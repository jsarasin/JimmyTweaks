import Foundation
import CoreGraphics

struct FireplaceDock: Equatable { let frame: CGRect }
struct FireplaceLayout: Equatable {
    enum Edge: Equatable { case bottom, left, right }
    let screen: CGRect
    let frame: CGRect
    let edge: Edge
    /// Height of the Dock in the fireplace's canonical edge coordinates.
    let dockOcclusion: Double
    var length: Double { edge == .bottom ? frame.width : frame.height }
    var depth: Double { edge == .bottom ? frame.height : frame.width }
    static let topBrickHeight = 8.0
    static let mantelHeight = 30.0
    static let decorationHeight = 20.0
    var mantelBase: Double { depth - Self.mantelHeight - Self.decorationHeight }
    var opening: CGRect {
        CGRect(x: 18, y: 0, width: max(30, length - 36),
               height: max(30, mantelBase - Self.topBrickHeight))
    }
    var fireWidth: Double { min(opening.width, length * 0.8) }
    var fireLeft: Double { (length - fireWidth) * 0.5 }
    var logBed: CGRect {
        CGRect(x: fireLeft, y: dockOcclusion - 28, width: fireWidth, height: 36)
    }
    var flameRect: CGRect {
        let firebox = opening
        let base = logBed.maxY - 7
        return CGRect(x: fireLeft, y: base, width: fireWidth,
                      height: max(1, firebox.maxY - base))
    }
    var transform: CGAffineTransform {
        switch edge {
        case .bottom: return CGAffineTransform(translationX: frame.minX, y: frame.minY)
        case .left: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: frame.minX, ty: frame.minY)
        case .right: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: frame.maxX, ty: frame.minY)
        }
    }
    /// A live surround grows when the Dock reaches the inner masonry, retaining
    /// its larger envelope until disabled so magnification never makes it breathe.
    static func resolve(screens: [CGRect], dock: FireplaceDock?, previous: FireplaceLayout? = nil,
                        widthFraction: Double = 0.5, height: Double = 158, offset: Double = 0) -> FireplaceLayout? {
        let screens = screens.filter(WindowGeometry.valid)
        guard let main = screens.first, main.width >= 160, main.height >= 160 else { return nil }
        let widthFraction = min(0.8, max(0.3, widthFraction))
        let height = min(320, max(80, height))
        let retained = previous.flatMap { screens.contains($0.screen) ? $0 : nil }
        if let dock, WindowGeometry.valid(dock.frame),
           let screen = screens.max(by: { area($0.intersection(dock.frame)) < area($1.intersection(dock.frame)) }),
           area(screen.intersection(dock.frame)) >= area(dock.frame) * 0.6,
           min(dock.frame.width, dock.frame.height) >= 12,
           min(dock.frame.width, dock.frame.height) <= 512 {
            let horizontal = dock.frame.width >= dock.frame.height
            let edge: Edge?
            if horizontal && abs(dock.frame.minY - screen.minY) <= 45 { edge = .bottom }
            else if !horizontal && abs(dock.frame.minX - screen.minX) <= 45 { edge = .left }
            else if !horizontal && abs(dock.frame.maxX - screen.maxX) <= 45 { edge = .right }
            else { edge = nil }
            if let edge {
                let prior = retained.flatMap { $0.screen == screen && $0.edge == edge ? $0 : nil }
                let axis = edge == .bottom ? screen.width : screen.height
                let desiredLength = axis * widthFraction
                let extent = edge == .bottom ? dock.frame.maxY - screen.minY : edge == .left ? dock.frame.maxX - screen.minX : screen.maxX - dock.frame.minX
                let depth = min((edge == .bottom ? screen.height : screen.width) - 12, height)
                let dockLength = edge == .bottom ? dock.frame.width : dock.frame.height
                let available = (edge == .bottom ? screen.width : screen.height) - 12
                let length = min(available, max(prior?.length ?? 0, desiredLength, dockLength * 1.3, dockLength + 80))
                if edge == .bottom {
                    return FireplaceLayout(screen: screen, frame: CGRect(x: position(in: screen.minX...screen.maxX, length: length, offset: offset), y: screen.minY, width: length, height: depth), edge: edge,
                                           dockOcclusion: extent)
                }
                return FireplaceLayout(screen: screen, frame: CGRect(x: edge == .left ? screen.minX : screen.maxX - depth,
                    y: position(in: screen.minY...screen.maxY, length: length, offset: offset), width: depth, height: length), edge: edge,
                                       dockOcclusion: extent)
            }
        }
        if let retained {
            let depth = min((retained.edge == .bottom ? retained.screen.height : retained.screen.width) - 12, height)
            var frame = retained.frame
            if retained.edge == .bottom {
                frame.size.height = depth
                frame.origin.x = position(in: retained.screen.minX...retained.screen.maxX, length: frame.width, offset: offset)
            }
            else {
                frame.size.width = depth
                if retained.edge == .right { frame.origin.x = retained.screen.maxX - depth }
                frame.origin.y = position(in: retained.screen.minY...retained.screen.maxY, length: frame.height, offset: offset)
            }
            return FireplaceLayout(screen: retained.screen, frame: frame, edge: retained.edge, dockOcclusion: 0)
        }
        let width = min(main.width - 24, main.width * widthFraction)
        return FireplaceLayout(screen: main, frame: CGRect(x: position(in: main.minX...main.maxX, length: width, offset: offset), y: main.minY, width: width, height: min(height, main.height - 12)), edge: .bottom,
                               dockOcclusion: 0)
    }
    private static func position(in bounds: ClosedRange<Double>, length: Double, offset: Double) -> Double {
        let margin = 6.0
        let travel = max(0, bounds.upperBound - bounds.lowerBound - length - margin * 2)
        return bounds.lowerBound + margin + travel * (min(1, max(-1, offset)) + 1) / 2
    }
    private static func area(_ rect: CGRect) -> Double { rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height) }
}

