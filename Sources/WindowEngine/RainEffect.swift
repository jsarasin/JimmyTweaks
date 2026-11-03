import AppKit

struct RainDrop {
    let screenID: CGDirectDisplayID
    var position: CGPoint
    let speedVariation: Double
    let sizeVariation: Double
}

struct RainSplash {
    let windowID: UInt32
    let localX: Double
    let size: Double
    var age = 0.0
    let lifetime = 0.34
}

/// A bounded, directly drawn rain field. Drops are seeded across the display
/// immediately, so selecting Rain does not wait for an emitter to fill in.
final class RainEffectSimulation {
    static let maximumDropsPerScreen = 480
    static func splashChance(frequency: Double) -> Double {
        min(1, max(0, frequency))
    }
    private var seed: UInt64
    private(set) var drops: [RainDrop] = []
    private(set) var splashes: [RainSplash] = []
    #if TESTING
    private(set) var windowTopHits = 0
    private(set) var splashInteractions = 0
    #endif
    init(seed: UInt64 = 0xA17E_29D3) { self.seed = seed }
    private func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / 9_007_199_254_740_992
    }
    private func newDrop(on screen: StaticEffectScreen, fromTop: Bool) -> RainDrop {
        RainDrop(screenID: screen.id,
                 position: CGPoint(x: screen.frame.minX + random() * screen.frame.width,
                                   y: fromTop ? screen.frame.maxY + 10 + random() * 35 :
                                       screen.frame.minY + random() * screen.frame.height),
                 speedVariation: 0.72 + random() * 0.56,
                 sizeVariation: 0.7 + random() * 0.6)
    }
    func advance(dt rawDT: Double, screens: [StaticEffectScreen], windows: [SnowStormWindow], configuration: StaticEffectConfiguration) {
        guard rawDT.isFinite, rawDT > 0 else { return }
        let dt = min(rawDT, 0.05)
        let valid = Array(screens.prefix(8).filter { $0.frame.width > 0 && $0.frame.height > 0 })
        let byID = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0) })
        drops.removeAll { byID[$0.screenID] == nil }
        splashes.removeAll { splash in
            splash.age >= splash.lifetime || !windows.contains(where: { $0.id == splash.windowID })
        }
        for i in splashes.indices { splashes[i].age += dt }
        for screen in valid {
            let target = min(Self.maximumDropsPerScreen,
                             max(32, Int((70 + configuration.amount * 360) * min(1.6, sqrt(screen.frame.width / 1440)))))
            let existing = drops.filter { $0.screenID == screen.id }.count
            if existing < target {
                for _ in existing..<target { drops.append(newDrop(on: screen, fromTop: false)) }
            } else if existing > target {
                var excess = existing - target
                drops.removeAll { drop in
                    guard drop.screenID == screen.id && excess > 0 else { return false }
                    excess -= 1; return true
                }
            }
        }
        let baseSpeed = 420 + configuration.speed * 820
        for i in drops.indices {
            guard let screen = byID[drops[i].screenID] else { continue }
            let oldY = drops[i].position.y
            let speed = baseSpeed * drops[i].speedVariation
            drops[i].position.y -= speed * dt
            drops[i].position.x += speed * 0.095 * dt
            let x = drops[i].position.x
            var struck: SnowStormWindow?
            for window in windows where window.frame.intersects(screen.frame) &&
                x >= window.frame.minX + 6 && x <= window.frame.maxX - 6 &&
                oldY >= window.frame.maxY && drops[i].position.y <= window.frame.maxY {
                if struck == nil || window.frame.maxY > struck!.frame.maxY { struck = window }
            }
            if let struck {
                #if TESTING
                windowTopHits += 1
                #endif
                if random() < Self.splashChance(frequency: configuration.splashFrequency) {
                    #if TESTING
                    splashInteractions += 1
                    #endif
                    if splashes.count >= 80 { splashes.removeFirst() }
                    splashes.append(RainSplash(windowID: struck.id, localX: x - struck.frame.minX,
                                               size: 5 + configuration.size * 7 + random() * 6))
                    drops[i] = newDrop(on: screen, fromTop: true)
                    continue
                }
            }
            if drops[i].position.y < screen.frame.minY - 30 || x > screen.frame.maxX + 30 {
                drops[i] = newDrop(on: screen, fromTop: true)
            }
        }
    }
}

