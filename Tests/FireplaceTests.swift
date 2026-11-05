import AppKit

enum FireplaceTests {
    static func run(root: URL) throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { checks += 1; assert(value(), "Fireplace: " + label) }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let dock = FireplaceDock(frame: CGRect(x: 380, y: 8, width: 680, height: 76))
        let layout = FireplaceLayout.resolve(screens: [screen], dock: dock)!
        check(layout.edge == .bottom && layout.frame.width > dock.frame.width && layout.frame.maxY > dock.frame.maxY, "the hearth covers and slightly exceeds a visible bottom Dock")
        check(abs(layout.frame.width - dock.frame.width * 1.3) < 0.01, "the initial surround is thirty percent wider than the Dock")
        check(layout.opening.applying(layout.transform).maxY >= dock.frame.maxY + 16, "the entire Dock fits below the top bricks with clearance")
        check(layout.opening.minX == 18 && layout.length - layout.opening.maxX == 18,
              "both side walls are eighteen points wide")
        check(FireplaceLayout.mantelHeight == 30 && layout.mantelBase + FireplaceLayout.mantelHeight == layout.depth - FireplaceLayout.decorationHeight,
              "the wooden mantlepiece occupies thirty points below its decorations")
        check(abs(layout.logBed.width / layout.length - 0.8) < 0.001 &&
              abs(layout.flameRect.width / layout.length - 0.8) < 0.001 &&
              layout.flameRect.minY >= layout.logBed.minY &&
              layout.flameRect.minY <= layout.logBed.maxY,
              "the centred logs and flames each span eighty percent of the fireplace width")
        let visibleLog = layout.logBed.applying(layout.transform)
        check(visibleLog.minY < dock.frame.maxY && abs(visibleLog.maxY - dock.frame.maxY - 8) < 0.01,
              "only the upper eight points of the logs peek above the Dock")
        check(abs(layout.frame.midX - dock.frame.midX) < 0.01 && screen.contains(layout.frame), "the hearth stays centred and inside its display")
        let fallback = FireplaceLayout.resolve(screens: [screen], dock: nil)!
        check(fallback.frame.width == screen.width * 0.5 && fallback.frame.minY == screen.minY, "missing/hidden Dock uses the saved fifty-percent width")
        let farLeft = FireplaceLayout.resolve(screens: [screen], dock: nil, offset: -1)!
        let farRight = FireplaceLayout.resolve(screens: [screen], dock: nil, offset: 1)!
        check(abs(fallback.frame.midX - screen.midX) < 0.01 && farLeft.frame.minX == screen.minX + 6 &&
              farRight.frame.maxX == screen.maxX - 6, "zero centers the fireplace and either offset end reaches its display edge")
        check(abs(fallback.logBed.maxY - 8) < 0.01, "without a Dock only the log tips rise above the screen edge")
        let fallbackPreview = FireplaceModel(layout: fallback)
        fallbackPreview.setEnabled(true)
        for _ in 0..<60 { fallbackPreview.advance(1.0 / 60) }
        try snapshot(model: fallbackPreview, file: root.appendingPathComponent("fireplace-no-dock.png"))
        let narrow = FireplaceLayout.resolve(screens: [screen], dock: nil, widthFraction: 0.3)!
        let wide = FireplaceLayout.resolve(screens: [screen], dock: nil, widthFraction: 0.8)!
        check(narrow.frame.width == screen.width * 0.3 && wide.frame.width == screen.width * 0.8,
              "width adjustment spans thirty to eighty percent of the display")
        let low = FireplaceLayout.resolve(screens: [screen], dock: dock, height: 80)!
        let high = FireplaceLayout.resolve(screens: [screen], dock: dock, height: 320)!
        check(low.depth == 80 && high.depth == 320,
              "height adjustment spans eighty to three hundred twenty points with a visible Dock")
        let dockAware = FireplaceLayout.resolve(screens: [screen], dock: dock, widthFraction: 0.3)!
        check(dockAware.frame.width >= dock.frame.width * 1.3,
              "the Dock still fits when the selected width is too narrow")
        check(FireplaceLayout.resolve(screens: [screen], dock: FireplaceDock(frame: CGRect(x: 380, y: -74, width: 680, height: 76))) == fallback, "an auto-hidden sliver is not mistaken for a visible Dock")
        check(FireplaceLayout.resolve(screens: [], dock: nil) == nil, "no display creates no fireplace")
        let zoomed = FireplaceDock(frame: CGRect(x: 300, y: 8, width: 840, height: 170))
        let grown = FireplaceLayout.resolve(screens: [screen], dock: zoomed, previous: layout)!
        check(grown.length > layout.length && grown.depth == layout.depth,
              "Dock magnification grows the width while preserving the chosen height")
        let restored = FireplaceLayout.resolve(screens: [screen], dock: dock, previous: grown)!
        check(restored.frame == grown.frame && abs(restored.dockOcclusion - (dock.frame.maxY - screen.minY)) < 0.01,
              "the surround keeps its larger size while log tips follow the smaller Dock")
        let addedIcons = FireplaceDock(frame: CGRect(x: 180, y: 8, width: 1080, height: 76))
        let expanded = FireplaceLayout.resolve(screens: [screen], dock: addedIcons, previous: grown)!
        check(expanded.length > grown.length && expanded.opening.applying(expanded.transform).contains(addedIcons.frame), "additional icons expand beyond the old horizontal confines")
        let hiddenDock = FireplaceLayout.resolve(screens: [screen], dock: nil, previous: expanded)!
        check(hiddenDock.frame == expanded.frame && hiddenDock.dockOcclusion == 0,
              "auto-hide keeps the surround while the log tips return to the screen edge")
        let adjusted = FireplaceLayout.resolve(screens: [screen], dock: zoomed, previous: grown, height: 240)!
        check(adjusted.depth == 240 && adjusted.length == grown.length,
              "changing height keeps the existing width even after Dock magnification")
        let trackingModel = FireplaceModel(layout: grown), originalHeat = trackingModel.fireHeat
        trackingModel.setLayout(restored)
        check(trackingModel.fireHeat == originalHeat, "tracking Dock height leaves the running flame simulation intact")
        let cycling = FireplaceController(screens: { [StaticEffectScreen(id: 1, frame: screen)] }, present: { _ in }, allowGPU: false)!
        cycling.updateDock(zoomed)
        cycling.updateDock(dock)
        check(cycling.model.layout.length == grown.length, "a live fireplace retains its magnified Dock envelope")
        for finishDeparture in [false, true] {
            cycling.updateDock(zoomed)
            cycling.setEnabled(false)
            if finishDeparture { for _ in 0..<45 { cycling.advance(1.0 / 30) } }
            cycling.setEnabled(true)
            cycling.updateDock(dock)
            check(cycling.model.layout.length == layout.length,
                  "a new enable cycle resets the retained width, including during smoke departure")
            check(cycling.smokeCountForTesting > 0 || finishDeparture,
                  "resetting the width preserves any smoke that is still departing")
        }
        cycling.shutdown()
        let leftScreen = CGRect(x: -1280, y: -200, width: 1280, height: 800)
        for edge in [FireplaceLayout.Edge.left, .right] {
            let d = FireplaceDock(frame: CGRect(x: edge == .left ? leftScreen.minX : leftScreen.maxX - 70, y: -100, width: 70, height: 560))
            let side = FireplaceLayout.resolve(screens: [screen, leftScreen], dock: d)!
            check(side.screen == leftScreen && side.edge == edge && side.frame.height > d.frame.height, "side Docks select the correct display, including negative coordinates")
            let sideBottom = FireplaceLayout.resolve(screens: [screen, leftScreen], dock: d, offset: -1)!
            let sideTop = FireplaceLayout.resolve(screens: [screen, leftScreen], dock: d, offset: 1)!
            check(sideBottom.frame.minY == leftScreen.minY + 6 && sideTop.frame.maxY == leftScreen.maxY - 6,
                  "offset reaches the vertical display edges with a side Dock")
            let transformed = CGRect(x: 0, y: 0, width: side.length, height: side.depth).applying(side.transform)
            check(WindowGeometry.approximatelyEqual(transformed, side.frame), "canonical pixel fire maps correctly to either side Dock")
        }
        let model = FireplaceModel(layout: layout)
        check(!model.isVisible, "a new model is absent until enabled")
        model.setEnabled(true)
        check(model.phase == .assembling && model.bricks.count > 20 && model.bricks.count < 350, "enabling creates a bounded set of masonry pieces")
        check(model.bricks.allSatisfy { !screen.contains($0.start) }, "all bricks start beyond a screen edge")
        check(model.bricks.allSatisfy {
            let rect = $0.target.applying(layout.transform.inverted())
            return rect.maxX <= layout.opening.minX || rect.minX >= layout.opening.maxX || rect.minY >= layout.opening.maxY
        }, "masonry has only side walls and a lintel, with no bricks across the bottom")
        check(model.bricks.allSatisfy { $0.target.applying(layout.transform.inverted()).maxY <= layout.mantelBase } &&
              layout.mantelBase - layout.opening.maxY == FireplaceLayout.topBrickHeight,
              "only a slim brick course sits beneath the mantel")
        let initial = model.poses()
        for _ in 0..<15 { model.advance(1.0 / 60) }
        check(zip(initial, model.poses()).contains { $0.0.rect != $0.1.rect }, "bricks rapidly travel toward their target positions")
        for _ in 0..<45 { model.advance(1.0 / 60) }
        check(model.phase == .burning && model.poses().allSatisfy { $0.alpha == 1 && abs($0.angle) < 0.001 }, "assembly finishes within one second")
        let pixelsWide = Int(ceil(layout.length)), pixelsHigh = Int(ceil(layout.depth))
        let transparent = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                    bytesPerRow: pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        FireplaceDrawing.draw(model, context: transparent, worldRect: layout.frame)
        let bytes = transparent.data!.assumingMemoryBound(to: UInt8.self)
        let clearColumn = Int(layout.length * 0.34)
        let clearRows = (0..<pixelsHigh).filter { bytes[($0 * pixelsWide + clearColumn) * 4 + 3] == 0 }.count
        check(clearRows >= 12, "space above the mantel stays transparent instead of drawing a dark strip")
        check(zip(model.bricks, model.poses()).allSatisfy { WindowGeometry.approximatelyEqual($0.0.target, $0.1.rect, tolerance: 0.001) }, "settled bricks align without gaps in the planned frame")
        let heat = model.fireHeat, oldTime = model.time
        for _ in 0..<60 { model.advance(1.0 / 60) }
        check(abs(model.time - oldTime - FireplaceModel.fireAnimationSpeed) < 0.001 &&
              FireplaceModel.fireAnimationSpeed > 1,
              "the fire's heat, ember, and log animation clocks run faster than real time")
        check(model.fireHeat != heat && model.fireHeat.contains { $0 > 0.7 } && model.fireHeat.contains { $0 < 0.2 }, "unrelated fuel pockets evolve through hot cores and cooler tips")
        var flameUpdates = 0
        for _ in 0..<30 {
            let before = model.fireHeat
            model.advance(1.0 / 30)
            if model.fireHeat != before { flameUpdates += 1 }
        }
        check(flameUpdates >= 28, "faster flames update on nearly every display frame")
        check(model.fireHeat.count <= 144 * 60 && model.fireHeat.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1.1 }, "long-running turbulent fire remains finite and bounded")
        let artwork = FireplaceDrawing.staticImage(model)!
        let viewport = artwork.frame
        let readyFlames = (0..<3).compactMap { FireplaceDrawing.fireImage(model, layer: $0) }
        check(readyFlames.count == 3, "all flame layers can be prepared from one heat snapshot")
        func render(staticArt: (image: CGImage, frame: CGRect)?, fireImages: [CGImage]? = nil) -> [UInt8] {
            let width = Int(viewport.width), height = Int(viewport.height)
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            FireplaceDrawing.draw(model, context: context, worldRect: viewport,
                                  staticArt: staticArt, fireImages: fireImages)
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self),
                                             count: width * height * 4))
        }
        let direct = render(staticArt: nil), cached = render(staticArt: artwork, fireImages: readyFlames)
        let changedPixels = stride(from: 0, to: direct.count, by: 4).filter { offset in
            (0..<4).contains { abs(Int(direct[offset + $0]) - Int(cached[offset + $0])) > 4 }
        }.count
        check(changedPixels < direct.count / 400, "cached brickwork and worker flame images preserve the visible artwork")
        check(FireplaceDrawing.hasBackdropForTesting, "the pixel firebrick backdrop is available to the renderer")
        let backFlames = NSBitmapImageRep(cgImage: FireplaceDrawing.fireImage(model, layer: 0)!)
        let middleFlames = NSBitmapImageRep(cgImage: FireplaceDrawing.fireImage(model, layer: 1)!)
        check(backFlames.representation(using: .png, properties: [:]) != middleFlames.representation(using: .png, properties: [:]),
              "the back and middle flame layers have different turbulent shapes")
        let columns = model.columns
        check(FireplaceDrawing.edgeOpacity(column: 0, count: columns) == 0 &&
              FireplaceDrawing.edgeOpacity(column: columns - 1, count: columns) == 0 &&
              FireplaceDrawing.edgeOpacity(column: columns / 20, count: columns) > 0 &&
              FireplaceDrawing.edgeOpacity(column: columns / 20, count: columns) < 1 &&
              FireplaceDrawing.edgeOpacity(column: columns / 2, count: columns) == 1,
              "flame opacity eases in from both sides before reaching the bright centre")
        for layer in 0..<3 {
            let image = FireplaceDrawing.fireImage(model, layer: layer)!
            let bytes = image.dataProvider!.data! as Data
            let edgeIsClear = (0..<image.height).allSatisfy { row in
                bytes[(row * image.width) * 4 + 3] == 0 &&
                bytes[(row * image.width + image.width - 1) * 4 + 3] == 0
            }
            check(edgeIsClear && stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 },
                  "flame layer \(layer) has transparent side edges and visible interior")
        }
        var differences = Set<Int>()
        for _ in 0..<45 {
            let before = model.fireHeat
            model.advance(1.0 / 15)
            differences.insert(Int(zip(before, model.fireHeat).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } * 100))
        }
        check(differences.count > 35, "flame evolution does not repeat a short uniform oscillation")
        try snapshot(model: model, file: root.appendingPathComponent("fireplace-burning.png"))
        try snapshot(model: model, dock: dock, file: root.appendingPathComponent("fireplace-with-dock.png"))
        model.setEnabled(false)
        check(model.phase == .dissolving && model.departureProgress == 0, "turning off starts a finite departure")
        model.advance(1.0 / 60)
        check(model.poses().contains { $0.angle != 0 && $0.alpha < 1 }, "the brickwork breaks apart as the smoke starts")
        for _ in 0..<90 { model.advance(1.0 / 60) }
        check(!model.isVisible && model.poses().isEmpty, "departure leaves no persistent brickwork")
        let stoppedTime = model.time; model.advance(1)
        check(model.time == stoppedTime, "an absent fireplace does no fire simulation")
        for _ in 0..<20 { model.setEnabled(true); model.advance(0.03); model.setEnabled(false); model.advance(0.03) }
        for _ in 0..<100 { model.advance(1.0 / 60) }
        check(!model.isVisible, "rapid toggles cannot strand the model in an animated state")

        let screens = [StaticEffectScreen(id: 1, frame: screen)]
        func make() -> FireplaceController? { FireplaceController(screens: { screens }, present: { _ in }, allowGPU: false) }
        let controller = make()!
        for _ in 0..<60 { controller.advance(1.0 / 60) }
        let rasterDeadline = Date().addingTimeInterval(1)
        while !controller.fireImagesReadyForTesting && Date() < rasterDeadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        check(controller.fireImagesReadyForTesting, "flame images are prepared off the main drawing path")
        check(controller.allPanels.count == 1 && controller.allPanels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && !$0.canBecomeMain }, "the hearth overlay is click-through and nonactivating")
        check(controller.allPanels[0].level.rawValue < Int(CGWindowLevelForKey(.normalWindow)) &&
              controller.allPanels[0].level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)) &&
              controller.allPanels[0].level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)),
              "the hearth sits above the wallpaper but behind desktop icons, windows, and the Dock")
        controller.updateDock(dock)
        check(controller.model.layout == layout, "Dock geometry updates resize the active hearth")
        controller.setWidthFraction(0.8)
        check(abs(controller.model.layout.frame.width - screen.width * 0.8) < 0.01,
              "a live width change grows the fireplace")
        controller.setWidthFraction(0.3)
        check(abs(controller.model.layout.frame.width - dockAware.frame.width) < 0.01,
              "lowering width can shrink a previously wider fireplace")
        controller.updateDock(zoomed); controller.updateDock(dock)
        check(controller.model.layout.length >= grown.length, "live Dock tracking retains the magnified envelope")
        controller.setHeight(240)
        check(controller.model.layout.depth == 240, "a live height change resizes the fireplace independently of the Dock")
        controller.setOffset(-1)
        check(controller.model.layout.frame.minX == screen.minX + 6, "a live offset reaches the left display edge")
        controller.setOffset(0)
        check(abs(controller.model.layout.frame.midX - screen.midX) < 0.01, "returning to zero centers the running fireplace")
        controller.updateDock(zoomed)
        check(controller.model.layout.depth == 240, "Dock updates preserve the selected height")
        controller.setEnabled(false); controller.advance(0.05)
        check(controller.smokeCountForTesting == 1, "turning off creates a smoke poof")
        controller.setEnabled(true); controller.advance(0.05); controller.setEnabled(false); controller.advance(0.05)
        controller.setEnabled(true); controller.advance(0.05); controller.setEnabled(false); controller.advance(0.05)
        check(controller.smokeCountForTesting <= 2, "overlapping poofs have a bounded resource count")
        controller.dissolveIndependently(); controller.dissolveIndependently()
        check(controller.departureTimerForTesting, "leaving Snow Storm runs a finite independent departure clock")
        for _ in 0..<100 { controller.advance(1.0 / 60) }
        check(controller.finished && controller.allPanels.isEmpty && !controller.departureTimerForTesting, "the final smoke releases every surface and its clock")
        controller.shutdown()

        let prefs = PreferenceStore(defaults: MemoryDefaults())
        check(!prefs.bool(.stormFireplace) && prefs.int(.stormFireplaceWidth) == 50 &&
              prefs.int(.stormFireplaceHeight) == 158 && prefs.int(.stormFireplaceOffset) == 0,
              "Fireplace defaults off at fifty-percent width, 158-point height, and centered position")
        prefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect); prefs.set(true, for: .stormFireplace)
        let parent = StaticEffectsController(preferences: prefs, reducedMotion: { false }, screens: { screens }, present: { _, _ in }, automaticPlacement: false, fireplaceFactory: make)
        let storm = parent.stormForTesting!, fireplace = storm.fireplaceForTesting!
        prefs.set(80, for: .stormFireplaceWidth)
        check(abs(fireplace.model.layout.frame.width - screen.width * 0.8) < 0.01,
              "changing Fireplace Width updates the running hearth")
        prefs.set(30, for: .stormFireplaceWidth)
        check(abs(fireplace.model.layout.frame.width - screen.width * 0.3) < 0.01,
              "the running hearth shrinks to the selected width without a Dock")
        prefs.set(280, for: .stormFireplaceHeight)
        check(fireplace.model.layout.depth == 280,
              "the height adjuster resizes the running fireplace")
        prefs.set(100, for: .stormFireplaceOffset)
        check(fireplace.model.layout.frame.maxX == screen.maxX - 6,
              "the offset adjuster moves the running fireplace to the right edge")
        prefs.set(0, for: .stormFireplaceOffset)
        check(abs(fireplace.model.layout.frame.midX - screen.midX) < 0.01,
              "the offset adjuster returns the running fireplace to screen center")
        for _ in 0..<60 { fireplace.advance(1.0 / 60) }
        let snow = storm.simulation
        prefs.set(false, for: .stormFireplace)
        check(parent.stormForTesting?.simulation === snow && fireplace.model.phase == .dissolving, "checkbox changes preserve the live Snow Storm simulation")
        prefs.set(true, for: .stormFireplace)
        fireplace.advance(0.05)
        check(storm.fireplaceForTesting === fireplace && fireplace.model.phase == .assembling, "re-enabling reuses the active fireplace controller")
        prefs.set(StaticEffect.none.rawValue, for: .staticEffect)
        check(parent.stormForTesting == nil && !storm.timerRunningForTesting && parent.retiringFireplacesForTesting.count == 1, "No Effect stops snow but retains the finite smoke departure")
        let departure = parent.retiringFireplacesForTesting[0]
        for _ in 0..<100 { departure.advance(1.0 / 60) }
        check(parent.retiringFireplacesForTesting.isEmpty && !departure.departureTimerForTesting, "completed departure is released by its owner")
        prefs.set(StaticEffect.snowStorm.rawValue, for: .staticEffect)
        check(parent.stormForTesting?.fireplaceForTesting != nil && prefs.bool(.stormFireplace), "the saved Fireplace choice returns with Snow Storm")
        prefs.set(true, for: .suspended)
        check(parent.stormForTesting == nil && parent.retiringFireplacesForTesting.isEmpty, "suspension stops all fire and smoke immediately")
        parent.shutdown()
        print("\(checks) Fireplace checks passed: Dock growth/clearance, open-bottom masonry, irregular fire, behind-Dock layering, smoke lifecycle, rapid toggles, and cleanup.")
    }
    private static func snapshot(model: FireplaceModel, dock: FireplaceDock? = nil, file: URL) throws {
        let rect = model.layout.frame.insetBy(dx: -16, dy: -16)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(rect.width)), pixelsHigh: Int(ceil(rect.height)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        graphics.cgContext.setFillColor(NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.16, alpha: 1).cgColor)
        graphics.cgContext.fill(CGRect(origin: .zero, size: rect.size))
        FireplaceDrawing.draw(model, context: graphics.cgContext, worldRect: rect)
        if let dock {
            let local = dock.frame.offsetBy(dx: -rect.minX, dy: -rect.minY)
            graphics.cgContext.setFillColor(NSColor(calibratedWhite: 0.38, alpha: 0.9).cgColor)
            graphics.cgContext.addPath(CGPath(roundedRect: local, cornerWidth: 16, cornerHeight: 16, transform: nil))
            graphics.cgContext.fillPath()
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