struct FireplaceBrick {
    let index: Int
    let target: CGRect
    let start: CGPoint
    let delay: Double
    let duration: Double
    let twist: Double
    let shade: Double
}
struct FireplaceBrickPose {
    let rect: CGRect
    let angle: Double
    let alpha: Double
    let shade: Double
}

/// Bounded turbulent fire and finite brick choreography, shared by live rendering
/// and deterministic previews. Disabling transfers the current pose to debris.
final class FireplaceModel {
    enum Phase: Equatable { case absent, assembling, burning, dissolving }
    static let buildDuration = 0.8
    static let departureDuration = 1.4
    static let fireAnimationSpeed = 1.6
    private(set) var layout: FireplaceLayout
    private(set) var phase = Phase.absent
    private(set) var phaseTime = 0.0
    private(set) var time = 0.0
    private(set) var bricks: [FireplaceBrick] = []
    private var departing: [FireplaceBrickPose] = []
    private var departureIgnition = 0.0
    private var departureBacking = 0.0
    private var heat: [Float] = []
    private var fireRemainder = 0.0
    private var fuel: [Float] = []
    private var fuelTarget: [Float] = []
    private var fuelLifetime: [Float] = []
    private var currents: [Float] = []
    private var currentColumns = 0
    private var currentRows = 0
    private var seed: UInt64 = 0xF1A3_78AB
    private(set) var columns = 0
    private(set) var rows = 0
    var fireHeat: [Float] { heat }
    var isVisible: Bool { phase != .absent }
    var departureProgress: Double? { phase == .dissolving ? min(1, phaseTime / Self.departureDuration) : nil }
    var ignition: Double { phase == .dissolving ? departureIgnition * (1 - Self.smooth(phaseTime / 0.24)) : Self.smooth((phaseTime - 0.16) / 0.5) }
    var backingOpacity: Double { phase == .dissolving ? departureBacking * (1 - Self.smooth(phaseTime / 0.25)) : Self.smooth(phaseTime / 0.3) }
    init(layout: FireplaceLayout) { self.layout = layout; rebuildBricks(); resizeFire(); for _ in 0..<64 { stepFire() } }
    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard phase == .absent || phase == .dissolving else { return }
            phase = .assembling; phaseTime = 0; departing.removeAll()
        } else {
            guard phase == .assembling || phase == .burning else { return }
            departing = poses(); departureIgnition = ignition; departureBacking = backingOpacity
            phase = .dissolving; phaseTime = 0
        }
    }
    func setLayout(_ next: FireplaceLayout) {
        guard next != layout, phase != .dissolving else { return }
        let geometryChanged = next.frame != layout.frame || next.edge != layout.edge
        layout = next
        if geometryChanged { rebuildBricks(); resizeFire() }
    }
    func advance(_ dt: Double) {
        guard dt.isFinite, dt > 0, phase != .absent else { return }
        let delta = min(1.0 / 15, dt)
        time += delta * Self.fireAnimationSpeed; phaseTime += delta
        if phase == .assembling && phaseTime >= Self.buildDuration { phase = .burning }
        if phase == .dissolving && phaseTime >= Self.departureDuration { phase = .absent; departing.removeAll(); return }
        if phase != .dissolving {
            fireRemainder += delta * Self.fireAnimationSpeed
            while fireRemainder >= 1.0 / 24 {
                fireRemainder -= 1.0 / 24
                stepFire()
            }
        }
    }
    func poses() -> [FireplaceBrickPose] {
        if phase == .absent { return [] }
        if phase == .dissolving {
            let t = min(1, phaseTime / 0.32), alpha = 1 - Self.smooth(t)
            return departing.enumerated().map { index, old in
                let direction = Self.noise(index, 8) * 2 - 1
                return FireplaceBrickPose(rect: old.rect.offsetBy(dx: direction * 60 * t, dy: (30 + Self.noise(index, 4) * 55) * t),
                    angle: old.angle + direction * t * 0.8, alpha: old.alpha * alpha, shade: old.shade)
            }
        }
        return bricks.map { brick in
            let t = max(0, min(1, (phaseTime - brick.delay) / brick.duration))
            let travel = 1 - pow(1 - t, 3)
            let center = CGPoint(x: brick.start.x + (brick.target.midX - brick.start.x) * travel,
                                 y: brick.start.y + (brick.target.midY - brick.start.y) * travel + sin(t * .pi) * 22)
            return FireplaceBrickPose(rect: CGRect(x: center.x - brick.target.width / 2, y: center.y - brick.target.height / 2, width: brick.target.width, height: brick.target.height),
                angle: brick.twist * (1 - travel), alpha: Self.smooth(t / 0.08), shade: brick.shade)
        }
    }
    private func rebuildBricks() {
        bricks.removeAll(keepingCapacity: true)
        let outer = CGRect(x: 0, y: 0, width: layout.length, height: layout.mantelBase)
        let opening = layout.opening
        let rowCount = Int(ceil(layout.mantelBase / 20))
        let brickWidth = max(40, ceil(layout.length / 64))
        for row in 0..<rowCount {
            let offset = row % 2 == 0 ? 0.0 : -brickWidth / 2
            for column in 0...Int(ceil(layout.length / brickWidth)) {
                let cell = CGRect(x: offset + Double(column) * brickWidth, y: Double(row) * 20, width: brickWidth, height: 20).intersection(outer)
                guard !cell.isEmpty, !cell.isNull else { continue }
                for rect in Self.subtract(opening, from: cell) where rect.width > 2 && rect.height > 2 {
                    let index = bricks.count, target = rect.applying(layout.transform)
                    let v = Self.noise(index, 3), pad = 40.0
                    let start: CGPoint
                    switch index % 4 {
                    case 0: start = CGPoint(x: layout.screen.minX - pad, y: layout.screen.minY + v * layout.screen.height)
                    case 1: start = CGPoint(x: layout.screen.maxX + pad, y: layout.screen.minY + v * layout.screen.height)
                    case 2: start = CGPoint(x: layout.screen.minX + v * layout.screen.width, y: layout.screen.maxY + pad)
                    default: start = CGPoint(x: layout.screen.minX + v * layout.screen.width, y: layout.screen.minY - pad)
                    }
                    bricks.append(FireplaceBrick(index: index, target: target, start: start, delay: Self.noise(index, 1) * 0.16,
                        duration: 0.43 + Self.noise(index, 2) * 0.16, twist: (Self.noise(index, 5) - 0.5) * 5, shade: Self.noise(index, 7)))
                }
            }
        }
    }
    private func resizeFire() {
        // The flames are smoothly interpolated over the firebox. A smaller
        // bounded heat grid avoids scaling CPU work with wide Dock layouts.
        let c = max(64, min(144, Int(layout.opening.width / 4)))
        let r = max(48, min(60, Int(layout.opening.height / 2)))
        guard c != columns || r != rows else { return }
        let old = heat, oldC = columns, oldR = rows
        columns = c; rows = r; heat = Array(repeating: 0, count: c * r)
        if oldC > 0 && oldR > 0 {
            for y in 0..<r { for x in 0..<c { heat[y * c + x] = old[min(oldR - 1, y * oldR / r) * oldC + min(oldC - 1, x * oldC / c)] } }
        }
        let zones = max(8, c / 9)
        fuel = (0..<zones).map { _ in 0.25 + random() * 0.85 }
        fuelTarget = fuel; fuelLifetime = fuel.map { _ in 0.05 + random() * 0.7 }
        currentColumns = c / 8 + 2; currentRows = r / 8 + 2
        currents = (0..<(currentColumns * currentRows)).map { _ in (random() - 0.5) * 2 }
    }
    private func random() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double(seed >> 11) / 9_007_199_254_740_992)
    }
    private func stepFire() {
        let old = heat
        // Independent fuel pockets flare and die on unrelated schedules. No
        // repeating sine-wave source, tiled flames, or fixed row colour bands.
        for i in fuel.indices {
            fuelLifetime[i] -= 1.0 / 24
            if fuelLifetime[i] <= 0 {
                fuelTarget[i] = 0.035 + pow(random(), 1.15) * 1.065
                fuelLifetime[i] = 0.12 + random() * 1.3
            }
            fuel[i] += (fuelTarget[i] - fuel[i]) * 0.28
        }
        for i in currents.indices { currents[i] = currents[i] * 0.91 + (random() - 0.5) * 0.38 }
        for x in 0..<columns {
            let u = Float(x) / Float(columns - 1) * Float(fuel.count - 1)
            let a = Int(u), b = min(fuel.count - 1, a + 1), t = u - Float(a)
            let edge = min(Float(x) / Float(columns - 1), Float(columns - 1 - x) / Float(columns - 1))
            let taper = min(1, max(0, edge / 0.14))
            heat[x] = max(0, min(1.1, (fuel[a] + (fuel[b] - fuel[a]) * t + (random() - 0.5) * 0.12) * taper))
        }
        for y in 1..<rows { for x in 0..<columns {
            let gx = Float(x) / 8, gy = Float(y) / 8
            let ix = Int(gx), iy = Int(gy), fx = gx - Float(ix), fy = gy - Float(iy)
            let a = currents[iy * currentColumns + ix], b = currents[iy * currentColumns + ix + 1]
            let c = currents[(iy + 1) * currentColumns + ix], d = currents[(iy + 1) * currentColumns + ix + 1]
            let swirl = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
            let localHeat = old[y * columns + x]
            let sx = max(0, min(Float(columns - 1), Float(x) - swirl * (2.5 + Float(y) / Float(rows) * 3)))
            let sy = max(0, Float(y) - 2.0 - localHeat * 2.7)
            let x0 = Int(sx), x1 = min(columns - 1, x0 + 1), y0 = Int(sy), y1 = min(rows - 1, y0 + 1)
            let tx = sx - Float(x0), ty = sy - Float(y0)
            let lower = old[y0 * columns + x0] * (1 - tx) + old[y0 * columns + x1] * tx
            let upper = old[y1 * columns + x0] * (1 - tx) + old[y1 * columns + x1] * tx
            let cooling = 0.020 + Float(y) / Float(rows) * 0.042 + random() * 0.016
            heat[y * columns + x] = max(0, lower * (1 - ty) + upper * ty - cooling)
        } }
    }
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(index + 1) &* 0x9E3779B97F4A7C15 &+ UInt64(salt) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9; x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return Double((x ^ (x >> 31)) >> 11) / 9_007_199_254_740_992
    }
    private static func smooth(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }
    private static func subtract(_ cut: CGRect, from rect: CGRect) -> [CGRect] {
        let i = rect.intersection(cut)
        guard !i.isNull, !i.isEmpty else { return [rect] }
        return [CGRect(x: rect.minX, y: rect.minY, width: i.minX - rect.minX, height: rect.height),
                CGRect(x: i.maxX, y: rect.minY, width: rect.maxX - i.maxX, height: rect.height),
                CGRect(x: i.minX, y: rect.minY, width: i.width, height: i.minY - rect.minY),
                CGRect(x: i.minX, y: i.maxY, width: i.width, height: rect.maxY - i.maxY)]
    }
}
