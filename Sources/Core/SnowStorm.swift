import Foundation
import CoreGraphics

struct SnowStormSettings: Equatable {
    var snowfall = 0.5
    var maximumFlakeSize = 0.5
    var gusts = 0.5
    var decorations = false
    var lights = false
    var maximumRadius: Double { 1.4 + maximumFlakeSize * 7.6 }
    var stormForce: Double {
        let intensity = max(0, min(1, snowfall))
        return pow(max(0, (intensity - 0.55) / 0.45), 1.4)
    }
}

/// Window Server order is front to back. Frames use AppKit desktop coordinates.
struct SnowStormWindow: Equatable {
    let id: UInt32
    let owner: Int32
    var frame: CGRect
    var level: Int
    var decoratable = true
}

/// The visible cursor silhouette sampled when Snow Storm begins. Alpha rows run
/// from the top of the cursor image, matching NSCursor's hotspot coordinates.
struct CursorSnowShape {
    let size: CGSize
    let hotSpot: CGPoint
    let topPixels: [Int?]
    let pixelHeight: Int
    init?(size: CGSize, hotSpot: CGPoint, pixelWidth: Int, pixelHeight: Int, alpha: [UInt8]) {
        guard size.width > 0, size.height > 0, pixelWidth > 0, pixelWidth <= 256,
              pixelHeight > 0, pixelHeight <= 256, alpha.count == pixelWidth * pixelHeight else { return nil }
        let tops = (0..<pixelWidth).map { x -> Int? in
            (0..<pixelHeight).first { alpha[$0 * pixelWidth + x] > 0 }
        }
        guard tops.contains(where: { $0 != nil }) else { return nil }
        self.size = size; self.hotSpot = hotSpot; topPixels = tops; self.pixelHeight = pixelHeight
    }
    func frame(at pointer: CGPoint) -> CGRect {
        CGRect(x: pointer.x - hotSpot.x, y: pointer.y + hotSpot.y - size.height,
               width: size.width, height: size.height)
    }
    func topY(at x: Double, in frame: CGRect) -> Double? {
        guard x >= frame.minX, x < frame.maxX else { return nil }
        let column = min(topPixels.count - 1, Int((x - frame.minX) / frame.width * Double(topPixels.count)))
        guard let pixel = topPixels[column] else { return nil }
        return frame.maxY - Double(pixel) / Double(pixelHeight) * frame.height
    }
}

/// Velocity is a fixed travel rate, not an integrated physical state.
struct StormFlake {
    var position: CGPoint
    var velocity: CGVector
    var mass: Double
    var radius: Double
    var phase: Double
    var age = 0.0
    var depthWindow: UInt32?
    var ignoreSupport: UInt64?
    var ignoreUntil = 0.0
    var landingSeed: UInt32 = 0
}

