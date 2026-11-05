import AppKit
import QuartzCore

/// A bounded collection of independent Core Animation emitters. Each visual
/// layer has its own movement and lifetime, so the field never moves as one
/// synchronized sheet when the wind changes.
enum FireStormLayers {
    static func emberFallVelocity(for speed: Double) -> Double {
        let value = min(1, max(0, speed))
        return 140 + 210 * value + 900 * pow(value, 3)
    }
    #if TESTING
    static var previewSprites: [(String, CGImage)] {
        [("flame", flameImage), ("spark", sparkImage), ("ember", emberImage),
         ("smoke", smokeImage), ("ash", ashImage), ("heat glow", heatImage)]
    }
    #endif
    static func make(configuration c: StaticEffectConfiguration, bounds: CGRect) -> [CAEmitterLayer] {
        guard c.effect == .fireStorm, bounds.width > 0, bounds.height > 0 else { return [] }
        // The extra density is concentrated near the top of the slider. At
        // ordinary settings the field keeps its earlier, cheaper particle load.
        let highEnd = pow(max(0, (c.amount - 0.55) / 0.45), 2)
        let density = 0.25 + c.amount * 0.75 + 1.8 * highEnd
        let speed = 0.45 + c.speed * 1.25
        let fallVelocity = emberFallVelocity(for: c.speed)
        let emberVelocityRange = 45 + c.speed * 115
        // Even the slowest embers need time to cross the whole display. The
        // birth rate is divided by life below, keeping the live count bounded.
        let emberLife = max(0.85, (bounds.height + 120) / max(80, fallVelocity - emberVelocityRange))
        let height = 0.35 + c.size * 0.85
        let wind = c.wind
        let bottom = CGPoint(x: bounds.midX, y: bounds.minY - 5)
        let top = CGPoint(x: bounds.midX, y: bounds.maxY + 8)

        let flame = cell(name: "flames", image: flameImage,
                         rate: (15 + 27 * density) / 1.35, life: 1.35,
                         velocity: 34 * speed + 25 * height, range: 20 * speed,
                         scale: 0.35 + height * 0.63, scaleRange: 0.21,
                         angle: .pi / 2, spread: 0.17 + wind * 0.17,
                         xAcceleration: 18 * wind, yAcceleration: 12,
                         color: .white, alphaSpeed: -0.65)
        let flames = emitter(name: "fireStorm.flames", bounds: bounds, position: bottom,
                             width: bounds.width, render: .additive, cells: [flame])
        pulse(flames, cell: "flames", rates: [0.65, 1.0, 0.78, 1.18, 0.65], baseRate: flame.birthRate, duration: 3.9)

        let sparksCell = cell(name: "sparks", image: sparkImage,
                              rate: (25 + 54 * density) / 2.1, life: 2.1,
                              velocity: 125 * speed, range: 75 * speed,
                              scale: 0.35 + c.size * 0.43, scaleRange: 0.24,
                              angle: .pi / 2, spread: 0.42 + wind * 0.30,
                              xAcceleration: 42 * wind, yAcceleration: -40,
                              color: .white, alphaSpeed: -0.43)
        let sparks = emitter(name: "fireStorm.sparks", bounds: bounds, position: bottom,
                             width: bounds.width, render: .additive, cells: [sparksCell])
        gust(sparks, cell: "sparks", strength: wind, duration: 7.4)

        let emberCell = cell(name: "embers", image: emberImage,
                             rate: (31 + 65 * density) / emberLife, life: emberLife,
                             velocity: fallVelocity, range: emberVelocityRange,
                             scale: 0.5 + c.size * 0.4, scaleRange: 0.12,
                             angle: -.pi / 2, spread: wind * 0.43,
                             xAcceleration: 38 * wind, yAcceleration: -25,
                             color: .white, alphaSpeed: -0.72 / emberLife)
        emberCell.spinRange = 0
        let embers = emitter(name: "fireStorm.embers", bounds: bounds, position: top,
                             width: bounds.width, render: .additive, cells: [emberCell])
        embers.minificationFilter = .nearest
        embers.magnificationFilter = .nearest
        gust(embers, cell: "embers", strength: wind, duration: 9.1)
        var layers = [flames, sparks, embers]

        if c.smoke {
            let smokeCell = cell(name: "smoke", image: smokeImage,
                                 rate: (7 + 13 * density) / 3.8, life: 3.8,
                                 velocity: 38 * speed, range: 24,
                                 scale: 0.7 + height * 0.55, scaleRange: 0.38,
                                 angle: .pi / 2, spread: 0.34 + wind * 0.30,
                                 xAcceleration: 30 * wind, yAcceleration: 7,
                                 color: NSColor(calibratedWhite: 0.66, alpha: 0.31), alphaSpeed: -0.07)
            let smoke = emitter(name: "fireStorm.smoke", bounds: bounds, position: bottom,
                                width: bounds.width, render: .unordered, cells: [smokeCell])
            gust(smoke, cell: "smoke", strength: wind, duration: 11.3)
            layers.insert(smoke, at: 0)
        }
        if c.ash {
            let ashCell = cell(name: "ash", image: ashImage,
                               rate: (13 + 38 * density) / 4.0, life: 4.0,
                               velocity: 72 * speed, range: 44,
                               scale: 0.4 + c.size * 0.3, scaleRange: 0.3,
                               angle: -.pi / 2, spread: wind * 0.34,
                               xAcceleration: 55 * wind, yAcceleration: -18,
                               color: NSColor(calibratedWhite: 0.78, alpha: 0.70), alphaSpeed: -0.20)
            let ash = emitter(name: "fireStorm.ash", bounds: bounds, position: top,
                              width: bounds.width, render: .unordered, cells: [ashCell])
            gust(ash, cell: "ash", strength: wind, duration: 8.3)
            layers.append(ash)
        }
        if c.heatGlow {
            let glowCell = cell(name: "heatGlow", image: heatImage,
                                rate: (3 + 5 * density) / 2.6, life: 2.6,
                                velocity: 35 * speed, range: 16,
                                scale: 0.9 + height * 0.6, scaleRange: 0.28,
                                angle: .pi / 2, spread: 0.32,
                                xAcceleration: 12 * wind, yAcceleration: 5,
                                color: NSColor(calibratedRed: 1, green: 0.36, blue: 0.08, alpha: 0.15), alphaSpeed: -0.05)
            layers.insert(emitter(name: "fireStorm.heatGlow", bounds: bounds, position: bottom,
                                  width: bounds.width, render: .additive, cells: [glowCell]), at: 0)
        }
        return layers
    }

