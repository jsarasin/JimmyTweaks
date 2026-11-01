import AppKit
import MetalKit

private final class IdleFeedbackWindows: WindowAccessing {
    let kind: GestureKind
    let initialFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    var resolveCount = 0
    var writeCount = 0
    var holdWrites = false
    var held: [(CGRect, (Result<CGRect, WindowAccessError>) -> Void)] = []
    var finalFrame = CGRect.zero
    init(kind: GestureKind) { self.kind = kind }
    func resolve(point: CGPoint, button: MouseButton?, preferences: GesturePreferences, deadline: TimeInterval,
                 stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void) {
        resolveCount += 1
        completion(WindowTarget(element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "effects.idle.fixture",
            seed: GestureSeed(frame: initialFrame, pointer: point, kind: kind)))
    }
    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate, restoring: Bool,
               completion: @escaping (Result<CGRect, WindowAccessError>) -> Void) {
        writeCount += 1; finalFrame = target.seed.desiredFrame(at: pointer)
        if holdWrites { held.append((finalFrame, completion)) } else { completion(.success(finalFrame)) }
    }
    func completeHeld() { let pending = held; held = []; for (frame, completion) in pending { completion(.success(frame)) } }
}

/// One focused end-of-feature check. No real applications are moved and no system settings change.
@main struct EffectsFeatureCheck {
    private static var checks = 0
    private static var failures = 0
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if condition() { print("PASS: \(message)") } else { failures += 1; print("FAIL: \(message)") }
    }
    private static func settle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.008))) }
    }
    private static func wait(_ timeout: TimeInterval, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { settle(0.01) }
    }
    private static func quartz(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: CGDisplayBounds(CGMainDisplayID()).height - frame.maxY, width: frame.width, height: frame.height)
    }

    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--fixture" {
            try fixture(URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try gpuCheck(root)
        try smokeCursorCheck(root)
        idleLifecycleCheck(root)
        try overlayCheck(root)
        try preferenceCheck(root)
        print("\(checks - failures)/\(checks) focused effect checks passed.")
        if failures > 0 { exit(1) }
    }

    private static func idleLifecycleCheck(_ root: URL) {
        let command = Modifiers(command: true, extra: false)
        let released = Modifiers(command: false, extra: false)
        for button in [MouseButton.left, .right] {
            let kind: GestureKind = button == .left ? .move : .resize(.bottomRight)
            let windows = IdleFeedbackWindows(kind: kind)
            let logger = FileLogger(directory: root.appendingPathComponent("idle-\(kind.name)"), maintenance: false)
            let engine = WindowGestureController(preferences: GesturePreferences(), windows: windows, logger: logger)
            engine.attachToCurrentRunLoopForTesting()
            var latest: GestureFeedback?
            var dismissals = 0
            engine.onFeedback = { latest = $0; if $0?.dismissing == true { dismissals += 1 } }
            let down = CGPoint(x: 350, y: 300), drag = CGPoint(x: 390, y: 330), up = CGPoint(x: 420, y: 350)
            func begin() {
                windows.holdWrites = false
                engine.handleForTesting(.down(button, down, command)); settle(0.025)
                engine.handleForTesting(.drag(button, drag)); settle(0.03)
            }
            begin()
            check(latest?.active == true && latest?.kind == kind, "\(kind.name): gesture begins normally")
            windows.holdWrites = true
            engine.handleForTesting(.up(button, up)); settle(0.03)
            check(latest?.idle == true && latest?.active == false && !engine.ownsSequenceForTesting,
                  "\(kind.name): mouse release immediately enters idle feedback without retaining mouse ownership")
            let idleFrame = latest?.frame
            let resolves = windows.resolveCount
            engine.hoverForTesting(at: CGPoint(x: 5000, y: 5000), modifiers: command); settle(0.01)
            check(windows.resolveCount == resolves && latest?.frame == idleFrame && latest?.idle == true,
                  "\(kind.name): moving the pointer while Command is held does not hide or retarget idle feedback")
            windows.completeHeld(); settle(0.025)
            check(latest?.idle == true && latest?.frame == windows.finalFrame,
                  "\(kind.name): final AX readback updates the idle effect to the accepted mouse-up frame")
            let writes = windows.writeCount
            engine.handleForTesting(.flags(Modifiers(command: true, extra: true))); settle(0.01)
            check(latest?.idle == true && windows.writeCount == writes,
                  "\(kind.name): idle feedback survives other modifiers and performs no extra window writes")
            let previousDismissals = dismissals
            engine.handleForTesting(.flags(released)); settle(0.01)
            check(dismissals == previousDismissals + 1 && latest?.idle != true,
                  "\(kind.name): Command release emits a smoke dismissal and relinquishes idle feedback")
            let resolvesBeforeClicks = windows.resolveCount
            for click in [MouseButton.left, .right] {
                let clickDown = engine.handleForTesting(.down(click, up, released))
                let clickUp = engine.handleForTesting(.up(click, up))
                check(!clickDown.suppress && !clickUp.suppress && windows.resolveCount == resolvesBeforeClicks,
                      "\(kind.name): rapid \(click) click after Command release passes through the input engine unchanged")
            }

            begin(); windows.holdWrites = true
            engine.handleForTesting(.up(button, up)); settle(0.03)
            engine.handleForTesting(.flags(released)); settle(0.01)
            windows.completeHeld(); settle(0.025)
            check(latest == nil, "\(kind.name): late mouse-up completion cannot resurrect feedback after Command release")

            begin()
            let activeDismissals = dismissals
            engine.handleForTesting(.flags(released)); settle(0.015)
            check(dismissals == activeDismissals + 1, "\(kind.name): Command release during an active drag also requests smoke")
            engine.handleForTesting(.up(button, up)); settle(0.015)

            begin(); engine.handleForTesting(.up(button, up)); settle(0.04)
            var disabled = GesturePreferences(); disabled.enabled = false
            engine.update(disabled); settle(0.02)
            check(latest == nil, "\(kind.name): disabling the feature clears idle feedback while Command is held")
        }
    }

    private static func smokeCursorCheck(_ root: URL) throws {
        guard let control = ProceduralEffects() else { check(false, "Cursor smoke check has GPU access"); return }
        let cleaned = control.makeSibling()
        let rect = CGRect(x: -320, y: -200, width: 640, height: 400)
        let stroke = SmokeCursorStroke(start: CGPoint(x: -180, y: 0), end: CGPoint(x: 180, y: 0))
        for i in 0..<8 {
            for field in [control, cleaned] {
                _ = field.configure(rect: rect, source: .zero, arms: .zero, mist: true, motion: EffectMotion())
                _ = field.render(surfaces: [], at: Double(i) / 60); field.waitForGPUForTesting()
            }
        }
        for (field, cursor) in [(control, Optional<SmokeCursorStroke>.none), (cleaned, Optional(stroke))] {
            _ = field.configure(rect: rect, source: .zero, arms: .zero, mist: true, motion: EffectMotion(), smoke: 0.35, cursor: cursor)
            _ = field.render(surfaces: [], at: 8.0 / 60); field.waitForGPUForTesting()
        }
        let untouched = control.snapshot(rect: rect, width: 640, height: 400)!
        let brushed = cleaned.snapshot(rect: rect, width: 640, height: 400)!
        check([-100, 0, 100].allSatisfy { x in
            let point = CGPoint(x: x, y: 0)
            return Int(alpha(brushed, at: point, rect: rect, width: 640, height: 400)) * 4
                < Int(alpha(untouched, at: point, rect: rect, width: 640, height: 400))
        }, "A fast cursor sweep thins smoke continuously along the whole path between frames")
        let outside = CGPoint(x: 0, y: 100)
        check(abs(Int(alpha(brushed, at: outside, rect: rect, width: 640, height: 400))
            - Int(alpha(untouched, at: outside, rect: rect, width: 640, height: 400))) <= 1,
              "Cursor cleanup stays local rather than fading the entire smoke layer")
        check(isGrey(brushed), "Cursor cleanup preserves the neutral-grey smoke colour")
        try save(brushed, width: 640, height: 400, to: root.appendingPathComponent("smoke-cursor-wake.png"))
        for field in [control, cleaned] {
            _ = field.configure(rect: rect, source: .zero, arms: .zero, mist: true, motion: EffectMotion(), smoke: 0.4)
            _ = field.render(surfaces: [], at: 9.0 / 60); field.waitForGPUForTesting()
        }
        let after = cleaned.snapshot(rect: rect, width: 640, height: 400)!
        let reference = control.snapshot(rect: rect, width: 640, height: 400)!
        check(Int(alpha(after, at: .zero, rect: rect, width: 640, height: 400)) * 2
            < Int(alpha(reference, at: .zero, rect: rect, width: 640, height: 400)),
              "The cleared wake persists in smoke density after the cursor moves away")

        // Cursor interaction belongs only to the ending smoke, not the live gesture.
        for field in [control, cleaned] { field.restart() }
        for (field, cursor) in [(control, Optional<SmokeCursorStroke>.none), (cleaned, Optional(stroke))] {
            _ = field.configure(rect: rect, source: .zero, arms: .zero, mist: true, motion: EffectMotion(), cursor: cursor)
            _ = field.render(surfaces: [], at: 0); field.waitForGPUForTesting()
        }
        check(control.snapshot(rect: rect, width: 640, height: 400)! == cleaned.snapshot(rect: rect, width: 640, height: 400)!,
              "Cursor movement never erases an active move or resize effect")
    }

    private static func gpuCheck(_ root: URL) throws {
        guard let renderer = ProceduralEffects() else { check(false, "Metal shaders compile and pipelines initialize"); return }
        check(true, "Metal shaders compile and pipelines initialize")
        print("GPU: \(renderer.device.name)")
        let radius: CGFloat = 288
        let rect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        let fireDesktop = CGRect(x: -1024, y: -768, width: 2048, height: 1536)
        var motion = EffectMotion()
        func advance(_ i: Int, rect: CGRect, source: CGPoint, mist: Bool) {
            let configured = renderer.configure(rect: mist ? rect : fireDesktop, source: source, arms: SIMD2(1, 1), mist: mist, motion: motion)
            if !configured { check(false, "GPU field allocation"); return }
            _ = renderer.render(surfaces: [], at: Double(i) / 60)
            renderer.waitForGPUForTesting()
        }
        for i in 0..<50 { advance(i, rect: rect, source: .zero, mist: false) }
        let idle = renderer.snapshot(rect: rect, width: 384, height: 384)!
        for i in 50..<70 { advance(i, rect: rect, source: .zero, mist: false) }
        let later = renderer.snapshot(rect: rect, width: 384, height: 384)!
        check(idle != later, "Fire evolves continuously without bitmap animation")
        check(alphaMaximum(idle) > 220, "Fire has a bright, opaque core")
        check(idle[3] == 0 && idle[idle.count - 1] == 0, "Fire patch boundaries are transparent")
        check(alpha(idle, at: CGPoint(x: 80, y: 0), rect: rect, width: 384, height: 384) > 220, "Enlarged fire has bright arms extending well beyond the old 32-point marker")
        try save(idle, width: 384, height: 384, to: root.appendingPathComponent("fire-idle.png"))

        // A single accepted frame can jump 100 points along each axis. Reconstruct
        // its emission path instead of leaving two disconnected corner patches.
        let jump = CGPoint(x: 100, y: 100)
        motion.sample(.zero, at: 69.0 / 60)
        motion.sample(jump, at: 70.0 / 60)
        let jumpRect = rect.offsetBy(dx: jump.x, dy: jump.y)
        advance(70, rect: jumpRect, source: jump, mist: false)
        let swept = renderer.snapshot(rect: jumpRect, width: 576, height: 576)!
        check([25, 50, 75].allSatisfy { distance in
            alpha(swept, at: CGPoint(x: distance, y: distance), rect: jumpRect, width: 576, height: 576) > 20
        }, "A 100-point resize jump emits continuously along the intermediate path")
        check(alpha(swept, at: jump, rect: jumpRect, width: 576, height: 576) > 220, "Interpolated flame keeps the bright corner attached to the actual accepted frame")
        try save(swept, width: 576, height: 576, to: root.appendingPathComponent("fire-fast-jump.png"))

        // Reverse far enough that the existing trail would have fallen outside the
        // former corner-following 576-point patch. The desktop field must retain it.
        advance(71, rect: rect, source: CGPoint(x: 450, y: 0), mist: false)
        advance(72, rect: rect, source: CGPoint(x: -450, y: 0), mist: false)
        let reversed = renderer.snapshot(rect: fireDesktop, width: 1024, height: 768)!
        check(alpha(reversed, at: CGPoint(x: 450, y: 30), rect: fireDesktop, width: 1024, height: 768) > 20,
              "Rapid reversal retains live flame 900 points from the new corner without a moving rectangular cutoff")
        try save(reversed, width: 1024, height: 768, to: root.appendingPathComponent("fire-full-desktop-reversal.png"))

        renderer.restart(); motion = EffectMotion()
        for i in 0..<70 {
            let position = CGPoint(x: Double(max(0, i - 30)) * 1.8, y: sin(Double(i) * 0.12) * 8)
            motion.sample(position, at: Double(i) / 60)
            advance(i, rect: rect.offsetBy(dx: position.x, dy: position.y), source: position, mist: false)
        }
        let position = CGPoint(x: 39 * 1.8, y: sin(69 * 0.12) * 8)
        let movingRect = rect.offsetBy(dx: position.x, dy: position.y)
        let moving = renderer.snapshot(rect: movingRect, width: 384, height: 384)!
        check(later != moving, "Accepted corner velocity and acceleration change the flame")
        check(motion.velocity.x > 50 && motion.acceleration.x.isFinite, "Motion filtering remains finite and responds to movement")
        motion.sample(CGPoint(x: 10000, y: -10000), at: 1.17)
        check(motion.velocity == .zero && motion.acceleration == .zero, "A discontinuous target jump resets motion instead of producing a flare")
        try save(moving, width: 384, height: 384, to: root.appendingPathComponent("fire-moving.png"))
        let coloured = stride(from: 0, to: moving.count, by: 4).filter { moving[$0 + 3] > 25 }
        let meanSaturation = coloured.reduce(0.0) { total, i in
            let channels = [Double(moving[i]), Double(moving[i + 1]), Double(moving[i + 2])]
            return total + (channels.max()! - channels.min()!) / max(1, channels.max()!)
        } / Double(max(1, coloured.count))
        check(meanSaturation < 0.55 && coloured.contains { moving[$0] > moving[$0 + 2] },
              "Supernatural corner uses a subdued cool iridescent palette rather than saturated accent-coloured fire")
        func smokeFrame(mist: Bool, rect: CGRect, source: CGPoint, time: Double, progress: Float) -> [UInt8] {
            _ = renderer.configure(rect: mist ? rect : fireDesktop, source: source, arms: SIMD2(1, 1), mist: mist, motion: motion, smoke: progress)
            _ = renderer.render(surfaces: [], at: time); renderer.waitForGPUForTesting()
            return renderer.snapshot(rect: rect, width: 384, height: 384)!
        }
        let morphingCorner = smokeFrame(mist: false, rect: movingRect, source: position, time: 1.18, progress: 0.08)
        check(alphaMaximum(morphingCorner) > 10 && !isGrey(morphingCorner), "Corner energy retains its colour during the graceful change into smoke")
        let cornerSmoke = smokeFrame(mist: false, rect: movingRect, source: position, time: 1.2, progress: 0.25)
        check(alphaMaximum(cornerSmoke) > 10 && isGrey(cornerSmoke), "Corner energy finishes turning grey before the separate smoke fade begins")
        let almostGone = smokeFrame(mist: false, rect: movingRect, source: position, time: 1.22, progress: 0.9)
        check(alphaMaximum(almostGone) < alphaMaximum(cornerSmoke), "Smoke rapidly loses opacity as it dissipates")
        let gone = smokeFrame(mist: false, rect: movingRect, source: position, time: 1.24, progress: 1)
        check(alphaMaximum(gone) == 0, "Smoke is fully transparent at the end of its dismissal")
        try save(cornerSmoke, width: 384, height: 384, to: root.appendingPathComponent("corner-grey-smoke.png"))

        renderer.restart(); motion = EffectMotion()
        let mistRect = CGRect(x: -320, y: -200, width: 640, height: 400)
        advance(0, rect: mistRect, source: .zero, mist: true)
        let immediateFog = renderer.snapshot(rect: mistRect, width: 640, height: 400)!
        check(alphaMaximum(immediateFog) > 70, "Mist is visibly seeded in the very first rendered frame")
        for i in 1..<8 { advance(i, rect: mistRect, source: .zero, mist: true) }
        let earlyFog = renderer.snapshot(rect: mistRect, width: 640, height: 400)!
        check(alphaMaximum(earlyFog) > 130, "Mist reaches strong visibility within roughly 120 ms")
        for i in 8..<110 { advance(i, rect: mistRect, source: .zero, mist: true) }
        let fog = renderer.snapshot(rect: mistRect, width: 640, height: 400)!
        check(alphaMaximum(fog) > 140 && alphaMaximum(fog) <= 166, "Mist is substantially stronger with opacity capped at 65 percent")
        let centre = (200 * 640 + 320) * 4
        check(fog[centre] > fog[centre + 2], "Mist is blue")
        var edgeAlpha: [UInt8] = []
        for x in 0..<640 { edgeAlpha.append(fog[x * 4 + 3]); edgeAlpha.append(fog[(399 * 640 + x) * 4 + 3]) }
        for y in 0..<400 { edgeAlpha.append(fog[(y * 640) * 4 + 3]); edgeAlpha.append(fog[(y * 640 + 639) * 4 + 3]) }
        check(edgeAlpha.allSatisfy { $0 == 0 }, "Mist fades completely to transparency on every window edge")
        try save(fog, width: 640, height: 400, to: root.appendingPathComponent("mist-idle.png"))
        for i in 110..<145 {
            let p = CGPoint(x: Double(i - 109) * 3, y: Double(i - 109))
            motion.sample(p, at: Double(i) / 60)
            advance(i, rect: mistRect.offsetBy(dx: p.x, dy: p.y), source: p, mist: true)
        }
        let movedFog = renderer.snapshot(rect: mistRect.offsetBy(dx: 105, dy: 35), width: 640, height: 400)!
        check(fog != movedFog, "Blue mist responds to accepted window motion")
        try save(movedFog, width: 640, height: 400, to: root.appendingPathComponent("mist-moving.png"))

        // Both screen fragments sample precisely the same shared simulation coordinates.
        let left = renderer.snapshot(rect: CGRect(x: -215, y: -165, width: 320, height: 400), width: 320, height: 400)!
        let right = renderer.snapshot(rect: CGRect(x: 105, y: -165, width: 320, height: 400), width: 320, height: 400)!
        var joined = [UInt8]()
        for row in 0..<400 {
            joined += left[(row * 320 * 4)..<((row + 1) * 320 * 4)]
            joined += right[(row * 320 * 4)..<((row + 1) * 320 * 4)]
        }
        check(zip(joined, movedFog).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Split display fragments match the unsplit simulation without a seam")
        let fogSmokeRect = mistRect.offsetBy(dx: 105, dy: 35)
        let morphingFog = smokeFrame(mist: true, rect: fogSmokeRect, source: CGPoint(x: 105, y: 35), time: 2.47, progress: 0.08)
        check(alphaMaximum(morphingFog) > 10 && !isGrey(morphingFog), "Blue mist also retains its colour during the initial smoke morph")
        let fogSmoke = smokeFrame(mist: true, rect: fogSmokeRect, source: CGPoint(x: 105, y: 35), time: 2.5, progress: 0.25)
        check(alphaMaximum(fogSmoke) > 10 && isGrey(fogSmoke), "Moving mist also becomes neutral-grey smoke")
        let incoming = renderer.makeSibling()
        _ = incoming.configure(rect: fireDesktop, source: CGPoint(x: -100, y: -100), arms: SIMD2(1, 1), mist: false, motion: EffectMotion())
        _ = incoming.render(surfaces: [], at: 2.5); incoming.waitForGPUForTesting()
        let incomingOnly = incoming.snapshot(rect: fogSmokeRect, width: 640, height: 400)!
        let composite = incoming.snapshot(rect: fogSmokeRect, width: 640, height: 400, underlays: [renderer])!
        check(zip(composite, incomingOnly).contains { $0 != $1 }, "GPU compositing preserves outgoing smoke beneath a newly started effect")
        try save(composite, width: 640, height: 400, to: root.appendingPathComponent("mode-switch-composite.png"))
        check(!renderer.failed, "GPU command buffers complete without errors")
    }

    private static func overlayCheck(_ root: URL) throws {
        let infoURL = root.appendingPathComponent("fixture.json")
        try? FileManager.default.removeItem(at: infoURL)
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--fixture", infoURL.path]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        wait(8) { FileManager.default.fileExists(atPath: infoURL.path) || !child.isRunning }
        guard let data = try? Data(contentsOf: infoURL), let info = try JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            check(false, "Separate-process window fixture starts"); return
        }
        let target = Int(info["target"]!), occluder = Int(info["occluder"]!)
        let appKitFrame = CGRect(x: info["x"]!, y: info["y"]!, width: info["width"]!, height: info["height"]!)
        let screen = NSScreen.screens.first { $0.frame.intersects(appKitFrame) }!
        check(FeedbackWindow.match(pid: child.processIdentifier, frame: quartz(appKitFrame))?.number == target, "Public metadata identifies the foreign target window")
        var reduced = false
        var pointer = CGPoint(x: appKitFrame.midX - 150, y: appKitFrame.midY)
        let feedback = FeedbackController(reducedMotion: { reduced }, cursorPosition: { pointer })
        defer { feedback.clear() }
        var prefs = GesturePreferences(); prefs.changeCursor = false
        func show(_ frame: CGRect, _ kind: GestureKind = .resize(.bottomLeft), idle: Bool = false) {
            feedback.show(GestureFeedback(frame: quartz(frame), kind: kind, active: !idle, preferences: prefs, window: FeedbackWindow(number: target, level: 0), idle: idle))
        }
        show(appKitFrame)
        wait(10) { feedback.rendererReadyForTesting }
        settle(0.35)
        check(feedback.presentedFramesForTesting > 0 && feedback.timerRunningForTesting, "Active resizing presents procedural Metal frames")
        let panel = feedback.panelsForTesting.first { $0.isVisible }!
        check(panel.frame == screen.frame && !panel.isOpaque && panel.ignoresMouseEvents && !panel.canBecomeKey, "Overlay is full-display, transparent, nonactivating, and click-through")
        let initialFrame = panel.frame
        let initialSimulationBounds = feedback.simulationBoundsForTesting
        func fullScreenSurface(_ panel: NSWindow) -> Bool {
            guard let screen = NSScreen.screens.first(where: { $0.frame == panel.frame }),
                  let surface = panel.contentView?.subviews.compactMap({ $0 as? EffectSurface }).first else { return false }
            let size = CGSize(width: ceil(screen.frame.width * screen.backingScaleFactor), height: ceil(screen.frame.height * screen.backingScaleFactor))
            return surface.frame == panel.contentView!.bounds && surface.worldRect == screen.frame && surface.drawableSize == size
        }
        check(fullScreenSurface(panel), "Fire MTKView and native-resolution drawable both fill the entire display")
        show(appKitFrame.offsetBy(dx: 24, dy: 12)); settle(0.12)
        check(panel.frame == initialFrame, "Target movement does not move or resize the display overlay")
        check(fullScreenSurface(panel) && feedback.simulationBoundsForTesting == initialSimulationBounds,
              "Moving the corner changes neither the rendering surface nor the desktop simulation bounds")
        let resizeFrames = feedback.effectFramesForTesting
        show(appKitFrame, idle: true); settle(0.1)
        check(feedback.timerRunningForTesting && feedback.effectFramesForTesting > resizeFrames && panel.isVisible,
              "Resize fire continues animating in its idle state after mouse release")
        let ordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
        if let a = ordered.firstIndex(of: occluder), let b = ordered.firstIndex(of: panel.windowNumber), let c = ordered.firstIndex(of: target) {
            check(a < b && b < c, "Foreign occluding window stays above the overlay, which stays above its target")
        } else { check(false, "Window Server reports the target-relative stack") }
        show(appKitFrame, .move); settle(0.035)
        check(feedback.smokeCountForTesting > 0 && feedback.compositedLayersForTesting >= 2,
              "Resize-to-move switch overlaps outgoing smoke and incoming mist")
        show(appKitFrame); settle(0.035)
        check(feedback.smokeCountForTesting >= 2 && feedback.compositedLayersForTesting >= 3,
              "Rapid move-to-resize reversal preserves both outgoing smoke layers")
        show(appKitFrame, .move); settle(0.3)
        check(feedback.timerRunningForTesting, "Active left-button moving uses the animated renderer")
        check(fullScreenSurface(panel), "Mist also uses a full-display native-resolution rendering surface")
        let moveFrames = feedback.effectFramesForTesting
        show(appKitFrame, .move, idle: true); settle(0.1)
        check(feedback.timerRunningForTesting && feedback.effectFramesForTesting > moveFrames && panel.isVisible,
              "Moving mist continues animating in its idle state after mouse release")
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        show(desktop, .move); settle(0.08)
        let visiblePanels = feedback.panelsForTesting.filter { $0.isVisible }
        check(visiblePanels.count == NSScreen.screens.count && NSScreen.screens.allSatisfy { screen in visiblePanels.contains { $0.frame == screen.frame } }, "Cross-display geometry creates one stationary full-screen overlay for every intersected display")
        show(appKitFrame, .move); settle(0.08)
        let time = feedback.averageGPUTimeForTesting * 1000
        print(String(format: "Shared compute/render batch average: %.3f ms GPU (short feature check, not a sustained benchmark).", time))

        feedback.show(GestureFeedback(frame: quartz(appKitFrame), kind: .move, active: false, preferences: prefs,
            window: FeedbackWindow(number: target, level: 0), dismissing: true))
        settle(0.04)
        check(feedback.smokeCountForTesting > 0 && feedback.timerRunningForTesting && panel.isVisible,
              "Command release starts a brief smoke poof instead of instantly hiding the overlay")
        check(feedback.panelsForTesting.filter { $0.isVisible }.allSatisfy { $0.ignoresMouseEvents && !$0.acceptsMouseMovedEvents && !$0.canBecomeKey },
              "Fading smoke windows stay click-through and do not receive mouse movement or focus")
        let strokes = feedback.smokeCursorStrokesForTesting
        pointer.x += 300
        feedback.show(nil); settle(0.025)
        check(feedback.timerRunningForTesting && panel.isVisible, "Late nil feedback cannot cut a smoke poof short")
        check(feedback.smokeCursorStrokesForTesting > strokes && panel.ignoresMouseEvents,
              "The smoke clock polls cursor motion and clears a wake without capturing input events")
        settle(0.45)
        check(feedback.smokeCountForTesting > 0 && feedback.timerRunningForTesting && panel.isVisible,
              "Smoke remains visible after the one-third-second colour morph")
        settle(0.55)
        check(feedback.smokeCountForTesting > 0 && feedback.timerRunningForTesting && panel.isVisible,
              "The colour morph does not shorten the full one-second grey smoke fade")
        settle(0.4)
        check(feedback.smokeCountForTesting == 0 && !feedback.timerRunningForTesting && !panel.isVisible,
              "One-third-second colour morph and one-second smoke fade finish with rendering stopped")
        show(appKitFrame, .move); settle(0.05)
        let noSmokeStrokes = feedback.smokeCursorStrokesForTesting
        pointer.y += 100; settle(0.025)
        check(feedback.smokeCursorStrokesForTesting == noSmokeStrokes,
              "Cursor interaction stops when only a live gesture remains")
        feedback.show(GestureFeedback(frame: quartz(appKitFrame), kind: .move, active: false, preferences: prefs,
            window: FeedbackWindow(number: target, level: 0), dismissing: true))
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        settle(0.02)
        check(!feedback.timerRunningForTesting && feedback.smokeCountForTesting == 0 && !panel.isVisible,
              "Enabling Reduce Motion immediately cancels a running smoke dismissal")
        reduced = false

        show(appKitFrame, .move, idle: true)
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        settle(0.08)
        let stoppedAt = feedback.effectFramesForTesting
        settle(0.1)
        check(!feedback.timerRunningForTesting && feedback.effectFramesForTesting == stoppedAt && panel.isVisible, "Reduce Motion immediately stops GPU simulation and preserves a static idle moving outline")
        reduced = false; prefs.animatedEffects = false
        show(appKitFrame)
        check(!feedback.timerRunningForTesting && panel.isVisible, "Turning animations off keeps the steady corner marker visible")
        prefs.animatedEffects = true; show(appKitFrame); settle(0.1)
        check(feedback.timerRunningForTesting, "Saved animation choice resumes after the override is removed")
        feedback.clear(); settle(0.05)
        let hiddenAt = feedback.effectFramesForTesting
        settle(0.1)
        check(!feedback.timerRunningForTesting && feedback.effectFramesForTesting == hiddenAt && feedback.panelsForTesting.allSatisfy { !$0.isVisible }, "Clearing feedback hides every overlay and performs no further animation work")
        print("Physical displays exercised: \(NSScreen.screens.count). Shared-coordinate seam check covers an artificial display split.")
    }

    private static func preferenceCheck(_ root: URL) throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false })
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: prefs))
        let page = WindowPageController(.window, context: context)
        var reduced = false; page.reduceMotion = { reduced }; _ = page.view
        let checkbox = page.controls["window.feedback.animatedEffects"] as! NSButton
        check(checkbox.isEnabled && checkbox.state == .on && prefs.gesture.animatedEffects, "Animated effects preference is searchable, enabled, and defaults on")
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        let note = views(page.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Disabled because Reduce Motion is enabled in System Settings." }
        check(!checkbox.isEnabled && checkbox.state == .off && note?.isHidden == false, "Reduce Motion disables the checkbox and displays its explanation beside it")
        check(prefs.bool(.animatedEffects), "Reduce Motion preserves the saved animation preference")
        reduced = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        check(checkbox.isEnabled && checkbox.state == .on && note?.isHidden == true, "Changing Reduce Motion restores the saved checkbox state live")
        prefs.set(false, for: .animatedEffects); page.refreshValues()
        check(!prefs.gesture.animatedEffects && checkbox.state == .off, "Explicitly disabled animation preference reaches the input engine")
        prefs.resetWindow()
        check(prefs.gesture.animatedEffects, "Reset Window Resizer restores the animation default")
    }

    private static func fixture(_ destination: URL) throws {
        let screen = NSScreen.screens[0]
        let rect = CGRect(x: screen.visibleFrame.minX + 90, y: screen.visibleFrame.minY + 90, width: 500, height: 340)
        let target = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        target.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1); target.isReleasedWhenClosed = false; target.orderFrontRegardless()
        let occluder = NSWindow(contentRect: CGRect(x: rect.midX, y: rect.midY, width: 180, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        occluder.backgroundColor = NSColor(calibratedWhite: 0.3, alpha: 1); occluder.isReleasedWhenClosed = false; occluder.orderFrontRegardless()
        settle(0.2)
        let info: [String: Double] = ["target": Double(target.windowNumber), "occluder": Double(occluder.windowNumber), "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
        try JSONSerialization.data(withJSONObject: info).write(to: destination, options: .atomic)
        // Retain both windows for the parent's bounded check. A watchdog also handles a parent crash.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { _ in NSApp.terminate(nil) }
        withExtendedLifetime([target, occluder]) { NSApp.run() }
    }
    private static func alphaMaximum(_ pixels: [UInt8]) -> UInt8 { stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }.max() ?? 0 }
    private static func isGrey(_ pixels: [UInt8]) -> Bool {
        stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 8 }.allSatisfy { i in
            let channels = [Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])]
            return channels.max()! - channels.min()! <= 1
        }
    }
    private static func alpha(_ pixels: [UInt8], at point: CGPoint, rect: CGRect, width: Int, height: Int) -> UInt8 {
        let x = min(width - 1, max(0, Int((point.x - rect.minX) / rect.width * CGFloat(width))))
        let y = min(height - 1, max(0, height - 1 - Int((point.y - rect.minY) / rect.height * CGFloat(height))))
        return pixels[(y * width + x) * 4 + 3]
    }
    private static func save(_ bgra: [UInt8], width: Int, height: Int, to url: URL) throws {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [.alphaNonpremultiplied], bytesPerRow: width * 4, bitsPerPixel: 32)!
        let output = image.bitmapData!
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let a = Float(bgra[i + 3])
            for channel in 0..<3 { output[i + channel] = a > 0 ? UInt8(min(255, Float(bgra[i + 2 - channel]) * 255 / a)) : 0 }
            output[i + 3] = bgra[i + 3]
        }
        try image.representation(using: .png, properties: [:])!.write(to: url)
    }
}