/// Deposits blend into a small height field. Quiet banks need no per-frame work.
struct StormDrift {
    static let cursorID = UInt64.max
    // A fixed quarter-circle approximation suits most rounded window tops.
    // Snow ends before the side edge, where the window itself curves away.
    static let cornerInset = 26.0
    static let cornerDrop = 26.0
    static let cornerBlank = 8.0
    static let cornerTaper = 30.0
    let id: UInt64
    var window: SnowStormWindow?
    var frame: CGRect
    var masses: [Double]
    var heightCaps: [Double]
    var cursorShape: CursorSnowShape?
    var revision: UInt64 = 0
    var motion = CGVector.zero
    var peakSpeed = 0.0
    var directionStartTime = -Double.infinity
    var lastMoveTime = -Double.infinity
    var isCursor: Bool { id == Self.cursorID }
    var maximumHeight: Double { isCursor ? 12 : 24 }
    var cellWidth: Double { frame.width / Double(masses.count) }
    var mass: Double { masses.reduce(0, +) }
    var heights: [Double] { masses.map { $0 / cellWidth } }
    func supportY(at x: Double) -> Double? {
        if let cursorShape { return cursorShape.topY(at: x, in: frame) }
        guard !isCursor else { return frame.maxY }
        let distance = max(0, min(x - frame.minX, frame.maxX - x))
        guard distance >= Self.cornerBlank else { return nil }
        let radius = min(Self.cornerInset, frame.width * 0.5)
        guard distance < radius else { return frame.maxY }
        let offset = radius - distance
        return frame.maxY - radius + sqrt(max(0, radius * radius - offset * offset))
    }
    init(id: UInt64, window: SnowStormWindow?, frame: CGRect, cursorShape: CursorSnowShape? = nil) {
        self.id = id; self.window = window; self.frame = frame; self.cursorShape = cursorShape
        let count = cursorShape.map { min(192, $0.topPixels.count) } ?? max(4, min(192, Int(ceil(frame.width / 8))))
        masses = Array(repeating: 0, count: count)
        heightCaps = Self.makeCaps(id: id, count: count, cursor: id == Self.cursorID)
        if !isCursor {
            for i in heightCaps.indices {
                let x = frame.minX + (Double(i) + 0.5) * cellWidth
                let distance = min(x - frame.minX, frame.maxX - x)
                let fraction = min(1, max(0, (distance - Self.cornerBlank) / Self.cornerTaper))
                let taper = fraction * fraction * (3 - 2 * fraction)
                heightCaps[i] *= taper
            }
        }
        if let cursorShape {
            for i in heightCaps.indices where cursorShape.topY(at: frame.minX + (Double(i) + 0.5) * cellWidth, in: frame) == nil {
                heightCaps[i] = 0
            }
        }
    }
    private static func makeCaps(id: UInt64, count: Int, cursor: Bool) -> [Double] {
        guard !cursor else { return Array(repeating: 12, count: count) }
        func unit(_ anchor: Int, _ salt: UInt64) -> Double {
            var x = id ^ (UInt64(anchor) &* 0x9E3779B97F4A7C15) ^ salt
            x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
            x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
            return Double((x ^ (x >> 31)) >> 11) / 9_007_199_254_740_992
        }
        func rolling(_ cell: Int, period: Int, salt: UInt64) -> Double {
            let anchor = cell / period, fraction = Double(cell % period) / Double(period)
            let eased = fraction * fraction * (3 - 2 * fraction)
            return unit(anchor, salt) * (1 - eased) + unit(anchor + 1, salt) * eased
        }
        return (0..<count).map { cell in
            let broad = rolling(cell, period: 17, salt: 0xB7A8)
            let local = rolling(cell, period: 5, salt: 0x51D3)
            let grain = unit(cell, 0xC19F)
            let edge = min(cell + 1, count - cell)
            let taper = min(1, 0.35 + Double(edge) * 0.09)
            return max(2.25, min(24, (10.5 + 6 * broad + 11.25 * (local - 0.5) + 3.75 * (grain - 0.5)) * taper))
        }
    }
    static func caps(id: UInt64, count: Int, cursor: Bool) -> [Double] { makeCaps(id: id, count: count, cursor: cursor) }
    func height(at x: Double) -> Double {
        let i = max(0, min(masses.count - 1, Int((x - frame.minX) / cellWidth)))
        return masses[i] / cellWidth
    }
}

private struct StormGridKey: Hashable { let x: Int; let y: Int }

struct StormVortex {
    let screen: CGRect
    let center: CGPoint
    let radius: Double
    let direction: Double
    let start: Double
    let duration: Double
    func envelope(at time: Double) -> Double {
        let phase = (time - start) / duration
        return phase > 0 && phase < 1 ? pow(sin(.pi * phase), 2) : 0
    }
}