    private static func emitter(name: String, bounds: CGRect, position: CGPoint, width: Double,
                                render: CAEmitterLayerRenderMode, cells: [CAEmitterCell]) -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.name = name
        layer.frame = bounds
        layer.emitterShape = .line
        layer.emitterMode = .outline
        layer.emitterPosition = position
        layer.emitterSize = CGSize(width: width, height: 1)
        layer.renderMode = render
        layer.emitterCells = cells
        return layer
    }

    private static func cell(name: String, image: CGImage, rate: Double, life: Double,
                             velocity: Double, range: Double, scale: Double, scaleRange: Double,
                             angle: Double, spread: Double, xAcceleration: Double, yAcceleration: Double,
                             color: NSColor, alphaSpeed: Double) -> CAEmitterCell {
        let cell = CAEmitterCell()
        cell.name = name; cell.contents = image
        cell.birthRate = Float(rate); cell.lifetime = Float(life)
        cell.velocity = velocity; cell.velocityRange = range
        cell.scale = CGFloat(scale); cell.scaleRange = CGFloat(scaleRange)
        cell.emissionLongitude = CGFloat(angle); cell.emissionRange = CGFloat(spread)
        cell.xAcceleration = xAcceleration; cell.yAcceleration = yAcceleration
        cell.spinRange = 1.9; cell.color = color.cgColor
        cell.alphaSpeed = Float(alphaSpeed)
        return cell
    }

    static func windowFire(in bounds: CGRect) -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.name = "fireStorm.windowFire"
        layer.frame = bounds
        layer.emitterShape = .line
        layer.emitterMode = .outline
        layer.emitterSize = CGSize(width: 38, height: 1)
        layer.renderMode = .additive
        layer.emitterCells = [cell(name: "windowFlame", image: flameImage,
                                   rate: 65, life: 0.68, velocity: 95, range: 42,
                                   scale: 0.72, scaleRange: 0.34,
                                   angle: .pi / 2, spread: 0.33,
                                   xAcceleration: 0, yAcceleration: 12,
                                   color: .white, alphaSpeed: -1.2),
                              cell(name: "windowSpark", image: sparkImage,
                                   rate: 30, life: 0.9, velocity: 115, range: 80,
                                   scale: 0.5, scaleRange: 0.25,
                                   angle: .pi / 2, spread: 0.7,
                                   xAcceleration: 0, yAcceleration: -45,
                                   color: .white, alphaSpeed: -0.9)]
        return layer
    }

    static func extinguish(_ layer: CAEmitterLayer) {
        layer.renderMode = .unordered
        layer.emitterSize = CGSize(width: 26, height: 1)
        layer.emitterCells = [cell(name: "windowSmoke", image: smokeImage,
                                   rate: 40, life: 0.9, velocity: 42, range: 22,
                                   scale: 0.7, scaleRange: 0.2,
                                   angle: .pi / 2, spread: 0.5,
                                   xAcceleration: 8, yAcceleration: 8,
                                   color: NSColor(calibratedWhite: 0.68, alpha: 0.7), alphaSpeed: -0.8)]
    }

    private static func gust(_ layer: CAEmitterLayer, cell: String, strength: Double, duration: Double) {
        guard strength > 0.01 else { return }
        let motion = CAKeyframeAnimation(keyPath: "emitterCells.\(cell).xAcceleration")
        motion.values = [-90 * strength, -24 * strength, 65 * strength, 112 * strength,
                         -52 * strength, -90 * strength]
        motion.keyTimes = [0, 0.19, 0.43, 0.58, 0.84, 1]
        motion.duration = duration; motion.repeatCount = .infinity
        motion.calculationMode = .cubicPaced
        layer.add(motion, forKey: "gust")
    }

    private static func pulse(_ layer: CAEmitterLayer, cell: String, rates: [Double], baseRate: Float,
                              duration: Double) {
        let motion = CAKeyframeAnimation(keyPath: "emitterCells.\(cell).birthRate")
        motion.values = rates.map { Double(baseRate) * $0 }
        motion.duration = duration; motion.repeatCount = .infinity
        layer.add(motion, forKey: "flamePulse")
    }

    private static func radialImage(width: Int, height: Int, colors: [CGColor], locations: [CGFloat]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                  locations: locations)!
        let center = CGPoint(x: width / 2, y: height / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: CGFloat(min(width, height)) / 2,
                                   options: [])
        return context.makeImage()!
    }

    private static let emberImage: CGImage = {
        let context = CGContext(data: nil, width: 12, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        func block(_ color: NSColor, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: x, y: y, width: width, height: height))
        }
        block(NSColor(calibratedRed: 0.76, green: 0.12, blue: 0.02, alpha: 1), 4, 2, 4, 10)
        block(NSColor(calibratedRed: 0.91, green: 0.24, blue: 0.02, alpha: 1), 3, 4, 6, 7)
        block(.systemOrange, 4, 5, 4, 6)
        block(.systemYellow, 5, 6, 2, 5)
        block(.white, 5, 8, 2, 2)
        block(.systemOrange, 5, 13, 2, 2)
        block(.systemRed, 3, 1, 2, 2)
        return context.makeImage()!
    }()
    private static let smokeImage = radialImage(width: 74, height: 74,
        colors: [NSColor.white.withAlphaComponent(0.45).cgColor,
                 NSColor.white.withAlphaComponent(0.24).cgColor,
                 NSColor.white.withAlphaComponent(0).cgColor], locations: [0, 0.46, 1])
    private static let heatImage = radialImage(width: 96, height: 96,
        colors: [NSColor.white.withAlphaComponent(0.36).cgColor,
                 NSColor.white.withAlphaComponent(0.12).cgColor,
                 NSColor.white.withAlphaComponent(0).cgColor], locations: [0, 0.47, 1])
    private static let ashImage: CGImage = {
        let context = CGContext(data: nil, width: 12, height: 12, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.withAlphaComponent(0.76).cgColor)
        context.fill(CGRect(x: 2, y: 5, width: 8, height: 2))
        context.fill(CGRect(x: 5, y: 2, width: 2, height: 7))
        return context.makeImage()!
    }()
    private static let sparkImage: CGImage = {
        let context = CGContext(data: nil, width: 8, height: 20, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.systemRed.withAlphaComponent(0).cgColor,
            NSColor.systemOrange.withAlphaComponent(0.8).cgColor,
            NSColor.white.cgColor,
            NSColor.systemYellow.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 0.28, 0.55, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 4, y: 0), end: CGPoint(x: 4, y: 20), options: [])
        return context.makeImage()!
    }()
    private static let flameImage: CGImage = {
        let context = CGContext(data: nil, width: 32, height: 68, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let shape = CGMutablePath()
        shape.move(to: CGPoint(x: 4, y: 0))
        shape.addCurve(to: CGPoint(x: 16, y: 67), control1: CGPoint(x: -3, y: 23), control2: CGPoint(x: 18, y: 44))
        shape.addCurve(to: CGPoint(x: 25, y: 17), control1: CGPoint(x: 12, y: 48), control2: CGPoint(x: 29, y: 37))
        shape.addQuadCurve(to: CGPoint(x: 28, y: 0), control: CGPoint(x: 35, y: 5))
        shape.closeSubpath()
        context.addPath(shape); context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor(calibratedRed: 1, green: 0.94, blue: 0.55, alpha: 0.96).cgColor,
            NSColor(calibratedRed: 1, green: 0.48, blue: 0.08, alpha: 0.92).cgColor,
            NSColor(calibratedRed: 0.83, green: 0.09, blue: 0.02, alpha: 0.45).cgColor,
            NSColor(calibratedRed: 0.83, green: 0.09, blue: 0.02, alpha: 0).cgColor
        ] as CFArray, locations: [0, 0.34, 0.75, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 16, y: 0),
                                   end: CGPoint(x: 16, y: 68), options: [])
        return context.makeImage()!
    }()
}

