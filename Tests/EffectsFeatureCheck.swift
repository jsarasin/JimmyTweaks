import AppKit
import MetalKit
import ImageIO

private final class IdleFeedbackWindows: WindowAccessing {
    let kind: GestureKind
    let initialFrame = CGRect(x: 100, y: 100, width: 600, height: 400)
    var resolveCount = 0
    var writeCount = 0
    var holdWrites = false
    var rejectResolution = false
    var held: [(CGRect, (Result<CGRect, WindowAccessError>) -> Void)] = []
    var finalFrame = CGRect.zero
    init(kind: GestureKind) { self.kind = kind }
    func resolve(point: CGPoint, button: MouseButton?, preferences: GesturePreferences, deadline: TimeInterval,
                 stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void) {
        resolveCount += 1
        if rejectResolution { completion(nil); return }
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
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--preview" {
            try renderPreviews(URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--ordinary" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            ordinaryDragCheck(); ordinaryNativeCheck(); try preferenceCheck(root)
            print("\(checks - failures)/\(checks) ordinary-window effect checks passed.")
            if failures > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--crystal" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try crystalFrostCheck(root)
            print("\(checks - failures)/\(checks) Crystal Frost checks passed.")
            if failures > 0 { exit(1) }
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try gpuCheck(root)
        try presetCheck(root)
        windHistoryCheck()
        electricalBehaviourCheck()
        electricalChannelCheck()
        try windAndFizzleCheck(root)
        try smokeCursorCheck(root)
        idleLifecycleCheck(root)
        resizeStartCheck(root)
        try overlayCheck(root)
        ordinaryDragCheck()
        ordinaryNativeCheck()
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

    private static func presetCheck(_ root: URL) throws {
        guard let renderer = ProceduralEffects() else { check(false, "Preset shaders compile"); return }
        let rect = CGRect(x: -320, y: -200, width: 640, height: 400)
        var snapshots: [WindowEffect: [UInt8]] = [:]
        for effect in WindowEffect.allCases where effect != .none {
            let mist = WindowEffect.moveOptions.contains(effect)
            let fieldRect = effect == .cartoonWind || effect == .furiousLightning ? rect.insetBy(dx: -420, dy: -420) : rect
            renderer.restart()
            var configured = true
            for i in 0..<(effect == .cartoonWind || effect == .furiousLightning ? 90 : 24) {
                configured = renderer.configure(rect: fieldRect, source: .zero, arms: SIMD2(1, 1), mist: mist, motion: EffectMotion(), effect: effect, windowRect: rect) && configured
                _ = renderer.render(surfaces: [], at: Double(i) / 60)
                renderer.waitForGPUForTesting()
            }
            check(configured, "\(effect.title) allocates its field")
            let pixels = renderer.snapshot(rect: fieldRect, width: 640, height: 400)!
            snapshots[effect] = pixels
            check(alphaMaximum(pixels) > 20, "\(effect.title) produces a visible effect")
            try save(pixels, width: 640, height: 400, to: root.appendingPathComponent(effect.rawValue + ".png"))
        }
        for options in [WindowEffect.resizeOptions.filter { $0 != .none }, WindowEffect.moveOptions.filter { $0 != .none }] {
            for i in 0..<options.count {
                for j in (i + 1)..<options.count {
                    check(snapshots[options[i]] != snapshots[options[j]], "\(options[i].title) and \(options[j].title) render differently")
                }
            }
        }
        let lightning = snapshots[.furiousLightning]!
        let bright = stride(from: 0, to: lightning.count, by: 4).filter { lightning[$0 + 3] > 200 }
        check(bright.count > 100 && bright.contains { lightning[$0] > lightning[$0 + 2] }, "Furious Lightning has bright blue-white bolt cores")
        let lightningDomain = rect.insetBy(dx: -420, dy: -420)
        let extended = (0..<400).contains { y in (0..<640).contains { x in
            let point = CGPoint(x: lightningDomain.minX + CGFloat(x) / 640 * lightningDomain.width,
                                y: lightningDomain.maxY - CGFloat(y) / 400 * lightningDomain.height)
            return !rect.insetBy(dx: -40, dy: -40).contains(point) && lightning[(y * 640 + x) * 4 + 3] > 80
        } }
        check(extended, "Lightning fingers shoot well outside the window edges")
        for corner in WindowCorner.allCases {
            renderer.restart()
            let arms = SIMD2<Float>(corner.isLeft ? 1 : -1, corner.isTop ? -1 : 1)
            let window = CGRect(x: -100, y: -60, width: 200, height: 120)
            _ = renderer.configure(rect: rect, source: .zero, arms: arms, mist: false, motion: EffectMotion(), effect: .furiousLightning, windowRect: window)
            _ = renderer.render(surfaces: [], at: 0); renderer.waitForGPUForTesting()
            let first = renderer.snapshot(rect: rect, width: 640, height: 400)!
            check(alphaMaximum(first) < 30, "\(corner.name) lightning enters gently instead of flashing on")
            _ = renderer.render(surfaces: [], at: 0.15); renderer.waitForGPUForTesting()
            _ = renderer.render(surfaces: [], at: 0.3); renderer.waitForGPUForTesting()
            _ = renderer.render(surfaces: [], at: 0.45); renderer.waitForGPUForTesting()
            let next = renderer.snapshot(rect: rect, width: 640, height: 400)!
            check(first != next, "\(corner.name) lightning restrikes over time")
            _ = renderer.configure(rect: rect, source: .zero, arms: arms, mist: false, motion: EffectMotion(), smoke: 0.4, effect: .furiousLightning, windowRect: window)
            _ = renderer.render(surfaces: [], at: 0.5); renderer.waitForGPUForTesting()
            let smoke = renderer.snapshot(rect: rect, width: 640, height: 400)!
            check(alphaMaximum(smoke) > 8 && !isGrey(smoke), "\(corner.name) lightning leaves a weakening electrical fizzle")
        }
        check(!renderer.failed, "All preset GPU commands complete successfully")
    }

    private static func crystalFrostCheck(_ root: URL) throws {
        check(WindowEffect.resizeOptions.contains(.crystalFrost) &&
              !WindowEffect.moveOptions.contains(.crystalFrost) &&
              WindowEffect.crystalFrost.title == "Crystal Frost",
              "Crystal Frost is offered only for resizing")
        let preferences = PreferenceStore(defaults: MemoryDefaults())
        preferences.set(WindowEffect.crystalFrost.rawValue, for: .resizeEffect)
        check(preferences.gesture.resizeEffect == .crystalFrost,
              "Crystal Frost remains selected after the resize preference is saved")
        var field = CrystalFrostField()
        let corner = SIMD2<Float>(140, 300), arms = SIMD2<Float>(1, -1)
        for _ in 0..<10 { field.advance(dt: 1 / 60, corner: corner, arms: arms, emitting: true) }
        let before = field.flakes
        field.advance(dt: 1 / 60, corner: corner + SIMD2(100, -50), arms: arms, emitting: false)
        check(!before.isEmpty && field.flakes.count == before.count &&
              zip(before, field.flakes).allSatisfy { $0.origin == $1.origin },
              "Existing crystals keep their world positions when the resize corner moves")
        for _ in 0..<90 { field.advance(dt: 1 / 60, corner: corner, arms: arms, emitting: true) }
        check(field.flakes.count > 20 && field.flakes.count <= CrystalFrostField.capacity &&
              field.flakes.contains { $0.size >= 40 } &&
              field.flakes.allSatisfy { simd_length($0.velocity) < 18 },
              "Crystals appear in varied sizes with little drift and a bounded live count")
        check(field.flakes.contains { abs($0.origin.x - corner.x) > 40 } &&
              field.flakes.contains { abs($0.origin.y - corner.y) > 40 } &&
              field.flakes.allSatisfy { simd_length($0.origin - corner) < 175 },
              "Crystals appear at varied nearby positions instead of emitting from the corner")
        let departing = field.flakes.count
        field.advance(dt: 1 / 60, corner: corner, arms: arms, emitting: false)
        check(field.flakes.count <= departing, "Finishing a resize stops crystal emission immediately")
        for cornerPose in WindowCorner.allCases {
            var sparkle = CrystalFrostField()
            let inward = SIMD2<Float>(cornerPose.isLeft ? 1 : -1, cornerPose.isTop ? -1 : 1)
            for _ in 0..<60 { sparkle.advance(dt: 1 / 60, corner: corner, arms: inward, emitting: true) }
            check(sparkle.flakes.contains { inward.x * ($0.origin.x - corner.x) > 40 } &&
                  sparkle.flakes.contains { inward.y * ($0.origin.y - corner.y) > 40 },
                  "\(cornerPose.name) crystals sparkle along both nearby edges")
        }
        guard MTLCreateSystemDefaultDevice() != nil else {
            print("SKIP: Metal rendering preview (this environment has no Metal graphics device)")
            return
        }
        let rect = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = CGRect(x: 140, y: 90, width: 320, height: 210)
        for corner in WindowCorner.allCases {
            guard let renderer = ProceduralEffects() else { check(false, "Crystal Frost shader compiles"); return }
            let source = CGPoint(x: corner.isLeft ? window.minX : window.maxX,
                                 y: corner.isTop ? window.maxY : window.minY)
            let directions = SIMD2<Float>(corner.isLeft ? 1 : -1, corner.isTop ? -1 : 1)
            func frame(_ index: Int, departure: Float? = nil) {
                _ = renderer.configure(rect: rect, source: source, arms: directions, mist: false,
                                       motion: EffectMotion(), smoke: departure, effect: .crystalFrost,
                                       windowRect: window)
                _ = renderer.render(surfaces: [], at: Double(index) / 60)
                renderer.waitForGPUForTesting()
            }
            frame(0)
            let early = renderer.snapshot(rect: rect, width: 640, height: 400)!
            for i in 1...55 { frame(i) }
            let complete = renderer.snapshot(rect: rect, width: 640, height: 400)!
            let visible: ([UInt8]) -> Int = { pixels in
                stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] > 40 }.count
            }
            check(visible(complete) > visible(early) * 3 && alphaMaximum(complete) > 100,
                  "\(corner.name) frost rapidly grows around the active corner")
            let oppositeX = Int(corner.isLeft ? window.maxX : window.minX)
            let farEdge = (0..<400).reduce(0) { count, y in
                count + ((oppositeX - 8)...(oppositeX + 8)).filter { x in
                    complete[(y * 640 + x) * 4 + 3] > 40
                }.count
            }
            check(farEdge == 0, "\(corner.name) frost and crystals leave the opposite edge clear")
            try save(complete, width: 640, height: 400,
                     to: root.appendingPathComponent("crystal-frost-\(corner.name).png"))
            frame(56, departure: 0.50)
            let shimmer = renderer.snapshot(rect: rect, width: 640, height: 400)!
            check(alphaMaximum(shimmer) > 60, "\(corner.name) completed frost remains visible during its shimmer")
            frame(57, departure: 0.99)
            let faded = renderer.snapshot(rect: rect, width: 640, height: 400)!
            check(alphaMaximum(faded) < 20, "\(corner.name) frost and flakes fade at the end")
            check(!renderer.failed, "\(corner.name) GPU work completes")
        }
    }

