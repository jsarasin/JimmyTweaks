import AppKit
import ImageIO

@main struct FireplaceFeatureCheck {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ text: String) { checks += 1; assert(condition(), text); print("PASS: " + text) }
    static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if CommandLine.arguments.contains("--performance") {
            performance()
            return
        }
        if CommandLine.arguments.contains("--headless") {
            try FireplaceTests.run(root: root)
            try settings(root: root)
            print("Focused fireplace layout and settings checks passed.")
            return
        }
        if CommandLine.arguments.contains("--layering") {
            try nativeLayering()
            print("Focused fireplace Window Server layering check finished.")
            return
        }
        guard let renderer = ProceduralEffects() else { fatalError("A Metal device is required for the smoke check") }
        let object = CGRect(x: 160, y: 40, width: 480, height: 128)
        let field = object.insetBy(dx: -140, dy: -160)
        var visible = false, escaped = false, neutral = true, final: [UInt8] = []
        for frame in 0...84 {
            let progress = Float(frame) / 84
            checkConfigure(renderer.configureSmokePuff(rect: field, object: object, progress: progress))
            _ = renderer.render(surfaces: [], at: Double(frame) / 60); renderer.waitForGPUForTesting()
            if [8, 24, 50, 84].contains(frame) {
                let pixels = renderer.snapshot(rect: field, width: 640, height: 400)!
                visible = visible || pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element > 20 }
                for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 10 {
                    neutral = neutral && abs(Int(pixels[i]) - Int(pixels[i + 1])) <= 1 && abs(Int(pixels[i + 1]) - Int(pixels[i + 2])) <= 1
                }
                if frame == 50 {
                    // The puff's area expands well beyond the original masonry.
                    for y in 0..<400 { for x in 0..<640 where pixels[(y * 640 + x) * 4 + 3] > 8 {
                        let world = CGPoint(x: field.minX + (Double(x) + 0.5) / 640 * field.width,
                                            y: field.maxY - (Double(y) + 0.5) / 400 * field.height)
                        if !object.insetBy(dx: -12, dy: -12).contains(world) { escaped = true }
                    } }
                }
                if frame == 84 { final = pixels }
            }
        }
        check(visible, "shared smoke renderer produces a visible poof from the fireplace footprint")
        check(neutral, "the departure is neutral grey from its first visible frame")
        check(escaped, "smoke expands and rises beyond the old brickwork")
        check(stride(from: 3, to: final.count, by: 4).allSatisfy { final[$0] == 0 }, "smoke ends fully transparent")
        try animation(root: root)
        try settings(root: root)
        try nativeLayering()
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let dock = FireplaceDockQuery.read(desktopTop: top)
        print("Read-only Dock lookup: \(dock.map { String(describing: $0.frame.size) } ?? "no visible Dock; fallback applies").")
        print("\(checks)/\(checks) Fireplace graphics/UI checks passed.")
    }
    static func checkConfigure(_ configured: Bool) { precondition(configured) }
    static func performance() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let layout = FireplaceLayout.resolve(screens: [screen], dock: nil,
                                               widthFraction: 0.8, height: 320)!
        let model = FireplaceModel(layout: layout); model.setEnabled(true)
        for _ in 0..<45 { model.advance(1.0 / 30) }
        let viewport = layout.frame.insetBy(dx: -6, dy: -6)
        let context = CGContext(data: nil, width: Int(viewport.width), height: Int(viewport.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let staticArt = FireplaceDrawing.staticImage(model)!
        let flameImages = (0..<3).compactMap { FireplaceDrawing.fireImage(model, layer: $0) }
        precondition(flameImages.count == 3)
        var simulation = 0.0, drawing = 0.0
        for _ in 0..<90 {
            let start = CFAbsoluteTimeGetCurrent()
            model.advance(1.0 / 30)
            let afterSimulation = CFAbsoluteTimeGetCurrent()
            context.clear(CGRect(origin: .zero, size: viewport.size))
            FireplaceDrawing.draw(model, context: context, worldRect: viewport,
                                  staticArt: staticArt, fireImages: flameImages)
            let afterDraw = CFAbsoluteTimeGetCurrent()
            simulation += afterSimulation - start
            drawing += afterDraw - afterSimulation
        }
        print(String(format: "Maximum-size fireplace: %.2f ms simulation, %.2f ms main-thread drawing per frame",
                     simulation / 90 * 1000, drawing / 90 * 1000))
        let rasterStart = CFAbsoluteTimeGetCurrent()
        for _ in 0..<90 {
            for layer in 0..<3 { _ = FireplaceDrawing.fireImage(model, layer: layer) }
        }
        print(String(format: "Three flame image builds on the worker: %.2f ms per frame",
                     (CFAbsoluteTimeGetCurrent() - rasterStart) / 90 * 1000))
    }
    static func image(_ bytes: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
    static func animation(root: URL) throws {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 500)
        var dock = FireplaceDock(frame: CGRect(x: 190, y: 8, width: 520, height: 60))
        let layout = FireplaceLayout.resolve(screens: [screen], dock: dock)!
        let model = FireplaceModel(layout: layout); model.setEnabled(true)
        let snow = SnowStormSimulation(seed: 19)
        let windows = [SnowStormWindow(id: 1, owner: 100, frame: CGRect(x: 130, y: 215, width: 440, height: 170), level: 0)]
        let settings = SnowStormSettings(snowfall: 0.45, maximumFlakeSize: 0.35, gusts: 0.3)
        for _ in 0..<300 { snow.advance(dt: 1.0 / 60, windows: windows, cursor: nil, screens: [screen], settings: settings) }
        let renderer = ProceduralEffects()!
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("fireplace-preview.gif") as CFURL, "com.compuserve.gif" as CFString, 151, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var first: CGImage?, burning: CGImage?, departed: CGImage?
        for i in 0...300 {
            if i >= 90 && i < 120 {
                let t = Double(i - 90) / 29
                dock = FireplaceDock(frame: CGRect(x: 190 - t * 80, y: 8, width: 520 + t * 160, height: 60 + t * 55))
            }
            if i == 150 { dock = FireplaceDock(frame: CGRect(x: 190, y: 8, width: 520, height: 60)) }
            if i < 180 { model.setLayout(FireplaceLayout.resolve(screens: [screen], dock: dock, previous: model.layout)!) }
            if i == 180 { model.setEnabled(false) }
            model.advance(1.0 / 60)
            snow.advance(dt: 1.0 / 60, windows: windows, cursor: nil, screens: [screen], settings: settings)
            var smoke: CGImage?
            if let progress = model.departureProgress {
                _ = renderer.configureSmokePuff(rect: model.layout.frame.insetBy(dx: -140, dy: -160), object: model.layout.frame, progress: Float(progress))
                _ = renderer.render(surfaces: [], at: Double(i) / 60); renderer.waitForGPUForTesting()
                if i % 2 == 0 { smoke = image(renderer.snapshot(rect: screen, width: 900, height: 500)!, width: 900, height: 500) }
            }
            guard i % 2 == 0 else { continue }
            let context = CGContext(data: nil, width: 900, height: 500, bitsPerComponent: 8, bytesPerRow: 3600,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.055, green: 0.11, blue: 0.17, alpha: 1)); context.fill(screen)
            FireplaceDrawing.draw(model, context: context, worldRect: screen)
            if let smoke { context.draw(smoke, in: screen) }
            for w in windows {
                context.setFillColor(CGColor(red: 0.2, green: 0.29, blue: 0.39, alpha: 1))
                context.addPath(CGPath(roundedRect: w.frame, cornerWidth: 10, cornerHeight: 10, transform: nil)); context.fillPath()
                if let drift = snow.drifts.first(where: { $0.window?.id == w.id }) { SnowStormDrawing.drift(drift, in: context, origin: .zero) }
            }
            SnowStormDrawing.flakes(snow.particles, windows: snow.windows, in: context, worldRect: screen, time: snow.time)
            // The Dock composites last: icons and its translucent shelf remain
            // visible in front of the complete fire/brick/smoke artwork.
            context.setFillColor(CGColor(gray: 0.5, alpha: 0.65)); context.addPath(CGPath(roundedRect: dock.frame, cornerWidth: 14, cornerHeight: 14, transform: nil)); context.fillPath()
            let stride = (dock.frame.width - 16) / 9
            for icon in 0..<9 {
                let color = NSColor(calibratedHue: Double(icon) / 9, saturation: 0.65, brightness: 0.9, alpha: 1)
                let size = min(stride - 12, dock.frame.height - 18), x = dock.frame.minX + 8 + Double(icon) * stride + (stride - size) / 2
                context.setFillColor(color.cgColor)
                context.addPath(CGPath(roundedRect: CGRect(x: x, y: 18, width: size, height: size), cornerWidth: 10, cornerHeight: 10, transform: nil)); context.fillPath()
                context.setFillColor(CGColor(gray: 1, alpha: 0.8)); context.fill(CGRect(x: x + size * 0.32, y: 18 + size * 0.26, width: size * 0.36, height: size * 0.44))
            }
            let frame = context.makeImage()!
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
            if [0, 18, 60, 150, 190, 220, 300].contains(i) {
                let still = CGImageDestinationCreateWithURL(root.appendingPathComponent("fireplace-\(i).png") as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(still, frame, nil); _ = CGImageDestinationFinalize(still)
            }
            if i == 0 { first = frame }; if i == 150 { burning = frame }; if i == 300 { departed = frame }
        }
        check(CGImageDestinationFinalize(destination), "open-bottom assembly, irregular fire, Dock expansion, and smoke departure export as an animation")
        check(first != nil && burning != nil && departed != nil && !model.isVisible, "the complete enable/disable cycle keeps Dock icons in front")
    }
    static func nativeLayering() throws {
        guard let screen = NSScreen.screens.first else {
            print("SKIP: Native Window Server layering requires a display.")
            return
        }
        let mock = NSPanel(contentRect: CGRect(x: screen.frame.midX - 250, y: screen.frame.minY + 8, width: 500, height: 76),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        mock.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        mock.ignoresMouseEvents = true; mock.orderFrontRegardless()
        let normal = NSPanel(contentRect: CGRect(x: screen.frame.midX - 180, y: screen.frame.minY + 90, width: 360, height: 130),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        normal.level = .normal; normal.ignoresMouseEvents = true; normal.orderFrontRegardless()
        let controller = FireplaceController(screens: { [StaticEffectScreen(id: 1, frame: screen.frame)] }, allowGPU: false)!
        defer { controller.shutdown(); mock.orderOut(nil); normal.orderOut(nil) }
        controller.updateDock(FireplaceDock(frame: mock.frame))
        for _ in 0..<60 { controller.advance(1.0 / 60) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
        let panel = controller.allPanels[0]
        let hearthIndex = ids.firstIndex(of: panel.windowNumber)
        check(hearthIndex != nil && ids.firstIndex(of: mock.windowNumber).map { $0 < hearthIndex! } == true &&
              ids.firstIndex(of: normal.windowNumber).map { $0 < hearthIndex! } == true,
              "Window Server places the hearth behind normal windows and the Dock")
        check(controller.model.layout.opening.applying(controller.model.layout.transform).contains(mock.frame), "the native Dock fixture fits between the walls and under the lintel")
        let old = controller.model.layout
        mock.setFrame(CGRect(x: mock.frame.minX - 100, y: mock.frame.minY, width: 700, height: 160), display: true)
        controller.updateDock(FireplaceDock(frame: mock.frame)); controller.advance(1.0 / 30)
        check(controller.model.layout.length > old.length && controller.model.layout.depth == old.depth &&
              panel.level.rawValue < mock.level.rawValue,
              "native Dock growth expands the width without changing height or moving in front")
        let image = FireplaceDrawing.fireImage(controller.model)!
        let bytes = image.dataProvider!.data! as Data
        var colors = Set<UInt32>()
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 20 {
            colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
        }
        check(image.shouldInterpolate && colors.count > 128, "the flame raster has continuous shading and smooth interpolation instead of pixel bands")
    }
    static func settings(root: URL) throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        prefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: prefs))
        let settings = SettingsWindowController(context: context); settings.showWindow(nil)
        context.navigate?(SearchDestination(page: .visualEffects, controlID: "visualEffects.static.effect"))
        let window = settings.window!; window.layoutIfNeeded()
        defer { window.orderOut(nil); context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown() }
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        let page = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? VisualEffectsPageController }.first!
        let toggle = page.controls["visualEffects.static.option.fireplace"] as! ActionButton
        let width = page.controls["visualEffects.static.option.fireplaceWidth"] as! NSSlider
        let height = page.controls["visualEffects.static.option.fireplaceHeight"] as! NSSlider
        let offset = page.controls["visualEffects.static.option.fireplaceOffset"] as! NSSlider
        let area = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.configuration" }!
        check(toggle.state == .off && toggle.isEnabled, "Snow Storm exposes an opt-in Fireplace checkbox")
        check(!width.isEnabled && width.minValue == 30 && width.maxValue == 80 && width.integerValue == 50,
              "Fireplace Width is disabled while Fireplace is off and spans thirty to eighty percent")
        check(!height.isEnabled && height.minValue == 80 && height.maxValue == 320 && height.integerValue == 158,
              "Fireplace Height is disabled while Fireplace is off and spans 80 to 320 points")
        check(!offset.isEnabled && offset.minValue == -100 && offset.maxValue == 100 && offset.integerValue == 0 &&
              offset.numberOfTickMarks == 3 && !offset.allowsTickMarkValuesOnly,
              "Fireplace Offset has continuous movement, a center tick, and a centered default")
        toggle.performClick(nil); page.refreshValues(); window.layoutIfNeeded()
        check(prefs.bool(.stormFireplace) && toggle.state == .on, "native checkbox action saves the Fireplace preference")
        check(width.isEnabled && height.isEnabled && offset.isEnabled, "turning on Fireplace enables its adjusters")
        width.integerValue = 80; _ = width.sendAction(width.action!, to: width.target)
        check(prefs.int(.stormFireplaceWidth) == 80, "the width adjuster saves its value immediately")
        height.integerValue = 260; _ = height.sendAction(height.action!, to: height.target)
        check(prefs.int(.stormFireplaceHeight) == 260, "the height adjuster saves its value immediately")
        offset.integerValue = 4; _ = offset.sendAction(offset.action!, to: offset.target)
        check(prefs.int(.stormFireplaceOffset) == 0 && offset.integerValue == 0, "offset snaps to zero near the center tick")
        offset.integerValue = 12; _ = offset.sendAction(offset.action!, to: offset.target)
        check(prefs.int(.stormFireplaceOffset) == 12, "offset remains continuous beyond the center snap zone")
        check(area.frame.height == 320 && area.bounds.contains(toggle.convert(toggle.bounds, to: area)) &&
              area.bounds.contains(width.convert(width.bounds, to: area)) &&
              area.bounds.contains(height.convert(height.bounds, to: area)) &&
              area.bounds.contains(offset.convert(offset.bounds, to: area)),
              "Fireplace controls fit the fixed-size configuration area")
        check(page.controls.filter { $0.key.hasPrefix("visualEffects.static.option.") }.values.allSatisfy {
            area.bounds.contains($0.convert($0.bounds, to: area))
        }, "all Snow Storm controls remain inside the fixed configuration area")
        check(context.catalog.search("fireplace").contains { $0.id == "visualEffects.static.option.fireplace" }, "Fireplace is searchable in Settings")
        check(context.catalog.search("fireplace width").contains { $0.id == "visualEffects.static.option.fireplaceWidth" },
              "Fireplace Width is searchable in Settings")
        check(context.catalog.search("fireplace height").contains { $0.id == "visualEffects.static.option.fireplaceHeight" },
              "Fireplace Height is searchable in Settings")
        check(context.catalog.search("fireplace offset").contains { $0.id == "visualEffects.static.option.fireplaceOffset" },
              "Fireplace Offset is searchable in Settings")
        let bitmap = area.bitmapImageRepForCachingDisplay(in: area.bounds)!
        area.cacheDisplay(in: area.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("snow-storm-fireplace-settings.png"))
        prefs.set(StaticEffect.rain.rawValue, for: .staticEffect); page.refreshValues()
        check(page.controls["visualEffects.static.option.fireplace"] == nil &&
              page.controls["visualEffects.static.option.fireplaceWidth"] == nil &&
              page.controls["visualEffects.static.option.fireplaceHeight"] == nil &&
              page.controls["visualEffects.static.option.fireplaceOffset"] == nil &&
              prefs.bool(.stormFireplace) && prefs.int(.stormFireplaceWidth) == 80 &&
              prefs.int(.stormFireplaceHeight) == 260 && prefs.int(.stormFireplaceOffset) == 12,
              "other Static effects hide fireplace controls while preserving their saved choices")
        prefs.set(StaticEffect.none.rawValue, for: .staticEffect); page.refreshValues(); window.layoutIfNeeded()
        check(views(area).contains { $0.identifier?.rawValue == "visualEffects.static.empty" } &&
              views(area).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Choose an effect for options to play with." },
              "No Effect shows a clear empty state in the configuration area")
    }
}