/// A small logical sample of the visible ember stream. It tracks only possible
/// roof crossings; Core Animation continues to draw the larger storm field.
final class FireStormIgnitionSimulation {
    struct Ember {
        var position: CGPoint
        let velocity: CGVector
    }
    struct Burn {
        let id: Int
        let windowID: UInt32
        let localX: CGFloat
        let duration: Double
        var age: Double
        var isSmoking: Bool { age >= duration }
    }
    private(set) var embers: [Ember] = []
    private(set) var burns: [Burn] = []
    private var spawnRemainder = 0.0
    private var nextID = 1
    private let random: () -> Double
    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) { self.random = random }

    func advance(dt rawStep: Double, screen: CGRect, windows: [SnowStormWindow],
                 configuration: StaticEffectConfiguration) {
        let dt = min(max(0, rawStep), 0.2)
        guard dt > 0 else { return }
        let ids = Set(windows.map(\.id))
        burns = burns.compactMap { burn in
            guard ids.contains(burn.windowID), burn.age + dt < burn.duration + 1.3 else { return nil }
            var updated = burn; updated.age += dt; return updated
        }
        let rate = 2 + 22 * pow(configuration.amount, 2)
        spawnRemainder += rate * dt
        while spawnRemainder >= 1 && embers.count < 140 {
            spawnRemainder -= 1
            let x = screen.minX + random() * screen.width
            let fall = FireStormLayers.emberFallVelocity(for: configuration.speed) * (0.87 + random() * 0.26)
            let drift = (random() - 0.5) * configuration.wind * 150
            embers.append(Ember(position: CGPoint(x: x, y: screen.maxY + 8),
                                velocity: CGVector(dx: drift, dy: -fall)))
        }
        if embers.count >= 140 { spawnRemainder = min(spawnRemainder, 1) }
        // These are the windows the field can visibly cover. Its panel sits
        // behind the frontmost window, so a fire is never lit on that window.
        let roofs = windows.enumerated().filter {
            $0.offset > 0 && $0.element.level == 0 && $0.element.frame.width >= 140 && $0.element.frame.intersects(screen)
        }.sorted { $0.element.frame.maxY > $1.element.frame.maxY }
        var survivors: [Ember] = []
        survivors.reserveCapacity(embers.count)
        for var ember in embers {
            let old = ember.position
            ember.position.x += ember.velocity.dx * dt
            ember.position.y += ember.velocity.dy * dt
            var hit: (window: SnowStormWindow, x: CGFloat)?
            for (index, roof) in roofs {
                let top = roof.frame.maxY
                guard old.y >= top, ember.position.y <= top, old.y > ember.position.y else { continue }
                let fraction = (old.y - top) / (old.y - ember.position.y)
                let x = old.x + (ember.position.x - old.x) * fraction
                guard x >= roof.frame.minX + 12, x <= roof.frame.maxX - 12,
                      !windows.prefix(index).contains(where: { $0.frame.contains(CGPoint(x: x, y: top + 1)) }) else { continue }
                hit = (roof, x); break
            }
            if let (roof, x) = hit {
                if random() < configuration.ignitionChance && burns.count < 10 &&
                    !burns.contains(where: { $0.windowID == roof.id && abs($0.localX - (x - roof.frame.minX)) < 80 }) {
                    burns.append(Burn(id: nextID, windowID: roof.id,
                                      localX: x - roof.frame.minX,
                                      duration: 2.7 + random() * 1.8, age: 0))
                    nextID += 1
                }
                continue
            }
            if ember.position.y > screen.minY - 10 && ember.position.x > screen.minX - 100 && ember.position.x < screen.maxX + 100 {
                survivors.append(ember)
            }
        }
        embers = survivors
    }
    #if TESTING
    func insertEmber(_ ember: Ember) { embers.append(ember) }
    #endif
}