    private static func windHistoryCheck() {
        check(WindField.emissionRate == 580 && WindField.capacity == 1680, "Wind emission and live-particle capacity are both four times the original")
        let window = CGRect(x: -200, y: -120, width: 400, height: 240)
        var field = WindField()
        for _ in 0..<90 { field.advance(dt: 1 / 60, window: window, velocity: SIMD2(350, 0), emitting: true) }
        check(Set(field.particles.map(\.material)) == Set(0...3), "Wind contains diffuse ribbons, solid strips, dust, and leaves")
        check(field.particles.contains { abs($0.origin.y) > 170 }, "The emitted wind front is taller than the window")
        var unchangedVector = field
        unchangedVector.advance(dt: 1 / 60, window: window, velocity: SIMD2(350, 0), emitting: false)
        let previousIDs = Set(field.particles.map(\.id))
        field.advance(dt: 1 / 60, window: window.offsetBy(dx: 500, dy: 400), velocity: SIMD2(0, 400), emitting: true)
        let comparison = Dictionary(uniqueKeysWithValues: unchangedVector.particles.map { ($0.id, $0) })
        check(field.particles.filter { previousIDs.contains($0.id) }.allSatisfy {
            comparison[$0.id]?.position == $0.position && comparison[$0.id]?.velocity == $0.velocity
        }, "Turning or moving the window never rotates or relocates existing wind particles")
        for _ in 0..<60 { field.advance(dt: 1 / 60, window: window, velocity: SIMD2(0, 400), emitting: true) }
        check(field.particles.contains { previousIDs.contains($0.id) && $0.velocity.x > 250 } &&
              field.particles.contains { !previousIDs.contains($0.id) && $0.velocity.y > 250 },
              "Old and new wind directions coexist while the emitter turns")
        for _ in 0..<240 { field.advance(dt: 1 / 60, window: window, velocity: .zero, emitting: true) }
        check(field.particles.count > 900 && field.particles.count <= WindField.capacity, "Fourfold wind density remains bounded during long drags")
        for _ in 0..<160 { field.advance(dt: 1 / 60, window: window, velocity: .zero, emitting: false) }
        check(field.particles.isEmpty, "Released wind particles finish their own lifetimes without replacement")
    }