/// One formula pass per frame: constant fall speed, sinusoidal sway, and a shared
/// gust offset. Only top-edge crossings can land. Moving edges fake a push by
/// changing X; there are no forces, impulses, body collision solver, or substeps.
final class SnowStormSimulation {
    static let maximumParticles = 3_000
    static let maximumWindows = 48
    private(set) var particles: [StormFlake] = []
    private(set) var drifts: [StormDrift] = []
    private(set) var windows: [SnowStormWindow] = []
    private(set) var time = 0.0
    private(set) var emittedMass = 0.0
    private(set) var escapedMass = 0.0
    private(set) var wind = 0.0
    private var seed: UInt64
    private var windSeed: UInt64
    private let cursorShape: CursorSnowShape?
    private var emitRemainder = 0.0
    private var nextGust = 0.5
    private var gustStart = -100.0
    private var gustDuration = 1.0
    private var gustAmplitude = 0.0
    private var nextVortex = 10.0
    private(set) var vortex: StormVortex?
    private(set) var vortexCount = 0
    private var fragmentRadiusLimit = 5.2
    private var lastWindowSample: Double?
    private var grid: [StormGridKey: [Int]] = [:]
    private var gridDirty = true
    private var driftLookup: [UInt64: Int] = [:]
    private(set) var erosionMass = 0.0
    private(set) var collisionCount = 0
    private(set) var gustCount = 0
    init(seed: UInt64 = 0x73A1_912B, cursorShape: CursorSnowShape? = nil) {
        self.seed = seed; windSeed = seed ^ 0xD1B5_4A32_D192_ED03; self.cursorShape = cursorShape
        particles.reserveCapacity(Self.maximumParticles)
    }
    var totalMass: Double { particles.reduce(0) { $0 + $1.mass } + drifts.reduce(0) { $0 + $1.mass } }
    private static func nextRandom(_ state: inout UInt64) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
    private func random() -> Double { Self.nextRandom(&seed) }
    private func randomWind() -> Double { Self.nextRandom(&windSeed) }
    /// Stable per flake/window, so skipped snow stays in front of that window
    /// instead of making a new random decision every time it crosses a grid cell.
    static func landsOnWindow(_ flake: StormFlake, id: UInt32) -> Bool {
        var bits = flake.landingSeed ^ (id &* 0x9E3779B9)
        bits = (bits ^ (bits >> 16)) &* 0x7FEB352D
        bits = (bits ^ (bits >> 15)) &* 0x846CA68B
        bits ^= bits >> 16
        return bits % 100 < 60
    }
    func advance(dt rawDT: Double, windows incoming: [SnowStormWindow], cursor: CGPoint?, screens: [CGRect], settings: SnowStormSettings,
                 windowSampleTime: Double? = nil, emit: Bool = true) {
        guard rawDT.isFinite, rawDT > 0 else { return }
        fragmentRadiusLimit = max(0.8, settings.maximumRadius)
        let dt = min(rawDT, 1.0 / 15)
        let stamp = windowSampleTime ?? (time + dt)
        if lastWindowSample != stamp {
            let sampleDT = max(1.0 / 240, min(0.2, lastWindowSample.map { stamp - $0 } ?? dt))
            updateWindows(incoming, dt: sampleDT)
            lastWindowSample = stamp
        }
        updateCursor(cursor, dt: dt)
        if gridDirty { rebuildGrid(); gridDirty = false }
        time += dt
        updateWind(settings: settings, screens: screens)
        if emit { spawn(screens: screens, settings: settings, dt: dt) }
        evolveParticles(dt: dt, screens: screens, settings: settings)
    }
    private func updateWindows(_ incoming: [SnowStormWindow], dt: Double) {
        var seen = Set<UInt32>()
        let next = incoming.filter { w in
            w.frame.width.isFinite && w.frame.height.isFinite && w.frame.minX.isFinite && w.frame.minY.isFinite &&
            w.frame.width >= 40 && w.frame.height >= 30 && w.frame.width <= 32_768 && w.frame.height <= 32_768 && seen.insert(w.id).inserted
        }.prefix(Self.maximumWindows).map { $0 }
        guard next != windows else { return }
        windows = next; gridDirty = true
        let ids = Set(windows.map { UInt64($0.id) })
        var surviving: [StormDrift] = []
        for drift in drifts {
            if drift.isCursor || ids.contains(drift.id) { surviving.append(drift) }
            else { release(drift, fraction: 1) }
        }
        drifts = surviving; rebuildLookup()
        for window in windows {
            let id = UInt64(window.id)
            if let i = driftLookup[id], drifts[i].window?.owner == window.owner {
                moveSupport(i, frame: window.frame, dt: dt); drifts[i].window = window
            } else {
                if let i = driftLookup[id] { release(drifts[i], fraction: 1); drifts.remove(at: i); rebuildLookup() }
                drifts.append(StormDrift(id: id, window: window, frame: window.frame)); rebuildLookup()
            }
        }
        let windowIDs = Set(windows.map(\.id))
        for i in particles.indices {
            if let id = particles[i].depthWindow, !windowIDs.contains(id) { particles[i].depthWindow = nil }
        }
    }
    private func rebuildLookup() { driftLookup = Dictionary(uniqueKeysWithValues: drifts.indices.map { (drifts[$0].id, $0) }) }
    private func updateCursor(_ cursor: CGPoint?, dt: Double) {
        guard let cursor, cursor.x.isFinite, cursor.y.isFinite else {
            if let i = driftLookup[StormDrift.cursorID] { release(drifts[i], fraction: 1); drifts.remove(at: i); rebuildLookup(); gridDirty = true }
            return
        }
        let frame = cursorShape?.frame(at: cursor) ?? CGRect(x: cursor.x - 3, y: cursor.y - 16, width: 24, height: 18)
        if let i = driftLookup[StormDrift.cursorID] { moveSupport(i, frame: frame, dt: dt) }
        else { drifts.append(StormDrift(id: StormDrift.cursorID, window: nil, frame: frame, cursorShape: cursorShape)); rebuildLookup() }
    }
    private func moveSupport(_ i: Int, frame: CGRect, dt: Double) {
        guard drifts[i].frame != frame else { return }
        let old = drifts[i], dx = frame.minX - old.frame.minX, dy = frame.maxY - old.frame.maxY
        let distance = hypot(dx, dy)
        if old.isCursor {
            if distance > 500 {
                release(old, fraction: 1); drifts[i].masses = old.masses.map { _ in 0 }; drifts[i].revision &+= 1
            } else if distance / dt > 180 {
                let fraction = min(0.55, max(0.08, distance / dt / 2400))
                release(old, fraction: fraction)
                for j in drifts[i].masses.indices { drifts[i].masses[j] *= 1 - fraction }
                drifts[i].revision &+= 1
            }
        } else if distance > 500 || abs(frame.width - old.frame.width) > 0.01 {
            // A relocation or resize is not evidence that the window was shaken.
            drifts[i].motion = .zero; drifts[i].peakSpeed = 0
            drifts[i].directionStartTime = time; drifts[i].lastMoveTime = time
        } else {
            let recent = time - old.lastMoveTime <= 0.15
            let previous = recent ? old.motion : .zero
            let vx = dx / dt, vy = dy / dt
            let speed = min(5_000, distance / dt)
            let previousSpeed = hypot(previous.dx, previous.dy)
            let reversed = recent && distance >= 2 && speed > 80 && previousSpeed > 80 &&
                previous.dx * vx + previous.dy * vy < -0.3 * previousSpeed * hypot(vx, vy)
            let quickShake = reversed && old.peakSpeed > 650 && time - old.directionStartTime < 0.8
            if quickShake {
                let fraction = min(0.10, 0.03 + (old.peakSpeed - 650) / 18_000)
                shedMovingSnow(i, old: old, fraction: fraction, dx: dx, dy: dy)
            }
            // Sustained fast travel also loosens the bank, even without a
            // reversal. Scale by sample time so query timing changes do not
            // suddenly strip a window bare; favor the trailing edge.
            let fastFactor = min(1, max(0, (speed - 550) / 1_300))
            let travelFraction = 0.018 * fastFactor * min(1.5, dt * 30)
            if travelFraction > 0 { shedMovingSnow(i, old: old, fraction: travelFraction, dx: dx, dy: dy) }
            // One inexpensive shift approximates the snow lagging a change in
            // window speed. Only mass already at the trailing edge can spill.
            let slip = max(-18, min(18, (previous.dx - vx) * dt * 0.23))
            if abs(slip) >= 0.5 { slideBank(i, old: old, by: slip) }
            drifts[i].motion = CGVector(dx: vx, dy: vy)
            drifts[i].peakSpeed = reversed || !recent ? speed : max(old.peakSpeed, speed)
            drifts[i].directionStartTime = reversed || !recent ? time : old.directionStartTime
            drifts[i].lastMoveTime = time
        }
        // A leading edge crossing a flake only nudges its X position. Existing
        // drift debris is briefly exempt so shedding stays at the old location.
        if !old.isCursor && distance > 0.5 && distance <= 500 {
            let span = old.frame.union(frame)
            for p in particles.indices {
                let point = particles[p].position
                guard point.y >= span.minY, point.y <= span.maxY,
                      !(particles[p].ignoreSupport == old.id && time < particles[p].ignoreUntil),
                      Self.landsOnWindow(particles[p], id: UInt32(old.id)) else { continue }
                let radius = particles[p].radius
                if frame.maxX > old.frame.maxX && point.x >= old.frame.maxX - radius && point.x <= frame.maxX + radius {
                    particles[p].position.x = frame.maxX + radius + 1; collisionCount += 1
                } else if frame.minX < old.frame.minX && point.x <= old.frame.minX + radius && point.x >= frame.minX - radius {
                    particles[p].position.x = frame.minX - radius - 1; collisionCount += 1
                } else if abs(dy) > 0.5 && frame.contains(point) && !old.frame.contains(point) {
                    particles[p].position.x = point.x < frame.midX ? frame.minX - radius - 1 : frame.maxX + radius + 1
                    collisionCount += 1
                }
            }
        }
        drifts[i].frame = frame
        if abs(frame.width - old.frame.width) > 0.01 {
            let count = max(4, min(192, Int(ceil(frame.width / 8))))
            var masses = Array(repeating: 0.0, count: count)
            let caps = StormDrift.caps(id: old.id, count: count, cursor: old.isCursor)
            let width = frame.width / Double(count)
            for j in old.masses.indices where drifts[i].masses[j] > 0 {
                let x = (Double(j) + 0.5) * old.cellWidth, mass = drifts[i].masses[j]
                if x < frame.width {
                    let destination = min(count - 1, Int(x / width)), capacity = width * caps[destination] - masses[destination]
                    let settled = min(mass, max(0, capacity)); masses[destination] += settled
                    if settled < mass { shed(mass: mass - settled, from: old, cell: j) }
                } else { shed(mass: mass, from: old, cell: j) }
            }
            drifts[i].masses = masses; drifts[i].heightCaps = caps; drifts[i].revision &+= 1
        }
    }
    private func slideBank(_ i: Int, old: StormDrift, by distance: Double) {
        let width = old.cellWidth, count = old.masses.count
        var shifted = Array(repeating: 0.0, count: count)
        var changed = false
        for cell in 0..<count where drifts[i].masses[cell] > 0 {
            let mass = drifts[i].masses[cell]
            let destination = Double(cell) + distance / width
            let lower = Int(floor(destination)), upperFraction = destination - Double(lower)
            let lowerMass = mass * (1 - upperFraction), upperMass = mass * upperFraction
            if lower >= 0 && lower < count { shifted[lower] += lowerMass }
            else if lowerMass > 0 { shed(mass: lowerMass, from: old, cell: cell) }
            if lower + 1 >= 0 && lower + 1 < count { shifted[lower + 1] += upperMass }
            else if upperMass > 0 { shed(mass: upperMass, from: old, cell: cell) }
            changed = true
        }
        for cell in 0..<count {
            let maximum = width * old.heightCaps[cell]
            if shifted[cell] > maximum {
                shed(mass: shifted[cell] - maximum, from: old, cell: cell)
                shifted[cell] = maximum
            }
        }
        if changed { drifts[i].masses = shifted; drifts[i].revision &+= 1 }
    }
    private func shedMovingSnow(_ i: Int, old: StormDrift, fraction: Double, dx: Double, dy: Double) {
        guard fraction > 0 else { return }
        let count = drifts[i].masses.count
        let bucketWidth = max(1, Int(ceil(Double(count) / 16)))
        var released = 0.0
        var changed = false
        for cell in 0..<count {
            if drifts[i].masses[cell] > 0 {
                let position = (Double(cell) + 0.5) / Double(count)
                let trailing = abs(dx) >= abs(dy) ? (dx >= 0 ? 1 - position : position) : max(position, 1 - position)
                let edgeWeight = 0.35 + 1.65 * trailing * trailing
                let mass = drifts[i].masses[cell] * min(0.2, fraction * edgeWeight)
                drifts[i].masses[cell] -= mass
                released += mass
                changed = changed || mass > 0
            }
            if (cell + 1) % bucketWidth == 0 || cell == count - 1 {
                if released > 0 {
                    shed(mass: released, from: old, cell: max(0, cell - bucketWidth / 2), maximumChunks: 1)
                    released = 0
                }
            }
        }
        if changed { drifts[i].revision &+= 1 }
    }
    private func updateWind(settings: SnowStormSettings, screens: [CGRect]) {
        let strength = max(0, min(1, settings.gusts))
        if strength > 0 && time >= nextGust {
            gustCount += 1; gustStart = time; gustDuration = 1 + randomWind() * (1.2 + strength * 2)
            gustAmplitude = (randomWind() < 0.5 ? -1 : 1) * strength * (35 + randomWind() * 210)
            nextGust = time + gustDuration + 0.4 + (1 - strength) * 9 + randomWind() * (1 - strength) * 7
        }
        let phase = (time - gustStart) / gustDuration
        wind = strength > 0 && phase >= 0 && phase <= 1 ? gustAmplitude * pow(sin(.pi * phase), 2) : 0
        wind += sin(time * 0.37) * strength * 14

        if let vortex, (time >= vortex.start + vortex.duration || !screens.contains(vortex.screen) || strength <= 0.05) {
            self.vortex = nil
        }
        if strength > 0.05 && vortex == nil && time >= nextVortex {
            let valid = screens.prefix(8).filter { $0.width >= 180 && $0.height >= 180 && $0.width.isFinite && $0.height.isFinite }
            if !valid.isEmpty {
                let screen = valid[min(valid.count - 1, Int(randomWind() * Double(valid.count)))]
                let radius = max(65, min(210, min(screen.width, screen.height) * (0.16 + strength * 0.09)))
                let left = randomWind() < 0.5
                let center = CGPoint(x: left ? screen.minX + radius * 0.32 : screen.maxX - radius * 0.32,
                                     y: screen.minY + radius + max(0, screen.height - radius * 2) * randomWind())
                let duration = 2.2 + strength * 1.5 + randomWind() * 1.5
                vortex = StormVortex(screen: screen, center: center, radius: radius,
                                     direction: randomWind() < 0.5 ? -1 : 1, start: time, duration: duration)
                vortexCount += 1
                nextVortex = time + duration + 6 + (1 - strength) * 20 + randomWind() * (9 + (1 - strength) * 20)
            } else { nextVortex = time + 5 }
        }
    }
    func vortexVelocity(at point: CGPoint, gusts: Double) -> CGVector {
        guard let vortex else { return .zero }
        let strength = max(0, min(1, gusts)), envelope = vortex.envelope(at: time)
        guard strength > 0, envelope > 0 else { return .zero }
        let dx = point.x - vortex.center.x, dy = point.y - vortex.center.y
        let distance = hypot(dx, dy)
        guard distance > 1, distance < vortex.radius else { return .zero }
        let tangent = (75 + strength * 700) * envelope * pow(1 - distance / vortex.radius, 0.65) *
            min(1, distance / (vortex.radius * 0.18))
        let radial = (vortex.radius * 0.55 - distance) * 0.6 * envelope
        return CGVector(dx: vortex.direction * -dy / distance * tangent + dx / distance * radial,
                        dy: vortex.direction * dx / distance * tangent + dy / distance * radial)
    }
    private func spawn(screens: [CGRect], settings: SnowStormSettings, dt: Double) {
        let valid = screens.prefix(8).filter { $0.width > 0 && $0.height > 0 && $0.width.isFinite && $0.height.isFinite }
        let width = valid.reduce(0) { $0 + $1.width }
        guard width > 0 else { return }
        // Faster flakes leave the display sooner; replace them quickly enough
        // that max intensity still looks dense without raising the live cap.
        emitRemainder += dt * (20 + max(0, min(1, settings.snowfall)) * 300 + settings.stormForce * 500) * min(3, width / 1440)
        let count = min(Int(emitRemainder), max(0, Self.maximumParticles - particles.count))
        emitRemainder -= Double(Int(emitRemainder))
        // Redirect part of the existing emission budget to the upwind side.
        // A screen-height sample makes the gust visible all along the edge,
        // without increasing the live particle cap or adding another field.
        let sideShare = abs(wind) > 8 ? min(0.78, 0.13 + abs(wind) / 280) : 0
        let sideDirection = wind >= 0 ? 1.0 : -1.0
        let vortexShare = vortex.map { $0.envelope(at: time) * min(0.45, 0.12 + settings.gusts * 0.33) } ?? 0
        for _ in 0..<count {
            var sample = random() * width, screen = valid[valid.count - 1]
            for candidate in valid { if sample <= candidate.width { screen = candidate; break }; sample -= candidate.width }
            let radius = 0.7 + pow(random(), 2.4) * max(0.2, settings.maximumRadius - 0.7), mass = radius * radius * 0.8
            let position: CGPoint, dx: Double
            if let vortex, vortexShare > 0, random() < vortexShare {
                let angle = random() * .pi * 2, orbitRadius = vortex.radius * (0.45 + random() * 0.3)
                position = CGPoint(x: vortex.center.x + cos(angle) * orbitRadius,
                                   y: vortex.center.y + sin(angle) * orbitRadius)
                dx = (random() - 0.5) * 18
            } else {
                let fromSide = sideShare > 0 && random() < sideShare
                position = CGPoint(x: fromSide ? (sideDirection > 0 ? screen.minX - radius - 2 : screen.maxX + radius + 2) : screen.minX + sample,
                                   y: fromSide ? screen.minY + random() * screen.height : screen.maxY + radius + 2)
                dx = fromSide ? sideDirection * (4 + random() * 18) : (random() - 0.5) * 18
            }
            particles.append(StormFlake(position: position,
                velocity: CGVector(dx: dx, dy: -65 - random() * 45), mass: mass, radius: radius,
                phase: random() * .pi * 2, landingSeed: UInt32(truncatingIfNeeded: seed)))
            emittedMass += mass
        }
    }
    private func release(_ drift: StormDrift, fraction: Double) {
        for j in drift.masses.indices where drift.masses[j] > 0 { shed(mass: drift.masses[j] * fraction, from: drift, cell: j) }
    }
    private func shed(mass: Double, from drift: StormDrift, cell: Int, maximumChunks: Int = 4) {
        guard mass > 0 else { return }
        erosionMass += mass
        let slots = Self.maximumParticles - particles.count
        guard slots > 0 else { escapedMass += mass; return }
        let targetMass = max(0.8, fragmentRadiusLimit * fragmentRadiusLimit * 0.4)
        let chunks = min(slots, min(maximumChunks, max(1, Int(ceil(mass / targetMass)))))
        for _ in 0..<chunks {
            let chunkMass = mass / Double(chunks), x = drift.frame.minX + (Double(cell) + random()) * drift.cellWidth
            particles.append(StormFlake(position: CGPoint(x: x, y: (drift.supportY(at: x) ?? drift.frame.maxY) + drift.height(at: x) + 2 + random() * 3),
                velocity: CGVector(dx: (random() - 0.5) * 48, dy: -65 - random() * 45), mass: chunkMass,
                radius: min(fragmentRadiusLimit, max(0.6, sqrt(chunkMass / 0.8))), phase: random() * .pi * 2,
                depthWindow: drift.window?.id, ignoreSupport: drift.id, ignoreUntil: time + 0.6, landingSeed: UInt32(truncatingIfNeeded: seed)))
        }
    }
    /// Only narrow, stationary top bands are indexed, and only after geometry
    /// changes. Cursor landing uses one extra direct check instead of rebuilding.
    private func rebuildGrid() {
        grid.removeAll(keepingCapacity: true)
        for i in drifts.indices where !drifts[i].isCursor {
            let frame = drifts[i].frame
            let x0 = Int(floor(frame.minX / 128)), x1 = Int(floor(frame.maxX / 128))
            let y0 = Int(floor((frame.maxY - StormDrift.cornerDrop - 12) / 128)), y1 = Int(floor((frame.maxY + 48) / 128))
            for x in x0...x1 { for y in y0...y1 { grid[StormGridKey(x: x, y: y), default: []].append(i) } }
        }
    }
    private func landing(_ p: StormFlake, old: CGPoint, support i: Int) -> Double? {
        let drift = drifts[i]
        guard !(p.ignoreSupport == drift.id && time < p.ignoreUntil),
              drift.isCursor || Self.landsOnWindow(p, id: UInt32(drift.id)),
              p.position.x >= drift.frame.minX, p.position.x <= drift.frame.maxX else { return nil }
        guard let base = drift.supportY(at: p.position.x) else { return nil }
        let surface = base + drift.height(at: p.position.x) + p.radius
        // Several flakes can arrive in the same frame. Growth from an earlier
        // deposit must not make the rest tunnel through the newly raised bank.
        guard old.y >= base + p.radius, p.position.y <= surface else { return nil }
        // Snowbank strips preserve native Z order. A hidden top cannot catch snow.
        if let frontIndex = windows.firstIndex(where: { $0.id == drift.window?.id }),
           windows.prefix(frontIndex).contains(where: { $0.frame.contains(CGPoint(x: p.position.x, y: surface)) }) { return nil }
        return surface
    }
    private func evolveParticles(dt: Double, screens: [CGRect], settings: SnowStormSettings) {
        let snapshot = particles
        particles.removeAll(keepingCapacity: true)
        let force = settings.stormForce
        let swayTime = time * 1.6
        for var p in snapshot {
            p.age += dt
            let old = p.position
            let swirl = vortexVelocity(at: old, gusts: settings.gusts)
            p.position.x += (p.velocity.dx + wind + sin(swayTime + p.phase) * 12 + swirl.dx) * dt
            p.position.y += swirl.dy * dt - max(35, abs(p.velocity.dy)) * (1 + force * 3) * dt
            var support: Int?, highest = -Double.infinity
            let x0 = Int(floor(min(old.x, p.position.x) / 128)), x1 = Int(floor(max(old.x, p.position.x) / 128))
            let y0 = Int(floor(min(old.y, p.position.y) / 128)), y1 = Int(floor(max(old.y, p.position.y) / 128))
            // Formula speeds bound this to a few cells. No candidate allocation,
            // swept body tests, or pairwise particle collisions.
            for x in x0...min(x0 + 2, x1) { for y in y0...min(y0 + 2, y1) {
                for i in grid[StormGridKey(x: x, y: y)] ?? [] {
                    if let surface = landing(p, old: old, support: i), surface > highest { highest = surface; support = i }
                }
            } }
            if let cursor = driftLookup[StormDrift.cursorID], let surface = landing(p, old: old, support: cursor), surface > highest { highest = surface; support = cursor }
            if let i = support {
                let settled = deposit(p, support: i)
                if settled >= p.mass - 0.000001 { continue }
                p.mass -= settled
                p.ignoreSupport = drifts[i].id; p.ignoreUntil = time + 1
                // A full bank lets excess continue down in front of its window.
                p.position.y = min(p.position.y, highest - p.radius * 2 - 1)
            }
            let alive = p.age < 90 && p.position.x.isFinite && p.position.y.isFinite && screens.contains {
                p.position.x > $0.minX - 120 && p.position.x < $0.maxX + 120 && p.position.y > $0.minY - 40 && p.position.y < $0.maxY + 100
            }
            if alive && particles.count < Self.maximumParticles { particles.append(p) } else { escapedMass += p.mass }
        }
    }
    private func deposit(_ p: StormFlake, support: Int) -> Double {
        let width = drifts[support].cellWidth
        let cell = max(0, min(drifts[support].masses.count - 1, Int((p.position.x - drifts[support].frame.minX) / width)))
        var remaining = p.mass
        if drifts[support].cursorShape != nil {
            let candidates = [(0, 0.28), (-1, 0.18), (1, 0.18), (-2, 0.12), (2, 0.12), (-3, 0.06), (3, 0.06)]
                .compactMap { offset, weight -> (Int, Double)? in
                    let index = cell + offset
                    guard index >= 0 && index < drifts[support].masses.count,
                          drifts[support].heightCaps[index] > 0 else { return nil }
                    return (index, weight)
                }
            let totalWeight = candidates.reduce(0) { $0 + $1.1 }
            guard totalWeight > 0 else { return 0 }
            for (index, weight) in candidates {
                let capacity = max(0, width * drifts[support].heightCaps[index] - drifts[support].masses[index])
                let amount = min(capacity, p.mass * weight / totalWeight)
                drifts[support].masses[index] += amount; remaining -= amount
            }
            for (index, _) in candidates where remaining > 0.000001 {
                let capacity = max(0, width * drifts[support].heightCaps[index] - drifts[support].masses[index])
                let amount = min(capacity, remaining)
                drifts[support].masses[index] += amount; remaining -= amount
            }
            if remaining < p.mass { drifts[support].revision &+= 1 }
            return p.mass - remaining
        }
        // Blend each landing over adjacent bins; no later granular relaxation.
        for offset in [0, -1, 1] {
            let j = cell + offset
            guard j >= 0 && j < drifts[support].masses.count, drifts[support].heightCaps[j] > 0 else { continue }
            let capacity = max(0, width * drifts[support].heightCaps[j] - drifts[support].masses[j])
            let amount = min(capacity, offset == 0 ? remaining * 0.6 : offset == -1 ? remaining * 0.5 : remaining)
            drifts[support].masses[j] += amount; remaining -= amount
        }
        if remaining < p.mass { drifts[support].revision &+= 1 }
        return p.mass - remaining
    }
    #if TESTING
    func addParticleForTesting(_ particle: StormFlake) { particles.append(particle); emittedMass += particle.mass }
    func fillDriftForTesting(id: UInt64, height: Double) {
        guard let i = driftLookup[id] else { return }
        let width = drifts[i].cellWidth
        let masses = drifts[i].heightCaps.map { min($0, max(0, height)) * width }
        emittedMass += masses.reduce(0, +) - drifts[i].mass
        drifts[i].masses = masses; drifts[i].revision &+= 1
    }
    #endif
}