private final class FireStormIgnitionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Small, bounded overlays follow their burning windows. Native window ordering
/// occludes both existing flames and drifting smoke when another window covers them.
final class FireStormIgnitions {
    private final class Overlay {
        let panel: NSPanel
        let layer: CAEmitterLayer
        init(frame: CGRect) {
            panel = FireStormIgnitionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.acceptsMouseMovedEvents = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.setAccessibilityHidden(true)
            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true; view.layer?.masksToBounds = true; view.setAccessibilityHidden(true)
            panel.contentView = view
            layer = FireStormLayers.windowFire(in: view.bounds)
            layer.emitterPosition = CGPoint(x: frame.width / 2, y: 8)
            view.layer?.addSublayer(layer)
        }
        func hide() { panel.orderOut(nil) }
    }
    private let screens: () -> [StaticEffectScreen]
    private let query: (Set<Int>, Double) -> [SnowStormWindow]
    private let present: (NSPanel, SnowStormWindow?) -> Void
    private var configuration: StaticEffectConfiguration
    private var simulations: [CGDirectDisplayID: FireStormIgnitionSimulation] = [:]
    private var overlays: [CGDirectDisplayID: [Int: Overlay]] = [:]
    private var timer: Timer?
    private var previousTime = ProcessInfo.processInfo.systemUptime