    private static func electricalBehaviourCheck() {
        let window = CGRect(x: -200, y: -120, width: 400, height: 240)
        var field = ElectricalField()
        var previous: [UInt64: (anchored: Bool, edge: Int, offset: Float, angle: Float, sweep: Bool, age: Float)] = [:]
        var pinned = true, walking = false, probing = false, sweeping = false, mixedCollapse = false, independentSwitch = false
        var longestPin: Float = 0
        var rootsOnEdges = true
        for i in 0..<720 {
            field.advance(dt: 1 / 60, window: window, corner: SIMD2(-200, -120), arms: SIMD2(1, 1), speed: 0, emitting: true)
            let states = field.fingersForTesting
            let active = states.filter { $0.age > 0 && $0.remaining > 0 }
            var changedModes = 0
            for state in active {
                rootsOnEdges = rootsOnEdges && state.offset >= 0 && state.offset <= 1
                if let old = previous[state.id] {
                    if state.anchored {
                        pinned = pinned && old.edge == state.edge && old.offset == state.offset
                        longestPin = max(longestPin, state.age)
                    } else if old.edge != state.edge || abs(old.offset - state.offset) > 0.001 { walking = true }
                    let angularSpeed = abs(state.angle - old.angle) * 60
                    if !state.sweep && angularSpeed > 0.005 && angularSpeed < 1.6 { probing = true }
                    if state.sweep && angularSpeed > 2.5 { sweeping = true }
                    if old.sweep != state.sweep { changedModes += 1 }
                }
            }
            if changedModes == 1 && active.count >= 4 { independentSwitch = true }
            if active.contains(where: \.collapsing) && active.contains(where: { !$0.collapsing }) { mixedCollapse = true }
            previous = Dictionary(uniqueKeysWithValues: active.map { ($0.id, ($0.anchored, $0.edge, $0.offset, $0.angle, $0.sweep, $0.age)) })
            if i == 60 {
                let sprites = field.sprites(departure: nil).filter { $0.appearance.y == 4 }
                check(sprites.count >= 32 && sprites[0].appearance.w > sprites[31].appearance.w * 8, "A lightning finger has a broad base tapering to a fine tip")
            }
        }
        check(rootsOnEdges, "Electrical roots stay on a window edge")
        check(pinned && longestPin > 1.1, "Pinned lightning roots hold one spot for seconds")
        check(walking, "Walking fingers travel along and around the window edges")
        check(probing && sweeping, "Fingers alternate between gentle probing and violent tip sweeps")
        check(independentSwitch && mixedCollapse, "One finger may change behaviour or collapse while others continue independently")
        check(field.fingersForTesting.count == 8, "Long-running electrical behaviour uses a bounded set of fingers")
        for _ in 0..<100 { field.advance(dt: 1 / 60, window: window, corner: SIMD2(-200, -120), arms: SIMD2(1, 1), speed: 0, emitting: false) }
        check(field.sprites(departure: nil).isEmpty, "Release collapses every finger and lets the remaining sparks expire")
    }