/// One transparent, pixel-aligned droplet per height. The largest is 20 points
/// tall; the smallest is a single bright pixel. Textures are generated once.
enum RainDropPixels {
    static let maximumHeight = 20
    static func height(slider: Double, variation: Double) -> Int {
        let setting = min(1, max(0, slider))
        return min(maximumHeight, max(1, Int((1 + 19 * pow(setting, 1.1) * variation).rounded())))
    }
    static let images: [CGImage] = (1...maximumHeight).map(make)
    private static func make(_ height: Int) -> CGImage {
        let width = height <= 3 ? height : max(4, Int((Double(height) * 0.72).rounded()))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsAntialiasing(false); context.setShouldAntialias(false)
        let outline = CGColor(red: 0.03, green: 0.42, blue: 0.60, alpha: 0.92)
        let shadow = CGColor(red: 0.02, green: 0.59, blue: 0.77, alpha: 0.88)
        let body = CGColor(red: 0.10, green: 0.76, blue: 0.96, alpha: 0.92)
        let light = CGColor(red: 0.48, green: 0.90, blue: 1, alpha: 0.96)
        let shine = CGColor(red: 0.93, green: 0.99, blue: 1, alpha: 0.98)
        if height <= 3 {
            context.setFillColor(light)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let center = (Double(width) - 1) * 0.5
        for y in 0..<height {
            let fraction = Double(y) / Double(height - 1)
            let halfWidth: Double
            if fraction < 0.23 {
                halfWidth = (0.20 + 0.30 * fraction / 0.23) * Double(width)
            } else if fraction < 0.53 {
                halfWidth = 0.50 * Double(width)
            } else {
                halfWidth = max(0, 0.50 * Double(width) * pow((1 - fraction) / 0.47, 0.82))
            }
            let left = fraction == 1 ? Int(center.rounded()) : max(0, Int(ceil(center - halfWidth + 0.45)))
            let right = fraction == 1 ? left : min(width - 1, Int(floor(center + halfWidth - 0.45)))
            guard left <= right else { continue }
            for x in left...right {
                let edge = x == left || x == right
                let leftGlint = height >= 9 && fraction > 0.30 && fraction < 0.76 && x == left + 1
                let lowerArc = height >= 12 && fraction > 0.12 && fraction < 0.25 &&
                    x >= left + 2 && x <= right - 2
                let color = leftGlint ? shine : lowerArc ? light : edge ? outline :
                    x > Int(center) + 1 ? shadow : body
                context.setFillColor(color)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        if height >= 13 {
            context.setFillColor(shine)
            context.fill(CGRect(x: max(1, width / 4), y: max(2, height / 6), width: 2, height: 2))
        }
        return context.makeImage()!
    }
}

enum RainEffectDrawing {
    static func drops(_ drops: [RainDrop], on screen: StaticEffectScreen, configuration: StaticEffectConfiguration,
                      in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = .none
        for drop in drops where drop.screenID == screen.id {
            let x = drop.position.x - screen.frame.minX, y = drop.position.y - screen.frame.minY
            let height = RainDropPixels.height(slider: configuration.size, variation: drop.sizeVariation)
            let image = RainDropPixels.images[height - 1]
            let width = Double(image.width)
            guard x > -width && x < screen.frame.width + width && y > -Double(height) && y < screen.frame.height + Double(height) else { continue }
            context.draw(image, in: CGRect(x: (x - width * 0.5).rounded(), y: y.rounded(),
                                           width: width, height: Double(height)))
        }
        context.restoreGState()
    }
    static func splashes(_ splashes: [RainSplash], on window: SnowStormWindow, in context: CGContext, origin: CGPoint) {
        context.saveGState()
        context.setLineCap(.round)
        for splash in splashes where splash.windowID == window.id {
            let phase = min(1, splash.age / splash.lifetime)
            let alpha = pow(1 - phase, 1.35)
            let x = window.frame.minX + splash.localX - origin.x
            let y = window.frame.maxY - origin.y + 1
            let spread = splash.size * (0.45 + phase)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - spread, y: y + phase * 2))
            path.addQuadCurve(to: CGPoint(x: x + spread, y: y + phase * 2),
                              control: CGPoint(x: x, y: y - 2 - phase * 2))
            for side in [-1.0, 1.0] {
                let tipX = x + side * spread * 0.8
                path.move(to: CGPoint(x: x + side * 2, y: y))
                path.addQuadCurve(to: CGPoint(x: tipX, y: y + splash.size * (0.4 + phase * 0.8)),
                                  control: CGPoint(x: x + side * spread * 0.3, y: y + splash.size * (0.8 + phase)))
            }
            context.addPath(path)
            context.setStrokeColor(NSColor(calibratedRed: 0.83, green: 0.94, blue: 1, alpha: alpha).cgColor)
            context.setLineWidth(1.2 + (1 - phase) * 0.7)
            context.strokePath()
        }
        context.restoreGState()
    }
}

private final class RainPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RainView: NSView {
    var simulation: RainEffectSimulation?
    var configuration: StaticEffectConfiguration?
    var screen: StaticEffectScreen?
    var supportWindow: SnowStormWindow?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let simulation, let context = NSGraphicsContext.current?.cgContext else { return }
        if let screen, let configuration {
            RainEffectDrawing.drops(simulation.drops, on: screen, configuration: configuration, in: context)
        } else if let window = supportWindow {
            RainEffectDrawing.splashes(simulation.splashes, on: window, in: context, origin: frameInWorld.origin)
        }
    }
    var frameInWorld = CGRect.zero
}