    init(configuration: StaticEffectConfiguration,
         screens: @escaping () -> [StaticEffectScreen],
         query: @escaping (Set<Int>, Double) -> [SnowStormWindow],
         present: @escaping (NSPanel, SnowStormWindow?) -> Void = SnowStormController.order, automaticTicks: Bool) {
        self.configuration = configuration; self.screens = screens
        self.query = query; self.present = present
        if automaticTicks {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.015
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
    deinit { shutdown() }
    func update(configuration: StaticEffectConfiguration) { self.configuration = configuration }
    func shutdown() {
        timer?.invalidate(); timer = nil
        for screenOverlays in overlays.values { for overlay in screenOverlays.values { overlay.hide() } }
        overlays.removeAll(); simulations.removeAll()
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - previousTime; previousTime = now
        tick(dt: dt)
    }
    private func tick(dt: Double) {
        let displays = Array(screens().prefix(8))
        let connected = Set(displays.map(\.id))
        for id in Array(overlays.keys) where !connected.contains(id) {
            overlays.removeValue(forKey: id)?.values.forEach { $0.hide() }
            simulations.removeValue(forKey: id)
        }
        let excluded = Set(NSApp.windows.filter { !$0.styleMask.contains(.titled) }.map(\.windowNumber))
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? displays.first?.frame.maxY ?? 0
        let windows = query(excluded, desktopTop)
        for display in displays {
            let simulation = simulations[display.id] ?? FireStormIgnitionSimulation()
            simulations[display.id] = simulation
            let localWindows = windows.filter { $0.frame.intersects(display.frame) }
            simulation.advance(dt: dt, screen: display.frame,
                               windows: localWindows,
                               configuration: configuration)
            var screenOverlays = overlays[display.id] ?? [:]
            let active = Set(simulation.burns.map(\.id))
            for id in Array(screenOverlays.keys) where !active.contains(id) {
                screenOverlays.removeValue(forKey: id)?.hide()
            }
            for burn in simulation.burns {
                guard let window = localWindows.first(where: { $0.id == burn.windowID }) else { continue }
                let frame = CGRect(x: window.frame.minX + burn.localX - 120,
                                   y: window.frame.maxY - 5, width: 240, height: 240)
                let overlay = screenOverlays[burn.id] ?? Overlay(frame: frame)
                screenOverlays[burn.id] = overlay
                if overlay.panel.frame != frame { overlay.panel.setFrame(frame, display: false) }
                let layer = overlay.layer
                // The continuous storm remains behind the frontmost window;
                // a pre-existing burn must not jump in front when its host gains focus.
                if window.id == localWindows.first?.id || burn.localX < 12 || burn.localX > window.frame.width - 12 {
                    layer.birthRate = 0; overlay.hide(); continue
                }
                if burn.isSmoking {
                    if layer.name != "fireStorm.windowSmoke" {
                        FireStormLayers.extinguish(layer)
                        layer.name = "fireStorm.windowSmoke"
                    }
                    layer.birthRate = burn.age - burn.duration < 0.24 ? 1.7 : 0
                } else {
                    let flare = min(1, burn.age / 0.34)
                    let fuel = max(0.25, 1 - burn.age / burn.duration)
                    layer.birthRate = Float((1.1 + 1.15 * (1 - flare)) * fuel)
                }
                present(overlay.panel, window)
            }
            overlays[display.id] = screenOverlays
        }
    }
    #if TESTING
    func tickForTesting(dt: Double = 0.1) { tick(dt: dt) }
    func insertEmberForTesting(_ ember: FireStormIgnitionSimulation.Ember, on display: CGDirectDisplayID) {
        let simulation = simulations[display] ?? FireStormIgnitionSimulation()
        simulations[display] = simulation; simulation.insertEmber(ember)
    }
    var activeFireCountForTesting: Int { overlays.values.reduce(0) { $0 + $1.count } }
    var panelsForTesting: [NSPanel] { overlays.values.flatMap { $0.values.map(\.panel) } }
    #endif
}