    private static func electricalChannelCheck() {
        var field = ElectricalField()
        let window = CGRect(x: -200, y: -120, width: 400, height: 240)
        var previous: [UInt64: (revision: Int, points: [SIMD2<Float>])] = [:]
        var stableFrames = 0, reroutes = 0, preservedRoots = true, internalChanges = 0
        var branchCounts = Set<Int>(), bounded = true
        for _ in 0..<360 {
            field.advance(dt: 1 / 60, window: window, corner: SIMD2(-200, -120), arms: SIMD2(1, 1), speed: 0, emitting: true)
            let channels = field.dischargesForTesting
            for channel in channels where channel.anchored && !channel.collapsing {
                bounded = bounded && channel.branches <= 18
                branchCounts.insert(channel.branches)
                guard let old = previous[channel.id] else { continue }
                if old.revision == channel.revision {
                    stableFrames += 1
                    preservedRoots = preservedRoots && old.points == channel.points
                } else {
                    reroutes += 1
                    preservedRoots = preservedRoots && Array(old.points.prefix(3)) == Array(channel.points.prefix(3))
                    let oldLengths = zip(old.points, old.points.dropFirst()).map { simd_length($1 - $0) }
                    let newLengths = zip(channel.points, channel.points.dropFirst()).map { simd_length($1 - $0) }
                    if zip(oldLengths, newLengths).reduce(Float(0), { $0 + abs($1.0 - $1.1) }) > 5 { internalChanges += 1 }
                }
            }
            previous = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, ($0.revision, $0.points)) })
        }
        check(stableFrames > 20 && preservedRoots, "Pinned electrical channels hold their proximal route instead of rotating as rigid sticks")
        check(reroutes > 20 && internalChanges > 20, "Restrikes rebuild the internal channel geometry, not just its endpoint")
        check(branchCounts.count > 3, "The number and arrangement of lightning streamers repeatedly reform")
        check(bounded, "Branching discharge trees remain bounded")
    }

    private static func resizeStartCheck(_ root: URL) {
        for immediate in [true, false] {
            var prefs = GesturePreferences(); prefs.resizeEffect = .furiousLightning
            prefs.immediateResize = immediate
            let windows = IdleFeedbackWindows(kind: .resize(.topLeft))
            let logger = FileLogger(directory: root.appendingPathComponent("lightning-hover"), maintenance: false)
            let engine = WindowGestureController(preferences: prefs, windows: windows, logger: logger)
            engine.attachToCurrentRunLoopForTesting()
            var latest: GestureFeedback?
            engine.onFeedback = { latest = $0 }
            engine.hoverForTesting(at: .zero, modifiers: Modifiers(command: true, extra: false)); settle(0.03)
            check(latest?.kind == .resize(.topLeft) && latest?.active == false && latest?.idle == false && windows.writeCount == 0,
                  "Command-only hover is cursor feedback, never an active resize")
            let resolves = windows.resolveCount
            let unmodified = engine.handleForTesting(.down(.right, .zero, Modifiers(command: false, extra: false)))
            _ = engine.handleForTesting(.up(.right, .zero)); settle(0.02)
            check(!unmodified.suppress && windows.resolveCount == resolves && latest?.active != true, "Right-button alone cannot begin resize visuals")
            engine.handleForTesting(.down(.right, .zero, Modifiers(command: true, extra: false))); settle(0.03)
            check(latest?.active == immediate, "Resize visuals respect Immediate versus After Small Drag activation")
            if !immediate {
                engine.handleForTesting(.drag(.right, CGPoint(x: 3, y: 0))); settle(0.02)
                check(latest?.active == false, "A subthreshold resize stays visually inactive")
            }
            engine.handleForTesting(.drag(.right, CGPoint(x: 12, y: 10))); settle(0.03)
            check(latest?.active == true && latest?.kind == .resize(.topLeft), "Command plus right-button resizing activates its effect")
            engine.handleForTesting(.up(.right, CGPoint(x: 12, y: 10))); settle(0.03)
            engine.handleForTesting(.flags(Modifiers(command: false, extra: false))); settle(0.03)
            check(latest?.dismissing == true || latest == nil, "A started resize retains its normal dismissal when Command is released")
        }
    }

    private static func windAndFizzleCheck(_ root: URL) throws {
        guard let renderer = ProceduralEffects() else { check(false, "Wind and fizzle shaders compile"); return }
        let rect = CGRect(x: -600, y: -400, width: 1200, height: 800)
        let window = CGRect(x: -200, y: -120, width: 400, height: 240)
        func windFrame(_ time: Double, departure: Float? = nil) -> [UInt8] {
            _ = renderer.configure(rect: rect, source: .zero, arms: .zero, mist: true, motion: EffectMotion(), smoke: departure, effect: .cartoonWind, windowRect: window)
            _ = renderer.render(surfaces: [], at: time); renderer.waitForGPUForTesting()
            return renderer.snapshot(rect: rect, width: 1200, height: 800)!
        }
        let entrance = windFrame(0)
        check(alphaMaximum(entrance) < 12, "Cartoon Wind starts with a soft entrance")
        var wind = entrance
        for i in 1...70 { wind = windFrame(Double(i) / 60) }
        check(alphaMaximum(wind) > 80, "Layered wind grows into visible gusts and particles")
        var exterior = 0, overWindow = 0, centre = 0
        for y in 0..<800 {
            for x in 0..<1200 where wind[(y * 1200 + x) * 4 + 3] > 12 {
                let point = CGPoint(x: Double(x) - 600, y: 400 - Double(y))
                if point.x < window.minX - 80 { exterior += 1 }
                if window.contains(point) { overWindow += 1 }
                if abs(point.x) < 50 && abs(point.y) < 30 { centre += 1 }
            }
        }
        check(exterior > 100, "Wind starts well outside the window")
        check(overWindow > 50 && centre == 0, "Wind curls over the window edge while its centre stays completely clear")
        try save(wind, width: 1200, height: 800, to: root.appendingPathComponent("cartoon-wind-exterior.png"))
        var departing = wind, wisps = wind, gone = wind
        for i in 1...156 {
            let frame = windFrame(Double(70 + i) / 60, departure: Float(i) / 156)
            if i == 12 { departing = frame }
            if i == 86 { wisps = frame }
            if i == 156 { gone = frame }
        }
        check(alphaMaximum(departing) > 50 && departing != wind, "Released wind keeps drifting instead of vanishing")
        check(alphaMaximum(wisps) > 5 && alphaMaximum(wisps) < alphaMaximum(departing), "Departing wind thins gradually into wisps")
        check(alphaMaximum(gone) == 0, "Wind is fully transparent when its natural departure finishes")
        try save(wisps, width: 1200, height: 800, to: root.appendingPathComponent("cartoon-wind-wisps.png"))

        renderer.restart()
        func lightningFrame(_ time: Double, departure: Float? = nil) -> [UInt8] {
            _ = renderer.configure(rect: rect, source: .zero, arms: SIMD2(1, 1), mist: false, motion: EffectMotion(), smoke: departure, effect: .furiousLightning, windowRect: window)
            _ = renderer.render(surfaces: [], at: time); renderer.waitForGPUForTesting()
            return renderer.snapshot(rect: rect, width: 1200, height: 800)!
        }
        let first = lightningFrame(0)
        var charged = first
        for i in 1...24 { charged = lightningFrame(Double(i) / 60) }
        check(alphaMaximum(first) < 30 && alphaMaximum(charged) > 180, "Lightning ramps from a faint charge to bright bolts")
        let fizzle = lightningFrame(0.42, departure: 0.12)
        check(alphaMaximum(fizzle) > 10 && !isGrey(fizzle) && fizzle != charged, "Lightning breaks into fading coloured sparks before the smoke fade")
        let residual = lightningFrame(0.5, departure: 0.4)
        check(alphaMaximum(residual) > 5 && !isGrey(residual), "Lightning retains a dim ionized residual while its charge fizzles")
        check(alphaMaximum(lightningFrame(0.6, departure: 1)) == 0, "Lightning finishes fully transparent")
        try save(fizzle, width: 1200, height: 800, to: root.appendingPathComponent("lightning-fizzle.png"))
        renderer.restart()
        for i in 0..<60 {
            _ = renderer.configure(rect: rect, source: CGPoint(x: window.minX, y: window.minY), arms: SIMD2(1, 1), mist: false, motion: EffectMotion(), effect: .furiousLightning, windowRect: window)
            _ = renderer.render(surfaces: [], at: Double(i) / 60)
            renderer.waitForGPUForTesting()
        }
        try save(renderer.snapshot(rect: rect, width: 1200, height: 800)!, width: 1200, height: 800, to: root.appendingPathComponent("tesla-coil-exterior.png"))
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
        for effect in WindowEffect.resizeOptions {
            prefs.resizeEffect = effect
            feedback.show(GestureFeedback(frame: quartz(appKitFrame), kind: .resize(.bottomLeft), active: false, preferences: prefs,
                window: FeedbackWindow(number: target, level: 0)))
            settle(0.04)
            check(!feedback.timerRunningForTesting && !feedback.rendererReadyForTesting && feedback.panelsForTesting.allSatisfy { !$0.isVisible },
                  "\(effect.title) cannot start on Command-only hover or pending resize feedback")
        }
        prefs.animatedEffects = false
        feedback.show(GestureFeedback(frame: quartz(appKitFrame), kind: .resize(.bottomLeft), active: false, preferences: prefs))
        check(feedback.panelsForTesting.allSatisfy { !$0.isVisible }, "Static corner markers also wait for a resize gesture")
        prefs.animatedEffects = true; prefs.resizeEffect = .iridescentEnergy
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
        prefs.resizeEffect = .furiousLightning; show(appKitFrame); settle(0.12)
        check(feedback.timerRunningForTesting && feedback.smokeCountForTesting > 0, "Changing the resize preset live overlaps the old smoke and new lightning")
        prefs.resizeEffect = .none; show(appKitFrame); settle(0.02)
        check(!feedback.timerRunningForTesting && panel.isVisible, "Disabling resize effects leaves a static corner hint without animation work")
        prefs.moveEffect = .none; show(appKitFrame, .move); settle(0.02)
        check(!feedback.timerRunningForTesting && feedback.panelsForTesting.allSatisfy { !$0.isVisible }, "Disabling move effects removes its decoration")
        prefs.moveEffect = .starlightSwirl; show(appKitFrame, .move); settle(0.12)
        check(feedback.timerRunningForTesting && panel.isVisible, "Moving can use its selected effect independently of disabled resize effects")
        prefs.moveEffect = .cartoonWind; show(appKitFrame, .move); settle(0.4)
        check(feedback.timerRunningForTesting && feedback.simulationBoundsForTesting == desktop && fullScreenSurface(panel), "Cartoon Wind renders outside the target through a full-display surface")
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
        let page = VisualEffectsPageController(.visualEffects, context: context)
        var reduced = false; page.reduceMotion = { reduced }; _ = page.view
        let checkbox = page.controls["window.feedback.animatedEffects"] as! NSButton
        let resizePopup = page.controls["window.resize.effect"] as! ActionPopup
        let movePopup = page.controls["window.move.effect"] as! ActionPopup
        let normalToggle = page.controls["visualEffects.normalWindowDrags"] as! NSButton
        check(page.controls["window.resize.effectsEnabled"] == nil && page.controls["window.move.effectsEnabled"] == nil,
              "The two effect switches have been removed")
        check(normalToggle.state == .off && !prefs.gesture.normalWindowEffects,
              "Ordinary window effects are an opt-in checkbox")
        normalToggle.state = .on; _ = normalToggle.sendAction(normalToggle.action!, to: normalToggle.target)
        check(prefs.gesture.normalWindowEffects, "Ordinary window effects choice is saved")
        check(resizePopup.itemTitles == WindowEffect.resizeOptions.map(\.title) && movePopup.itemTitles == WindowEffect.moveOptions.map(\.title), "Both gestures offer correctly scoped effect choices")
        check(resizePopup.itemTitles.first == "No Effect" && movePopup.itemTitles.first == "No Effect",
              "Both effect menus begin with No Effect")
        check(movePopup.itemTitles.contains("Cartoon Wind") && context.catalog.search("Cartoon Wind").contains { $0.id == "window.move.effect" }, "Cartoon Wind is available in the moving dropdown and Settings search")
        check(context.catalog.search("Furious Lightning").contains { $0.id == "window.resize.effect" }, "Furious Lightning is discoverable through Settings search")
        resizePopup.selectItem(withTitle: "Furious Lightning"); _ = resizePopup.sendAction(resizePopup.action!, to: resizePopup.target)
        movePopup.selectItem(withTitle: "Aurora Veil"); _ = movePopup.sendAction(movePopup.action!, to: movePopup.target)
        check(prefs.gesture.resizeEffect == .furiousLightning && prefs.gesture.moveEffect == .auroraVeil, "Dropdown actions save independent effect choices")
        resizePopup.selectItem(withTitle: "No Effect"); _ = resizePopup.sendAction(resizePopup.action!, to: resizePopup.target)
        check(prefs.gesture.resizeEffect == .none && prefs.gesture.moveEffect == .auroraVeil && resizePopup.isEnabled,
              "No Effect disables resizing visuals and leaves both selectors usable")
        resizePopup.selectItem(withTitle: "Furious Lightning"); _ = resizePopup.sendAction(resizePopup.action!, to: resizePopup.target)
        check(checkbox.isEnabled && checkbox.state == .on && prefs.gesture.animatedEffects, "Animated effects preference is searchable, enabled, and defaults on")
        reduced = true
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        let note = views(page.view).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Disabled because Reduce Motion is enabled in System Settings." }
        check(!checkbox.isEnabled && checkbox.state == .off && note?.isHidden == false, "Reduce Motion disables the checkbox and displays its explanation beside it")
        check(prefs.bool(.animatedEffects), "Reduce Motion preserves the saved animation preference")
        check(resizePopup.isEnabled && movePopup.isEnabled && prefs.gesture.resizeEffect == .furiousLightning, "Reduce Motion leaves effect choices editable without changing saved effects")
        reduced = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        check(checkbox.isEnabled && checkbox.state == .on && note?.isHidden == true, "Changing Reduce Motion restores the saved checkbox state live")
        prefs.set(false, for: .animatedEffects); page.refreshValues()
        check(!prefs.gesture.animatedEffects && checkbox.state == .off, "Explicitly disabled animation preference reaches the input engine")
        check(resizePopup.isEnabled && movePopup.isEnabled, "The master animation switch leaves effect choices editable")
        prefs.resetWindow(); page.refreshValues()
        check(prefs.gesture.animatedEffects, "Reset Window Move & Resize restores the animation default")
        check(resizePopup.titleOfSelectedItem == "Iridescent Energy" && movePopup.titleOfSelectedItem == "Blue Mist" && resizePopup.isEnabled && movePopup.isEnabled && !prefs.gesture.normalWindowEffects,
              "Reset refreshes both effect dropdowns and turns off ordinary window effects")
        let old = MemoryDefaults()
        old.set(WindowEffect.emberFlame.rawValue, forKey: PreferenceKey.resizeEffect.rawValue)
        old.set(false, forKey: "windowResizer.resizeEffectsEnabled")
        check(PreferenceStore(defaults: old).gesture.resizeEffect == .none && old.object(forKey: "windowResizer.resizeEffectsEnabled") == nil,
              "An unchecked legacy effect switch migrates to No Effect")
    }

    private static func ordinaryDragCheck() {
        let initial = OrdinaryWindowSnapshot(number: 401, owner: 32,
            frame: CGRect(x: 100, y: 100, width: 400, height: 300), level: 0)
        let current = Locked(initial)
        let observer = OrdinaryWindowEffectsObserver(hit: { point, _ in
            initial.frame.contains(point) ? current.snapshot : nil
        }, read: { number in
            let snapshot = current.snapshot
            return snapshot.number == number ? snapshot : nil
        })
        var received: [GestureFeedback] = []
        observer.onFeedback = { received.append($0) }
        var prefs = GesturePreferences()
        let titlePoint = CGPoint(x: 300, y: 111)
        observer.observe(type: .leftMouseDown, point: titlePoint, command: false, allowed: true, preferences: prefs)
        check(!observer.observingForTesting && received.isEmpty, "Normal clicks do not start observation until the option is enabled")
        prefs.normalWindowEffects = true
        observer.observe(type: .leftMouseDown, point: titlePoint, command: false, allowed: true, preferences: prefs)
        wait(1) { observer.targetForTesting != nil }
        check(observer.targetForTesting?.number == initial.number, "A normal down identifies the visible window without changing input")
        current.withValue { $0 = OrdinaryWindowSnapshot(number: 401, owner: 32, frame: initial.frame.offsetBy(dx: 40, dy: 10), level: 0) }
        observer.observe(type: .leftMouseDragged, point: CGPoint(x: 340, y: 121), command: false, allowed: true, preferences: prefs)
        wait(1) { observer.activeForTesting?.kind == .move }
        check(observer.activeForTesting?.passive == true && observer.activeForTesting?.frame == current.snapshot.frame,
              "A title-bar drag produces moving feedback from the actual window frame")
        observer.observe(type: .leftMouseUp, point: CGPoint(x: 340, y: 121), command: false, allowed: true, preferences: prefs)
        check(received.last?.dismissing == true && !observer.observingForTesting,
              "A normal mouse-up starts the effect's departure and stops sampling")

        current.withValue { $0 = initial }
        let edgePoint = CGPoint(x: 498, y: 250)
        observer.observe(type: .leftMouseDown, point: edgePoint, command: false, allowed: true, preferences: prefs)
        wait(1) { observer.targetForTesting != nil }
        current.withValue { $0 = OrdinaryWindowSnapshot(number: 401, owner: 32,
            frame: CGRect(x: 100, y: 100, width: 450, height: 300), level: 0) }
        observer.observe(type: .leftMouseDragged, point: CGPoint(x: 548, y: 250), command: false, allowed: true, preferences: prefs)
        wait(1) { if case .resize? = observer.activeForTesting?.kind { return true }; return false }
        check(observer.activeForTesting?.passive == true && observer.activeForTesting?.frame.width == 450,
              "A normal edge drag produces resizing feedback only after the window changes size")
        observer.observe(type: .leftMouseUp, point: CGPoint(x: 548, y: 250), command: false, allowed: true, preferences: prefs)
        check(OrdinaryWindowEffectsObserver.classify(initial: initial.frame, current: initial.frame.offsetBy(dx: 20, dy: 0),
                down: CGPoint(x: 300, y: 250), preferences: prefs) == nil,
              "A content drag does not trigger moving visuals")
        var disabled = prefs; disabled.moveEffect = .none
        check(OrdinaryWindowEffectsObserver.classify(initial: initial.frame, current: initial.frame.offsetBy(dx: 20, dy: 0),
                down: titlePoint, preferences: disabled) == nil,
              "No Effect suppresses ordinary moving feedback")
        disabled.resizeEffect = .none
        check(!disabled.normalWindowEffectsActive, "No selected effect leaves no passive observation work")
    }

    private static func ordinaryNativeCheck() {
        guard let screen = NSScreen.screens.first else { return }
        let window = NSWindow(contentRect: CGRect(x: screen.frame.midX - 220, y: screen.frame.midY - 150, width: 440, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Ordinary effect geometry fixture"
        window.orderFrontRegardless(); settle(0.06)
        defer { window.orderOut(nil) }
        guard let initial = OrdinaryWindowSnapshot.read(number: window.windowNumber) else {
            check(false, "Window Server exposes the native title-bar fixture"); return
        }
        let titlePoint = CGPoint(x: initial.frame.midX, y: initial.frame.minY + 14)
        let titleHit = OrdinaryWindowSnapshot.hit(at: titlePoint, excluding: [])
        if titleHit?.number != window.windowNumber {
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            print("Native hit debug: target=\(window.windowNumber), hit=\(titleHit?.number ?? -1), point=\(titlePoint)")
            for info in visible.prefix(12) {
                print("Native hit layer: id=\(info[kCGWindowNumber as String] ?? -1), owner=\(info[kCGWindowOwnerPID as String] ?? -1), level=\(info[kCGWindowLayer as String] ?? -1), bounds=\(info[kCGWindowBounds as String] ?? [:])")
            }
        }
        check(titleHit?.number == window.windowNumber,
              "A native title-bar hit resolves the foreground window")
        window.setFrameOrigin(window.frame.origin.applying(CGAffineTransform(translationX: 38, y: 0)))
        settle(0.06)
        let moved = OrdinaryWindowSnapshot.read(number: window.windowNumber)
        if moved == nil || abs(moved!.frame.minX - initial.frame.minX - 38) > 2 {
            print("Native move debug: initial=\(initial.frame), AppKit=\(window.frame), sampled=\(String(describing: moved?.frame))")
        }
        check(moved != nil && abs(moved!.frame.minX - initial.frame.minX - 38) <= 2,
              "Read-only Window Server sampling follows an actual native window move")
    }

    private static func renderPreviews(_ root: URL) throws {
        let rect = CGRect(x: -600, y: -400, width: 1200, height: 800)
        let initialWindow = CGRect(x: -180, y: -110, width: 420, height: 280)
        for effect in [WindowEffect.cartoonWind, .furiousLightning] {
            guard let renderer = ProceduralEffects() else { throw CocoaError(.coderInvalidValue) }
            let wind = effect == .cartoonWind
            let activeFrames = wind ? 180 : 360, tailFrames = wind ? 156 : 80
            let url = root.appendingPathComponent(wind ? "wind-field-preview.gif" : "tesla-lightning-preview.gif")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, (activeFrames + tailFrames + 2) / 3, nil)!
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            var motion = EffectMotion()
            for i in 0..<(activeFrames + tailFrames) {
                let t = Double(i) / 60
                let position = !wind ? CGPoint.zero : CGPoint(x: min(1.6, t) * 70, y: max(0, min(1.4, t - 1.6)) * 85)
                let window = initialWindow.offsetBy(dx: position.x, dy: position.y)
                motion.sample(position, at: t)
                let progress: Float? = i < activeFrames ? nil : Float(i - activeFrames) / Float(tailFrames - 1)
                _ = renderer.configure(rect: rect, source: wind ? CGPoint(x: window.midX, y: window.midY) : CGPoint(x: window.minX, y: window.minY),
                    arms: wind ? .zero : SIMD2(1, 1), mist: wind, motion: motion, smoke: progress, effect: effect, windowRect: window)
                _ = renderer.render(surfaces: [], at: t); renderer.waitForGPUForTesting()
                guard i % 3 == 0, let pixels = renderer.snapshot(rect: rect, width: 1200, height: 800) else { continue }
                let provider = CGDataProvider(data: Data(pixels) as CFData)!
                let overlay = CGImage(width: 1200, height: 800, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4800,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
                let context = CGContext(data: nil, width: 720, height: 480, bitsPerComponent: 8, bytesPerRow: 2880,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: 0.6, y: 0.6)
                context.setFillColor(CGColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
                let box = window.offsetBy(dx: 600, dy: 400)
                context.setFillColor(CGColor(gray: 0.18, alpha: 1)); context.addPath(CGPath(roundedRect: box, cornerWidth: 12, cornerHeight: 12, transform: nil)); context.fillPath()
                context.setStrokeColor(CGColor(gray: 0.45, alpha: 1)); context.setLineWidth(1); context.stroke(box.insetBy(dx: 0.5, dy: 0.5))
                context.setFillColor(CGColor(gray: 0.27, alpha: 1)); context.fill(CGRect(x: box.minX, y: box.maxY - 34, width: box.width, height: 1))
                for dot in 0..<3 {
                    context.setFillColor([CGColor(red: 0.95, green: 0.36, blue: 0.32, alpha: 1), CGColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 1), CGColor(red: 0.35, green: 0.76, blue: 0.38, alpha: 1)][dot])
                    context.fillEllipse(in: CGRect(x: box.minX + 16 + CGFloat(dot) * 20, y: box.maxY - 23, width: 10, height: 10))
                }
                context.draw(overlay, in: CGRect(x: 0, y: 0, width: 1200, height: 800))
                let frame = context.makeImage()!
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]] as CFDictionary)
                if i == 75 {
                    let still = CGImageDestinationCreateWithURL(root.appendingPathComponent(wind ? "wind-field-scene.png" : "tesla-lightning-scene.png") as CFURL, "public.png" as CFString, 1, nil)!
                    CGImageDestinationAddImage(still, frame, nil); _ = CGImageDestinationFinalize(still)
                }
            }
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            print("Rendered \(url.lastPathComponent)")
        }
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
