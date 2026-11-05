import AppKit
import QuartzCore

struct StaticEffectConfiguration: Equatable {
    let effect: StaticEffect
    let amount: Double
    let speed: Double
    let size: Double
    let splashFrequency: Double
    let fireplace: Bool
    let fireplaceWidth: Double
    let fireplaceHeight: Double
    let fireplaceOffset: Double
    let decorations: Bool
    let lights: Bool
    let snowBehindWindows: Bool
    let wind: Double
    let ignitionChance: Double
    let smoke: Bool
    let ash: Bool
    let heatGlow: Bool
    init(preferences: PreferenceStore) {
        effect = preferences.staticEffect
        let keys = effect.options.map(\.1)
        amount = keys.isEmpty ? 0 : Double(preferences.int(keys[0])) / 100
        speed = keys.isEmpty ? 0 : Double(preferences.int(keys[effect == .snowStorm ? 2 : 1])) / 100
        size = keys.isEmpty ? 0 : Double(preferences.int(keys[effect == .snowStorm ? 1 : 2])) / 100
        splashFrequency = effect == .rain ? Double(preferences.int(.rainSplashFrequency)) / 100 : 0
        fireplace = effect == .snowStorm && preferences.bool(.stormFireplace)
        fireplaceWidth = Double(preferences.int(.stormFireplaceWidth)) / 100
        fireplaceHeight = Double(preferences.int(.stormFireplaceHeight))
        fireplaceOffset = Double(preferences.int(.stormFireplaceOffset)) / 100
        decorations = effect == .snowStorm && preferences.bool(.stormDecorations)
        lights = effect == .snowStorm && preferences.bool(.stormLights)
        snowBehindWindows = effect == .snowStorm && preferences.bool(.stormBehindWindows)
        wind = effect == .fireStorm ? Double(preferences.int(.fireWindStrength)) / 100 : 0
        ignitionChance = effect == .fireStorm ? Double(preferences.int(.fireIgnitionChance)) / 100 : 0
        smoke = effect == .fireStorm && preferences.bool(.fireSmoke)
        ash = effect == .fireStorm && preferences.bool(.fireAsh)
        heatGlow = effect == .fireStorm && preferences.bool(.fireHeatGlow)
    }
}

private final class StaticEffectPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct StaticEffectScreen: Equatable {
    let id: CGDirectDisplayID
    let frame: CGRect
    static var connected: [StaticEffectScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return StaticEffectScreen(id: id, frame: screen.frame)
        }
    }
}

/// Screen-wide decoration has no input capture. Fireflies use Core Animation;
/// Rain and Snow Storm own their drawing clocks only while selected.
final class StaticEffectsController {
    private let preferences: PreferenceStore
    private let reducedMotion: () -> Bool
    private let screens: () -> [StaticEffectScreen]
    private let present: (NSPanel, SnowStormWindow?) -> Void
    private let query: (Set<Int>, Double) -> [SnowStormWindow]
    private let automaticPlacement: Bool
    private var placementTimer: Timer?
    private var panelTargets: [CGDirectDisplayID: UInt64] = [:]
    private let fireplaceFactory: (() -> FireplaceController?)?
    private var panels: [CGDirectDisplayID: NSPanel] = [:]
    private var activeConfiguration: StaticEffectConfiguration?
    private var storm: SnowStormController?
    private var rain: RainEffectController?
    private var ignitions: FireStormIgnitions?
    private var retiringFireplaces: [FireplaceController] = []
    private var observers: [NSObjectProtocol] = []
    private var activeSession = true
    private var sleeping = false
    private var displaysAsleep = false
    private var stopped = false

