import AppKit
import QuartzCore

@main struct FireStormFeatureCheck {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; assert(condition(), message)
        }
        let preferences = PreferenceStore(defaults: MemoryDefaults())
        preferences.set(StaticEffect.fireStorm.rawValue, for: .staticEffect)
        check(preferences.staticEffect == .fireStorm && StaticEffect.allCases.contains(.fireStorm),
              "Fire Storm persists as a Static selection")
        let standard = StaticEffectConfiguration(preferences: preferences)
        check(standard.amount == 0.5 && standard.speed == 0.5 && standard.size == 0.5 && standard.wind == 0 &&
              standard.ignitionChance == 0.15 &&
              standard.smoke && !standard.ash && standard.heatGlow,
              "Fire Storm starts without crosswind while other controls retain their defaults")
        let bounds = CGRect(x: 0, y: 0, width: 8000, height: 4000)
        let layers = FireStormLayers.make(configuration: standard, bounds: bounds)
        check(Set(layers.compactMap(\.name)) == Set(["fireStorm.flames", "fireStorm.sparks", "fireStorm.embers",
                                                       "fireStorm.smoke", "fireStorm.heatGlow"]),
              "Flames, sparks, embers, smoke, and heat glow have separate emitters")
        check(layers.allSatisfy { $0.emitterCells?.first?.contents != nil && $0.frame == bounds },
              "Every layer has visible art and follows its display")
        let calmEmbers = layers.first { $0.name == "fireStorm.embers" }!.emitterCells!.first!
        check(calmEmbers.emissionRange == 0 && calmEmbers.xAcceleration == 0 &&
              layers.allSatisfy { $0.animation(forKey: "gust") == nil },
              "Zero Wind Strength sends embers straight down without gust animations")
        check(Double(calmEmbers.lifetime) * Double(calmEmbers.velocity - calmEmbers.velocityRange) >= bounds.height + 119 &&
              Double(calmEmbers.alphaSpeed) * Double(calmEmbers.lifetime) > -1,
              "Slow embers stay visible long enough to cross a tall display")
        preferences.batch {
            preferences.set(100, for: .fireEmberDensity)
            preferences.set(100, for: .fireStormSpeed)
            preferences.set(100, for: .fireFlameHeight)
            preferences.set(100, for: .fireWindStrength)
            preferences.set(100, for: .fireIgnitionChance)
            preferences.set(true, for: .fireAsh)
        }
        let maximum = StaticEffectConfiguration(preferences: preferences)
        let full = FireStormLayers.make(configuration: maximum, bounds: bounds)
        check(full.filter { ["fireStorm.sparks", "fireStorm.embers", "fireStorm.smoke"].contains($0.name ?? "") }
              .allSatisfy { $0.animation(forKey: "gust") != nil } &&
              full.first { $0.name == "fireStorm.embers" }!.emitterCells!.first!.emissionRange > 0,
              "Increasing Wind Strength adds sideways motion and independent gusts")
        let totalParticles = full.reduce(0.0) { total, layer in
            total + Double(layer.emitterCells?.reduce(Float(0)) { $0 + $1.birthRate * $1.lifetime } ?? 0)
        }
        let ordinaryParticles = layers.reduce(0.0) { total, layer in
            total + Double(layer.emitterCells?.reduce(Float(0)) { $0 + $1.birthRate * $1.lifetime } ?? 0)
        }
        check(full.count == 6 && totalParticles > ordinaryParticles * 3 && totalParticles < 750,
              "Maximum density is much fuller while retaining a fixed particle budget")
        func cell(_ name: String, in layers: [CAEmitterLayer]) -> CAEmitterCell {
            layers.first { $0.name == name }!.emitterCells!.first!
        }
        check(cell("fireStorm.embers", in: full).birthRate > cell("fireStorm.embers", in: layers).birthRate &&
              cell("fireStorm.sparks", in: full).velocity > cell("fireStorm.sparks", in: layers).velocity &&
              cell("fireStorm.flames", in: full).scale > cell("fireStorm.flames", in: layers).scale,
              "Density, speed, and flame height affect the actual particle field")
        let fastEmbers = cell("fireStorm.embers", in: full)
        let compactField = FireStormLayers.make(configuration: maximum,
                                               bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let compactEmbers = cell("fireStorm.embers", in: compactField)
        check(fastEmbers.velocity >= 1_200 && fastEmbers.velocity - fastEmbers.velocityRange >= 1_000 &&
              fastEmbers.velocity > cell("fireStorm.embers", in: layers).velocity * 3 &&
              compactEmbers.lifetime <= 1 && compactEmbers.birthRate * compactEmbers.lifetime <= 220,
              "At 100% even the slowest falling embers cross a normal display quickly, with a bounded live count")
        let emberArt = FireStormLayers.previewSprites.first { $0.0 == "ember" }!.1
        let emberBitmap = NSBitmapImageRep(cgImage: emberArt)
        let alphas = Set((0..<emberBitmap.pixelsHigh).flatMap { y in
            (0..<emberBitmap.pixelsWide).map { x in Int((emberBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255) }
        })
        check(alphas == Set([0, 255]) && fastEmbers.spinRange == 0,
              "Falling embers use hard-edged opaque pixel art without rotation blur")
        preferences.batch {
            preferences.set(false, for: .fireSmoke)
            preferences.set(false, for: .fireAsh)
            preferences.set(false, for: .fireHeatGlow)
        }
        check(FireStormLayers.make(configuration: StaticEffectConfiguration(preferences: preferences), bounds: bounds).count == 3,
              "Each checkbox removes its optional visual layer")
        let screen = CGRect(x: 0, y: 0, width: 900, height: 700)
        let foreground = SnowStormWindow(id: 10, owner: 10, frame: CGRect(x: 0, y: 0, width: 900, height: 700), level: 0)
        let roof = SnowStormWindow(id: 11, owner: 11, frame: CGRect(x: 100, y: 100, width: 500, height: 300), level: 0)
        let strike = FireStormIgnitionSimulation.Ember(position: CGPoint(x: 300, y: 420), velocity: CGVector(dx: 0, dy: -300))
        let calm = FireStormIgnitionSimulation(random: { 0.75 })
        calm.advance(dt: 0.2, screen: screen, windows: [], configuration: standard)
        check(!calm.embers.isEmpty && calm.embers.allSatisfy { $0.velocity.dx == 0 },
              "Roof-ignition samples also fall vertically when Wind Strength is zero")
        preferences.set(0, for: .fireIgnitionChance)
        let noFire = FireStormIgnitionSimulation(random: { 0.5 })
        noFire.insertEmber(strike)
        noFire.advance(dt: 0.1, screen: screen, windows: [foreground, roof], configuration: StaticEffectConfiguration(preferences: preferences))
        check(noFire.burns.isEmpty, "Zero ignition chance never lights a roof")
        preferences.set(100, for: .fireIgnitionChance)
        let fire = FireStormIgnitionSimulation(random: { 0.5 })
        fire.insertEmber(strike)
        fire.advance(dt: 0.1, screen: screen, windows: [foreground, roof], configuration: StaticEffectConfiguration(preferences: preferences))
        check(fire.burns.count == 1 && fire.burns[0].windowID == roof.id && fire.burns[0].localX == 200,
              "A certain roof strike starts a fire anchored to the window")
        let movedRoof = SnowStormWindow(id: roof.id, owner: roof.owner,
                                        frame: roof.frame.offsetBy(dx: 120, dy: 40), level: 0)
        fire.advance(dt: 0.1, screen: screen, windows: [foreground, movedRoof],
                     configuration: StaticEffectConfiguration(preferences: preferences))
        check(fire.burns.first?.localX == 200, "A moving window retains the fire at the same roof position")
        let flameLayer = FireStormLayers.windowFire(in: screen)
        check(flameLayer.emitterCells?.count == 2 && flameLayer.name == "fireStorm.windowFire",
              "A roof fire erupts with both flames and sparks")
        FireStormLayers.extinguish(flameLayer)
        check(flameLayer.emitterCells?.first?.name == "windowSmoke", "Extinguishing replaces the fire with smoke")
        preferences.set(0, for: .fireIgnitionChance)
        let noIgnition = StaticEffectConfiguration(preferences: preferences)
        for _ in 0..<34 { fire.advance(dt: 0.2, screen: screen, windows: [foreground, movedRoof], configuration: noIgnition) }
        check(fire.burns.isEmpty, "The fire exhausts its fuel and its smoke dissipates")
        let display = StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900))
        let front = SnowStormWindow(id: 31, owner: 31, frame: CGRect(x: 100, y: 80, width: 700, height: 500), level: 0)
        var targets: [UInt32?] = []
        let controller = StaticEffectsController(preferences: preferences, reducedMotion: { false },
            screens: { [display] }, present: { _, window in targets.append(window?.id) },
            query: { _, _ in [front] }, automaticPlacement: false)
        check(controller.panelsForTesting.count == 1 && targets == [front.id] &&
              controller.panelsForTesting[0].ignoresMouseEvents,
              "The click-through field is placed behind the frontmost window")
        preferences.set(true, for: .fireSmoke); controller.reconcile()
        check(controller.panelsForTesting[0].contentView?.layer?.sublayers?.count == 4,
              "Changing an option rebuilds the active field immediately")
        preferences.set(true, for: .suspended); controller.reconcile()
        check(controller.panelsForTesting.isEmpty && preferences.staticEffect == .fireStorm,
              "Suspend All removes Fire Storm without forgetting the selection")
        controller.shutdown()

        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false },
            requestEventPosting: { false }, checkListening: { false }, requestListening: { false },
            checkScreenRecording: { false })
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: preferences, permissions: permissions,
            runtime: runtime, logger: logger, login: LoginService(preferences: preferences))
        let settings = SettingsWindowController(context: context)
        context.navigate?(SearchDestination(page: .visualEffects, controlID: ""))
        let window = settings.window!
        window.layoutIfNeeded()
        let page = window.contentViewController!.children.flatMap(\.children)
            .compactMap { $0 as? VisualEffectsPageController }.first!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let area = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.configuration" }!
        check((page.controls["visualEffects.static.effect"] as? ActionPopup)?.itemTitles.contains("Fire Storm") == true &&
              views(area).compactMap { $0 as? NSSlider }.count == 5,
              "Fire Storm appears in the picker with five sliders")
        check(page.controls["visualEffects.static.option.windowignition"] is NSSlider,
              "Window ignition chance has its own slider")
        check(["smoke", "fallingAsh", "heatGlow"].allSatisfy {
            page.controls["visualEffects.static.option.\($0)"] is ActionButton
        }, "Three optional feature switches appear in the configuration area")
        let ashButton = page.controls["visualEffects.static.option.fallingAsh"] as! ActionButton
        ashButton.performClick(nil)
        check(preferences.bool(.fireAsh), "Clicking a feature switch saves its choice")
        check(views(area).compactMap { $0 as? NSSlider }.allSatisfy {
            area.bounds.contains($0.convert($0.bounds, to: area))
        }, "Every slider fits inside the fixed settings area")
        check(views(area).compactMap { $0 as? ActionButton }.allSatisfy {
            area.bounds.contains($0.convert($0.bounds, to: area))
        }, "The feature switches fit inside the fixed settings area")
        let slider = page.controls["visualEffects.static.option.emberdensity"] as! NSSlider
        slider.integerValue = 63; _ = slider.sendAction(slider.action!, to: slider.target)
        check(preferences.int(.fireEmberDensity) == 63, "Slider changes are saved immediately")
        window.orderOut(nil); context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown()
        try preview(root: root)
        print("\(checks) Fire Storm checks passed: controls, independent layers, particle budget, and lifecycle.")
    }

    private static func preview(root: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 720, height: 260)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720, pixelsHigh: 260,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.setFillColor(NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.08, alpha: 1).cgColor)
        context.fill(bounds)
        for (index, sample) in FireStormLayers.previewSprites.enumerated() {
            let x = 25 + Double(index) * 115
            let image = sample.1
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: x, y: 70,
                width: Double(image.width) * 1.5, height: Double(image.height) * 1.5))
            (sample.0 as NSString).draw(at: CGPoint(x: x, y: 35),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                                 .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("fire-storm-particles.png"))
    }
}