final class RainEffectController {
    private static let frameInterval = 1.0 / 60.0
    private(set) var simulation = RainEffectSimulation()
    private var configuration: StaticEffectConfiguration
    private let screens: () -> [StaticEffectScreen]
    private let query: (Set<Int>, Double) -> [SnowStormWindow]
    private let presentField: (NSPanel, SnowStormWindow?) -> Void
    private let presentSplash: (NSPanel, SnowStormWindow?) -> Void
    private var fieldPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var splashPanels: [UInt32: NSPanel] = [:]
    private var fieldTargets: [CGDirectDisplayID: UInt32?] = [:]
    private var windows: [SnowStormWindow] = []
    private var timer: Timer?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var nextWindowQuery = 0.0
    private var lastOrder: [UInt32] = []
    private var stopped = false
    init(configuration: StaticEffectConfiguration, screens: @escaping () -> [StaticEffectScreen],
         query: @escaping (Set<Int>, Double) -> [SnowStormWindow],
         presentField: @escaping (NSPanel, SnowStormWindow?) -> Void,
         presentSplash: @escaping (NSPanel, SnowStormWindow?) -> Void = SnowStormController.order,
         automaticTicks: Bool = true) {
        self.configuration = configuration; self.screens = screens; self.query = query
        self.presentField = presentField; self.presentSplash = presentSplash
        tick(dt: Self.frameInterval)
        if automaticTicks {
            let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.002; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    deinit { shutdown() }
    func update(configuration: StaticEffectConfiguration) { self.configuration = configuration }
    func shutdown() {
        guard !stopped else { return }
        stopped = true; timer?.invalidate(); timer = nil
        for panel in allPanels { panel.orderOut(nil) }
        fieldPanels.removeAll(); splashPanels.removeAll()
    }
    private func makePanel(frame: CGRect) -> NSPanel {
        let panel = RainPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.acceptsMouseMovedEvents = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.setAccessibilityHidden(true)
        panel.contentView = RainView(frame: CGRect(origin: .zero, size: frame.size))
        return panel
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(0.05, max(0, now - lastTick)); lastTick = now
        tick(dt: dt)
    }
    private func tick(dt: Double) {
        guard !stopped else { return }
        let displays = screens()
        let now = ProcessInfo.processInfo.systemUptime
        if now >= nextWindowQuery {
            let excluded = Set((NSApp?.windows ?? []).filter { !$0.styleMask.contains(.titled) }.map(\.windowNumber))
            let desktopTop = NSScreen.screens.first?.frame.maxY ?? displays.first?.frame.maxY ?? 0
            windows = query(excluded, desktopTop)
            nextWindowQuery = now + 0.2
        }
        simulation.advance(dt: dt, screens: displays, windows: windows, configuration: configuration)
        render(displays: displays)
    }
    private func render(displays: [StaticEffectScreen]) {
        let screenIDs = Set(displays.map(\.id))
        for id in Array(fieldPanels.keys) where !screenIDs.contains(id) { fieldPanels.removeValue(forKey: id)?.orderOut(nil); fieldTargets.removeValue(forKey: id) }
        for screen in displays {
            let panel = fieldPanels[screen.id] ?? makePanel(frame: screen.frame)
            let isNew = fieldPanels[screen.id] == nil
            fieldPanels[screen.id] = panel
            if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
            let target = windows.first { $0.frame.intersects(screen.frame) }
            if isNew || fieldTargets[screen.id] != target?.id { presentField(panel, target); fieldTargets[screen.id] = target?.id }
            if let view = panel.contentView as? RainView {
                view.simulation = simulation; view.configuration = configuration; view.screen = screen
                view.needsDisplay = true
            }
        }
        let active = Set(simulation.splashes.map(\.windowID))
        for id in Array(splashPanels.keys) where !active.contains(id) { splashPanels.removeValue(forKey: id)?.orderOut(nil) }
        let order = windows.map(\.id), reordered = order != lastOrder
        lastOrder = order
        for window in windows.reversed() where active.contains(window.id) {
            let frame = CGRect(x: window.frame.minX - 12, y: window.frame.maxY - 5,
                               width: window.frame.width + 24, height: 40)
            let panel = splashPanels[window.id] ?? makePanel(frame: frame)
            let isNew = splashPanels[window.id] == nil
            splashPanels[window.id] = panel
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if let view = panel.contentView as? RainView {
                view.simulation = simulation; view.supportWindow = window; view.frameInWorld = frame
                view.needsDisplay = true
            }
            if isNew || reordered { presentSplash(panel, window) }
        }
    }
    var allPanels: [NSPanel] { Array(fieldPanels.values) + Array(splashPanels.values) }
    #if TESTING
    func advanceForTesting(dt: Double) { tick(dt: dt) }
    var timerRunningForTesting: Bool { timer != nil }
    #endif
}
