import AppKit
import ImageIO

@main struct SnowStormFeatureCheck {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError("Snow Storm feature check: " + message) }
        print("PASS: " + message)
    }
    static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--fireplace-mask" {
            fireplaceMask()
            print("Focused fireplace snowfall mask checks passed.")
            return
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--christmas" {
            try ChristmasTests.run(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try nativeLayers(root: root)
        try animation(root: root)
        print("\(checks)/\(checks) Snow Storm feature checks passed.")
    }
    static func settle() {
        let until = Date().addingTimeInterval(0.06)
        while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    static func fireplaceMask() {
        let world = CGRect(x: 100, y: 200, width: 100, height: 100)
        let hearth = CGRect(x: 130, y: 230, width: 40, height: 40)
        var inside = StormFlake(position: CGPoint(x: 150, y: 250), velocity: .zero,
                                mass: 1, radius: 8, phase: 0)
        inside.age = 1
        var outside = inside
        outside.position = CGPoint(x: 112, y: 250)
        func pixels(excluding frame: CGRect?) -> (inside: UInt8, outside: UInt8) {
            let width = 100, height = 100
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            SnowStormDrawing.flakes([inside, outside], windows: [], in: context,
                                    worldRect: world, time: 0, excluding: frame)
            let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
            func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }
            return (alpha(50, 50), alpha(12, 50))
        }
        let unmasked = pixels(excluding: nil)
        check(unmasked.inside > 0 && unmasked.outside > 0,
              "falling flakes draw both inside and outside the fireplace footprint without a mask")
        let masked = pixels(excluding: hearth)
        check(masked.inside == 0 && masked.outside > 0,
              "falling flakes stay off the fireplace while snowfall continues beside it")
        let moved = pixels(excluding: hearth.offsetBy(dx: 40, dy: 0))
        check(moved.inside > 0,
              "the exclusion follows the current fireplace frame")
    }
    static func nativeLayers(root: URL) throws {
        guard let screen = NSScreen.screens.first else { fatalError("A native display is required for the window-layer fixture") }
        let cursorShape = CursorSnowCapture.current()
        check(cursorShape != nil && cursorShape!.topPixels.contains(where: { $0 != nil }),
              "the visible system cursor exposes an opaque silhouette and hotspot")
        let a = NSWindow(contentRect: CGRect(x: screen.frame.midX - 180, y: screen.frame.midY - 140, width: 320, height: 200),
                         styleMask: [.titled], backing: .buffered, defer: false)
        let b = NSWindow(contentRect: a.frame.offsetBy(dx: 110, dy: 60), styleMask: [.titled], backing: .buffered, defer: false)
        a.title = "Snow Storm layering fixture"; b.title = "Snow Storm occlusion fixture"
        a.orderFrontRegardless(); b.orderFrontRegardless(); settle()
        defer { a.orderOut(nil); b.orderOut(nil) }
        func query() -> [SnowStormWindow] {
            SnowStormWindowQuery.read(excluding: [], desktopTop: screen.frame.maxY).filter { [a.windowNumber, b.windowNumber].contains(Int($0.id)) }
        }
        let windows = query()
        check(windows.count == 2 && windows[0].id == UInt32(b.windowNumber), "public window metadata preserves front-to-back order")
        check(windows.allSatisfy { abs($0.frame.maxY - ($0.id == UInt32(a.windowNumber) ? a.frame.maxY : b.frame.maxY)) <= 2 }, "Window Server geometry aligns with AppKit within the compositor border inset")
        let controller = SnowStormController(settings: SnowStormSettings(), screens: { [StaticEffectScreen(id: 1, frame: screen.frame)] },
            cursor: { nil }, automaticTicks: false)
        defer { controller.shutdown() }
        controller.advanceForTesting(dt: 1.0 / 60, windows: windows, cursor: nil)
        for window in windows { controller.simulation.fillDriftForTesting(id: UInt64(window.id), height: 36) }
        controller.advanceForTesting(dt: 1.0 / 60, windows: windows, cursor: nil); settle()
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = ordered.compactMap { $0[kCGWindowNumber as String] as? Int }
        let boundsA = windows.first { $0.id == UInt32(a.windowNumber) }!.frame
        let boundsB = windows.first { $0.id == UInt32(b.windowNumber) }!.frame
        let driftA = controller.allPanels.first { abs($0.frame.minX - (boundsA.minX - 4)) < 0.5 && $0.frame.height < 100 }!
        let driftB = controller.allPanels.first { abs($0.frame.minX - (boundsB.minX - 4)) < 0.5 && $0.frame.height < 100 }!
        let field = controller.allPanels.first { $0.frame == screen.frame }!
        check(ids.firstIndex(of: b.windowNumber)! < ids.firstIndex(of: field.windowNumber)!, "screen-wide snow falls behind the frontmost window")
        check(ids.firstIndex(of: b.windowNumber)! < ids.firstIndex(of: driftA.windowNumber)! && ids.firstIndex(of: driftA.windowNumber)! < ids.firstIndex(of: a.windowNumber)!, "a front window occludes a back window's snowbank")
        check(ids.firstIndex(of: driftB.windowNumber)! < ids.firstIndex(of: b.windowNumber)!, "each snowbank is immediately above its own window level")
        a.orderFrontRegardless(); settle()
        controller.advanceForTesting(dt: 1.0 / 60, windows: query(), cursor: nil); settle()
        let reordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
        check(reordered.firstIndex(of: a.windowNumber)! < reordered.firstIndex(of: field.windowNumber)!, "the snowfall field moves behind the newly frontmost window")
        check(reordered.firstIndex(of: a.windowNumber)! < reordered.firstIndex(of: driftB.windowNumber)!, "focus-only Z changes move snow behind the newly frontmost window")
        a.setFrameOrigin(a.frame.origin.applying(CGAffineTransform(translationX: 36, y: 0))); settle()
        controller.advanceForTesting(dt: 1.0 / 30, windows: query(), cursor: nil)
        check(controller.simulation.erosionMass > 0, "native frame movement releases accumulated snow")
        check(controller.allPanels.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey }, "native snow windows never capture clicks or focus")
        let panel = driftA.contentView!
        panel.layoutSubtreeIfNeeded()
        if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
            panel.cacheDisplay(in: panel.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("native-drift.png"))
        }
    }
    static func animation(root: URL) throws {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 500)
        var back = SnowStormWindow(id: 1, owner: 10, frame: CGRect(x: 60, y: 100, width: 400, height: 200), level: 0)
        let front = SnowStormWindow(id: 2, owner: 11, frame: CGRect(x: 420, y: 160, width: 300, height: 220), level: 0)
        let simulation = SnowStormSimulation(seed: 29)
        let settings = SnowStormSettings(snowfall: 0.95, maximumFlakeSize: 0.8, gusts: 0.55)
        var cursor = CGPoint(x: 365, y: 395)
        var updateTime = 0.0, updateSteps = 0
        func advance(_ windows: [SnowStormWindow]) {
            let before = ProcessInfo.processInfo.systemUptime
            simulation.advance(dt: 1.0 / 30, windows: windows, cursor: cursor, screens: [frame], settings: settings)
            updateTime += ProcessInfo.processInfo.systemUptime - before; updateSteps += 1
        }
        // Seed the preview through actual falling/landing rather than a filled bar.
        for _ in 0..<300 { advance([front, back]) }
        check(simulation.drifts.contains { !$0.isCursor && $0.mass > 200 }, "top-emitted flakes naturally form window snowbanks")
        check(simulation.drifts.first(where: \.isCursor)!.mass > 0, "top-emitted flakes naturally accumulate on the stationary cursor")
        let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent("snow-storm-preview.gif") as CFURL, "com.compuserve.gif" as CFString, 121, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var maximumDebris = 0
        for index in 0...120 {
            let t = Double(index) / 30
            if t > 1.2 && t < 2.2 {
                back.frame.origin.x = 60 + sin((t - 1.2) * .pi * 4) * 110
                cursor.x = 365 + sin((t - 1.2) * .pi * 5) * 65
            }
            advance([front, back])
            maximumDebris = max(maximumDebris, simulation.particles.filter { $0.ignoreSupport != nil }.count)
            let image = render(simulation, frame: frame, cursor: cursor)
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 30]] as CFDictionary)
            if [0, 45, 60, 75, 120].contains(index) {
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("storm-\(index).png"))
            }
        }
        check(CGImageDestinationFinalize(destination), "animated preview exports successfully")
        check(maximumDebris > 20 && simulation.erosionMass > 100, "rapid fixture motion produces formula-driven breakup particles")
        check(simulation.particles.count <= SnowStormSimulation.maximumParticles, "long-running animation keeps a bounded snow field")
        print(String(format: "Controlled 800×500 formula average: %.3f ms per 30 Hz update (%d steps).", updateTime * 1_000 / Double(updateSteps), updateSteps))
    }
    static func render(_ simulation: SnowStormSimulation, frame: CGRect, cursor: CGPoint) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.width), pixelsHigh: Int(frame.height), bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.setFillColor(NSColor(calibratedRed: 0.05, green: 0.1, blue: 0.16, alpha: 1).cgColor); cg.fill(frame)
        for window in simulation.windows.reversed() {
            let path = CGPath(roundedRect: window.frame, cornerWidth: 9, cornerHeight: 9, transform: nil)
            cg.setFillColor(NSColor(calibratedRed: window.id == 1 ? 0.19 : 0.25, green: 0.28, blue: 0.37, alpha: 1).cgColor)
            cg.addPath(path); cg.fillPath()
            cg.setFillColor(NSColor(white: 1, alpha: 0.08).cgColor)
            cg.fill(CGRect(x: window.frame.minX, y: window.frame.maxY - 28, width: window.frame.width, height: 27))
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                cg.setFillColor(color.cgColor); cg.fillEllipse(in: CGRect(x: window.frame.minX + 12 + Double(i) * 16, y: window.frame.maxY - 20, width: 9, height: 9))
            }
            if let drift = simulation.drifts.first(where: { $0.window?.id == window.id }) { SnowStormDrawing.drift(drift, in: cg, origin: .zero) }
        }
        SnowStormDrawing.flakes(simulation.particles, windows: simulation.windows, in: cg, worldRect: frame, time: simulation.time)
        let arrow = CGMutablePath(); arrow.move(to: cursor)
        arrow.addLine(to: CGPoint(x: cursor.x, y: cursor.y - 22)); arrow.addLine(to: CGPoint(x: cursor.x + 6, y: cursor.y - 16))
        arrow.addLine(to: CGPoint(x: cursor.x + 11, y: cursor.y - 25)); arrow.addLine(to: CGPoint(x: cursor.x + 15, y: cursor.y - 22))
        arrow.addLine(to: CGPoint(x: cursor.x + 10, y: cursor.y - 14)); arrow.addLine(to: CGPoint(x: cursor.x + 19, y: cursor.y - 14)); arrow.closeSubpath()
        cg.addPath(arrow); cg.setFillColor(NSColor.black.cgColor); cg.setStrokeColor(NSColor.white.cgColor); cg.setLineWidth(1.3); cg.drawPath(using: .fillStroke)
        if let drift = simulation.drifts.first(where: \.isCursor) { SnowStormDrawing.drift(drift, in: cg, origin: .zero) }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }
}