    init(preferences: PreferenceStore,
         reducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         screens: @escaping () -> [StaticEffectScreen] = { StaticEffectScreen.connected },
         present: @escaping (NSPanel, SnowStormWindow?) -> Void = SnowStormController.orderField,
         query: @escaping (Set<Int>, Double) -> [SnowStormWindow] = SnowStormWindowQuery.read,
         automaticPlacement: Bool = true, fireplaceFactory: (() -> FireplaceController?)? = nil) {
        self.preferences = preferences; self.reducedMotion = reducedMotion
        self.screens = screens; self.present = present; self.query = query; self.automaticPlacement = automaticPlacement
        self.fireplaceFactory = fireplaceFactory
        observers.append(NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in self?.reconcile() })
        observers.append(NotificationCenter.default.addObserver(forName: .santaRequested, object: preferences, queue: .main) { [weak self] _ in self?.storm?.triggerSanta() })
        observers.append(NotificationCenter.default.addObserver(forName: .yetiRequested, object: preferences, queue: .main) { [weak self] _ in self?.storm?.triggerYeti() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.clear(); self?.reconcile()
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.reconcile() })
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.willSleepNotification { self.sleeping = true }
                else if name == NSWorkspace.screensDidSleepNotification { self.displaysAsleep = true }
                else { self.activeSession = false }
                self.reconcile()
            })
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if name == NSWorkspace.didWakeNotification { self.sleeping = false }
                else if name == NSWorkspace.screensDidWakeNotification { self.displaysAsleep = false }
                else { self.activeSession = true }
                self.reconcile()
            })
        }
        reconcile()
    }
    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        clear()
    }
    func shutdown() { stopped = true; clear() }
    func reconcile() {
        precondition(Thread.isMainThread)
        let configuration = StaticEffectConfiguration(preferences: preferences)
        guard !stopped, activeSession, !sleeping, !displaysAsleep, !preferences.bool(.suspended), !reducedMotion() else { clear(); return }
        guard activeConfiguration != configuration else { return }
        activeConfiguration = configuration
        if configuration.effect == .snowStorm {
            ignitions?.shutdown(); ignitions = nil
            rain?.shutdown(); rain = nil
            placementTimer?.invalidate(); placementTimer = nil; panelTargets.removeAll()
            for panel in panels.values { panel.orderOut(nil) }
            panels.removeAll()
            let settings = SnowStormSettings(snowfall: configuration.amount, maximumFlakeSize: configuration.size,
                                             gusts: configuration.speed, decorations: configuration.decorations, lights: configuration.lights,
                                             behindWindows: configuration.snowBehindWindows)
            if let storm { storm.update(settings: settings) }
            else { storm = SnowStormController(settings: settings, screens: screens,
                                               cursorShape: CursorSnowCapture.current(), fireplaceFactory: fireplaceFactory) }
            storm?.setFireplace(enabled: configuration.fireplace, widthFraction: configuration.fireplaceWidth,
                                height: configuration.fireplaceHeight, offset: configuration.fireplaceOffset)
            return
        }
        if let fireplace = storm?.takeFireplaceForDeparture() {
            if retiringFireplaces.count >= 2 { retiringFireplaces.removeFirst().shutdown() }
            retiringFireplaces.append(fireplace)
            fireplace.onFinished = { [weak self, weak fireplace] in
                guard let fireplace else { return }
                fireplace.shutdown()
                self?.retiringFireplaces.removeAll { $0 === fireplace }
            }
            fireplace.dissolveIndependently()
        }
        storm?.shutdown(); storm = nil
        if configuration.effect == .rain {
            ignitions?.shutdown(); ignitions = nil
            placementTimer?.invalidate(); placementTimer = nil; panelTargets.removeAll()
            for panel in panels.values { panel.orderOut(nil) }; panels.removeAll()
            if let rain { rain.update(configuration: configuration) }
            else { rain = RainEffectController(configuration: configuration, screens: screens, query: query,
                                               presentField: present, automaticTicks: automaticPlacement) }
            return
        }
        rain?.shutdown(); rain = nil
        if configuration.effect == .none {
            ignitions?.shutdown(); ignitions = nil
            placementTimer?.invalidate(); placementTimer = nil; panelTargets.removeAll()
            for panel in panels.values { panel.orderOut(nil) }; panels.removeAll()
            return
        }
        for screen in screens() {
            let id = screen.id
            let panel: NSPanel
            if let existing = panels[id] { panel = existing }
            else {
                panel = StaticEffectPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                panel.ignoresMouseEvents = true; panel.acceptsMouseMovedEvents = false
                panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.setAccessibilityHidden(true)
                let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.wantsLayer = true; view.layer?.masksToBounds = true
                view.setAccessibilityHidden(true); panel.contentView = view
                panels[id] = panel
            }
            panel.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let effectLayers: [CAEmitterLayer] = configuration.effect == .fireStorm
                ? FireStormLayers.make(configuration: configuration, bounds: bounds)
                : [Self.makeEmitter(configuration: configuration, bounds: bounds)]
            for emitter in effectLayers {
                panel.contentView?.layer?.addSublayer(emitter)
                let entrance = CABasicAnimation(keyPath: "opacity")
                entrance.fromValue = 0; entrance.toValue = 1; entrance.duration = 0.8
                emitter.add(entrance, forKey: "entrance")
            }
        }
        positionPanels()
        if configuration.effect == .fireStorm {
            if let ignitions { ignitions.update(configuration: configuration) }
            else { ignitions = FireStormIgnitions(configuration: configuration, screens: screens, query: query,
                                                  automaticTicks: automaticPlacement) }
        } else { ignitions?.shutdown(); ignitions = nil }
        if automaticPlacement && placementTimer == nil {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.positionPanels() }
            timer.tolerance = 0.03; RunLoop.main.add(timer, forMode: .common); placementTimer = timer
        }
    }
    private func positionPanels() {
        guard !panels.isEmpty else { return }
        let displays = screens()
        let excluded = Set(NSApp.windows.filter { !$0.styleMask.contains(.titled) }.map(\.windowNumber))
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? displays.first?.frame.maxY ?? 0
        let windows = query(excluded, desktopTop)
        for screen in displays {
            guard let panel = panels[screen.id] else { continue }
            let target = windows.first { $0.frame.intersects(screen.frame) }
            let key = target.map { UInt64($0.id) << 32 | UInt64(UInt32(bitPattern: Int32($0.level))) } ?? 0
            if panelTargets[screen.id] != key { present(panel, target); panelTargets[screen.id] = key }
        }
    }
    private func clear() {
        placementTimer?.invalidate(); placementTimer = nil; panelTargets.removeAll()
        for fireplace in retiringFireplaces { fireplace.shutdown() }; retiringFireplaces.removeAll()
        storm?.shutdown(); storm = nil
        rain?.shutdown(); rain = nil
        ignitions?.shutdown(); ignitions = nil
        for panel in panels.values {
            panel.contentView?.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            panel.orderOut(nil)
        }
        panels.removeAll(); activeConfiguration = nil
    }

    static func makeEmitter(configuration c: StaticEffectConfiguration, bounds: CGRect) -> CAEmitterLayer {
        let layer = CAEmitterLayer()
        layer.frame = bounds
        guard c.effect == .fireflies else { return layer }
        layer.emitterShape = .rectangle
        layer.emitterMode = .volume
        layer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.emitterSize = bounds.size
        let speed = 0.4 + c.speed * 1.8
        let cell = CAEmitterCell()
        cell.contents = sprite(for: c.effect)
        cell.name = c.effect.rawValue
        cell.scale = 0.12 + c.size * 0.35
        cell.scaleRange = cell.scale * 0.4
        cell.emissionLongitude = -.pi / 2
        cell.emissionRange = 0.18
        let budget: Double
        switch c.effect {
        case .none, .snowStorm, .rain, .fireStorm: return layer
        case .fireflies:
            cell.velocity = 12 * speed; cell.velocityRange = 8 * speed
            cell.emissionRange = .pi * 2
            cell.lifetime = Float(12 / speed)
            cell.color = NSColor(calibratedRed: 1, green: 0.91, blue: 0.3, alpha: 0.9).cgColor
            cell.alphaSpeed = -Float(0.8 / Double(cell.lifetime))
            budget = 15 + c.amount * 160
        }
        // Rate * lifetime bounds live particles independently of display size.
        cell.birthRate = Float(budget) / cell.lifetime
        layer.emitterCells = [cell]
        return layer
    }

    private static func sprite(for effect: StaticEffect) -> CGImage? {
        guard let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            NSColor.white.cgColor, NSColor.white.withAlphaComponent(effect == .fireflies ? 0.2 : 0.65).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ] as CFArray, locations: [0, 0.3, 1]) {
            let center = CGPoint(x: 16, y: 16)
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: effect == .fireflies ? 16 : 10, options: [])
        }
        return context.makeImage()
    }
    #if TESTING
    var panelsForTesting: [NSPanel] { Array(panels.values) + (storm?.allPanels ?? []) + (rain?.allPanels ?? []) + (ignitions?.panelsForTesting ?? []) }
    var stormForTesting: SnowStormController? { storm }
    var rainForTesting: RainEffectController? { rain }
    var retiringFireplacesForTesting: [FireplaceController] { retiringFireplaces }
    #endif
}
