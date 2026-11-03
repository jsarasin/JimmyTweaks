import AppKit

@main struct RainFeatureCheck {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = PreferenceStore(defaults: MemoryDefaults())
        prefs.set(StaticEffect.rain.rawValue, for: .staticEffect)
        prefs.set(65, for: .rainAmount)
        let configuration = StaticEffectConfiguration(preferences: prefs)
        precondition(prefs.int(.rainSplashFrequency) == 50 &&
                     RainEffectSimulation.splashChance(frequency: configuration.splashFrequency) == 0.5 &&
                     RainEffectSimulation.splashChance(frequency: 0) == 0 &&
                     RainEffectSimulation.splashChance(frequency: 1) == 1,
                     "Splash frequency is the literal percentage chance of a window-top hit splashing")
        precondition(RainDropPixels.height(slider: 0.01, variation: 0.7) == 1 &&
                     RainDropPixels.height(slider: 1, variation: 1.3) == 20 &&
                     RainDropPixels.images.count == 20 && RainDropPixels.images.last?.height == 20,
                     "Drop size ranges from a one-pixel dot to a 20-pixel teardrop")
        let screen = StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let window = SnowStormWindow(id: 41, owner: 99, frame: CGRect(x: 80, y: 40, width: 480, height: 240), level: 0)
        let quietPrefs = PreferenceStore(defaults: MemoryDefaults())
        quietPrefs.set(StaticEffect.rain.rawValue, for: .staticEffect)
        quietPrefs.set(0, for: .rainSplashFrequency)
        let middlePrefs = PreferenceStore(defaults: MemoryDefaults())
        middlePrefs.set(StaticEffect.rain.rawValue, for: .staticEffect)
        let frequentPrefs = PreferenceStore(defaults: MemoryDefaults())
        frequentPrefs.set(StaticEffect.rain.rawValue, for: .staticEffect)
        frequentPrefs.set(100, for: .rainSplashFrequency)
        let quiet = RainEffectSimulation(seed: 47), middle = RainEffectSimulation(seed: 47),
            frequent = RainEffectSimulation(seed: 47)
        var frequentSplashFrames = 0
        for _ in 0..<180 {
            quiet.advance(dt: 1.0 / 60, screens: [screen], windows: [window],
                          configuration: StaticEffectConfiguration(preferences: quietPrefs))
            middle.advance(dt: 1.0 / 60, screens: [screen], windows: [window],
                           configuration: StaticEffectConfiguration(preferences: middlePrefs))
            frequent.advance(dt: 1.0 / 60, screens: [screen], windows: [window],
                             configuration: StaticEffectConfiguration(preferences: frequentPrefs))
            if !frequent.splashes.isEmpty { frequentSplashFrames += 1 }
        }
        let middleRate = Double(middle.splashInteractions) / Double(max(1, middle.windowTopHits))
        precondition(quiet.windowTopHits > 0 && quiet.splashInteractions == 0 && quiet.splashes.isEmpty &&
                     middle.windowTopHits > 0 && (0.35...0.65).contains(middleRate) &&
                     frequent.windowTopHits > 0 && frequent.splashInteractions == frequent.windowTopHits &&
                     frequentSplashFrames > 0,
                     "0%, 50%, and 100% cause none, roughly half, and every window-top hit to splash")
        var fieldTargets: [UInt32?] = []
        var splashPresentations = 0
        let rain = RainEffectController(configuration: configuration, screens: { [screen] }, query: { _, _ in [window] },
                                        presentField: { _, target in fieldTargets.append(target?.id) },
                                        presentSplash: { _, target in if target?.id == window.id { splashPresentations += 1 } },
                                        automaticTicks: false)
        defer { rain.shutdown() }
        precondition(fieldTargets == [window.id] && rain.allPanels.contains { $0.frame == screen.frame },
                     "Rain must create a field behind the front window immediately")
        precondition(!rain.simulation.drops.isEmpty && rain.simulation.drops.count <= RainEffectSimulation.maximumDropsPerScreen,
                     "Rain must have bounded visible drops on its first frame")
        let firstPositions = rain.simulation.drops.map(\.position)
        var maxSplashes = 0
        var splashImage: CGImage?
        for _ in 0..<180 {
            rain.advanceForTesting(dt: 1.0 / 60)
            if rain.simulation.splashes.count > maxSplashes {
                maxSplashes = rain.simulation.splashes.count
                let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                RainEffectDrawing.splashes(rain.simulation.splashes, on: window, in: context, origin: .zero)
                splashImage = context.makeImage()
            }
        }
        precondition(rain.simulation.drops.map(\.position) != firstPositions, "Rain drops must fall visibly")
        precondition(maxSplashes > 0 && splashPresentations > 0, "Window-top impacts must produce occasional visible splash overlays")
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        RainEffectDrawing.drops(rain.simulation.drops, on: screen, configuration: configuration, in: context)
        let image = context.makeImage()!
        func paintedPixels(_ image: CGImage) -> Int {
            let rep = NSBitmapImageRep(cgImage: image)
            return stride(from: 0, to: rep.pixelsHigh, by: 4).reduce(0) { count, y in
                count + stride(from: 0, to: rep.pixelsWide, by: 4).filter { x in
                    (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.15
                }.count
            }
        }
        precondition(paintedPixels(image) > 50, "Rain renderer must paint visible pixel raindrops")
        precondition(splashImage.map(paintedPixels) ?? 0 > 4, "Splash renderer must paint impact arcs")
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            .write(to: root.appendingPathComponent("rain-preview.png"))
        try NSBitmapImageRep(cgImage: splashImage!).representation(using: .png, properties: [:])!
            .write(to: root.appendingPathComponent("rain-splash-preview.png"))
        prefs.set(100, for: .rainSize)
        let largest = StaticEffectConfiguration(preferences: prefs)
        let largeContext = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        RainEffectDrawing.drops(rain.simulation.drops, on: screen, configuration: largest, in: largeContext)
        let largeImage = largeContext.makeImage()!
        precondition(paintedPixels(largeImage) > paintedPixels(image), "Larger drops paint more area than medium drops")
        try NSBitmapImageRep(cgImage: largeImage).representation(using: .png, properties: [:])!
            .write(to: root.appendingPathComponent("rain-large-drops-preview.png"))
        let gallery = CGContext(data: nil, width: 520, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        gallery.setFillColor(CGColor(red: 0.04, green: 0.09, blue: 0.16, alpha: 1))
        gallery.fill(CGRect(x: 0, y: 0, width: 520, height: 180))
        gallery.interpolationQuality = .none
        for (index, height) in [1, 4, 8, 12, 16, 20].enumerated() {
            let sprite = RainDropPixels.images[height - 1]
            gallery.draw(sprite, in: CGRect(x: 28 + index * 82, y: 52,
                                            width: sprite.width * 6, height: sprite.height * 6))
        }
        try NSBitmapImageRep(cgImage: gallery.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: root.appendingPathComponent("rain-drop-sizes.png"))
        rain.shutdown()
        precondition(rain.allPanels.isEmpty && !rain.timerRunningForTesting, "Stopping Rain removes its overlays and clock")
        let wrapper = StaticEffectsController(preferences: prefs, reducedMotion: { false }, screens: { [screen] },
                                              present: { _, _ in }, query: { _, _ in [] }, automaticPlacement: false)
        precondition(wrapper.rainForTesting != nil && !wrapper.panelsForTesting.isEmpty,
                     "Selecting Rain starts the direct renderer")
        let runningRain = wrapper.rainForTesting
        prefs.set(100, for: .rainSplashFrequency)
        precondition(wrapper.rainForTesting === runningRain,
                     "Changing splash frequency updates Rain without restarting its controller")
        prefs.set(StaticEffect.none.rawValue, for: .staticEffect)
        wrapper.reconcile()
        precondition(wrapper.rainForTesting == nil && wrapper.panelsForTesting.isEmpty,
                     "No Effect stops Rain and removes its surfaces")
        wrapper.shutdown()
        try checkSettings(root: root)
        print("Rain checks passed: immediate drops, falling motion, adjustable window splashes, visible rendering, and cleanup.")
    }
    private static func checkSettings(root: URL) throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults())
        prefs.set(StaticEffect.rain.rawValue, for: .staticEffect)
        prefs.set(true, for: .suspended)
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false },
                                                checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger,
                                      login: LoginService(preferences: prefs))
        let settings = SettingsWindowController(context: context); settings.showWindow(nil)
        context.navigate?(SearchDestination(page: .visualEffects, controlID: "visualEffects.static.effect"))
        let window = settings.window!; window.layoutIfNeeded()
        defer { window.orderOut(nil); context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown() }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let page = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? VisualEffectsPageController }.first!
        let slider = page.controls["visualEffects.static.option.splashfrequency"] as! NSSlider
        let area = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.configuration" }!
        precondition(slider.minValue == 0 && slider.maxValue == 100 && slider.integerValue == 50 &&
                     views(area).compactMap { $0 as? NSSlider }.count == 4 &&
                     area.bounds.contains(slider.convert(slider.bounds, to: area)),
                     "Rain settings show a splash frequency slider inside the fixed options area")
        slider.integerValue = 0; _ = slider.sendAction(slider.action!, to: slider.target)
        precondition(prefs.int(.rainSplashFrequency) == 0 &&
                     context.catalog.search("Splash frequency").contains { $0.id == "visualEffects.static.option.splashfrequency" },
                     "Splash frequency is saved and searchable")
    }
}
