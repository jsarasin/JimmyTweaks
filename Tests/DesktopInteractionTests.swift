import AppKit

private final class FakeOutputHardware: OutputAudioHardware {
    var endpoint = AudioEndpoint(id: 1, uid: "speakers")
    var values: [UInt32: [AudioGain]] = [1: [AudioGain(channel: 1, value: 0.4), AudioGain(channel: 2, value: 0.2)], 2: [AudioGain(channel: 0, value: 0.7)]]
    var muteValues: [UInt32: [AudioMute]] = [1: [AudioMute(channel: 0, muted: false)], 2: []]
    var reads = 0, failedChannel: UInt32?
    var writes: [UInt32] = []
    func defaultOutput() throws -> AudioEndpoint { reads += 1; return endpoint }
    func gains(_ device: UInt32) throws -> [AudioGain] { values[device] ?? [] }
    func setGain(_ device: UInt32, channel: UInt32, value: Float32) throws {
        if failedChannel == channel { throw OutputAudioError.failed(-1) }
        writes.append(device)
        if let i = values[device]?.firstIndex(where: { $0.channel == channel }) { values[device]![i].value = value }
    }
    func mutes(_ device: UInt32) throws -> [AudioMute] { muteValues[device] ?? [] }
    func setMute(_ device: UInt32, channel: UInt32, muted: Bool) throws {
        if let i = muteValues[device]?.firstIndex(where: { $0.channel == channel }) { muteValues[device]![i] = AudioMute(channel: channel, muted: muted) }
    }
}
private final class DelayedAdmissionWindows: WindowAccessing {
    var callback: ((WindowTarget?) -> Void)?
    var valid: (() -> Bool)?
    var applyCount = 0
    var hoverValid: (() -> Bool)?
    func resolve(point: CGPoint, button: MouseButton?, preferences: GesturePreferences, deadline: TimeInterval, stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void) {
        if button == nil { hoverValid = stillValid; completion(nil) }
        else { callback = completion; valid = stillValid }
    }
    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate, restoring: Bool, completion: @escaping (Result<CGRect, WindowAccessError>) -> Void) {
        applyCount += 1; completion(.success(target.seed.desiredFrame(at: pointer)))
    }
}

enum DesktopInteractionTests {
    static func run(logger: FileLogger, root: URL) throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; assert(value(), "Desktop interaction: " + message) }
        func settle(_ duration: Double = 0.015) {
            let until = Date().addingTimeInterval(duration)
            while Date() < until { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.003)) }
        }
        let hardware = FakeOutputHardware() // Never change the real output in tests.
        let volume = OutputAudioController(hardware: hardware)
        let first = try volume.adjust(by: 0.1)
        check(abs(first.volume! - 0.5) < 0.001 && abs(hardware.values[1]![1].value - 0.25) < 0.001, "volume adjustment preserves channel balance")
        check(try! volume.toggleMute().muted, "middle click can enable native hardware mute")
        check(!(try! volume.toggleMute()).muted, "second middle click unmutes")
        _ = try volume.adjust(by: 9)
        check(hardware.values[1]!.map(\.value).max() == 1, "volume clamps at maximum")
        _ = try volume.adjust(by: -9)
        check(hardware.values[1]!.allSatisfy { $0.value == 0 }, "volume clamps at zero")
        hardware.endpoint = AudioEndpoint(id: 2, uid: "headphones")
        let second = try volume.adjust(by: -0.1)
        check(abs(second.volume! - 0.6) < 0.001 && hardware.writes.last == 2, "the current output is resolved for every action")
        check(try! volume.toggleMute().muted && hardware.values[2]![0].value == 0, "devices without mute controls use a saved-volume mute")
        check(!(try! volume.toggleMute()).muted && abs(hardware.values[2]![0].value - 0.6) < 0.001, "software unmute restores the original volume")
        _ = try volume.toggleMute(); _ = try volume.adjust(by: 0.1)
        check(abs(hardware.values[2]![0].value - 0.7) < 0.001, "scrolling while muted restores saved volume before adjustment")
        hardware.endpoint = AudioEndpoint(id: 1, uid: "speakers")
        hardware.values[1] = [AudioGain(channel: 1, value: 0.4), AudioGain(channel: 2, value: 0.2)]
        hardware.failedChannel = 2
        do { _ = try volume.adjust(by: 0.2); check(false, "a rejected channel write must report failure") }
        catch { check(hardware.values[1]![0].value == 0.4, "partial audio failures roll back previously changed channels") }
        hardware.failedChannel = nil; hardware.values[1] = []; hardware.muteValues[1] = []
        do { _ = try volume.adjust(by: 0.1); check(false, "fixed-volume outputs must report unsupported") }
        catch { check(true, "unsupported outputs report a recoverable result") }
        var scroll = VolumeScrollAccumulator()
        check(scroll.change(delta: 1, precise: false, inverted: false, momentum: false) == 0.04, "wheel up raises volume")
        check(scroll.change(delta: 1, precise: false, inverted: true, momentum: false) == -0.04, "natural scrolling is normalized to physical direction")
        check(scroll.change(delta: 6, precise: true, inverted: false, momentum: false) == nil, "fine scrolling accumulates before changing volume")
        check(scroll.change(delta: 6, precise: true, inverted: false, momentum: false) == 0.04, "fine scrolling crosses a predictable adjustment threshold")
        check(scroll.change(delta: 100, precise: true, inverted: false, momentum: true) == nil, "trackpad momentum never continues volume changes")
        let overlay = StatusAudioView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        var enabled = true; overlay.enabled = { enabled }
        check(overlay.captures(type: .scrollWheel, button: 0) && overlay.captures(type: .otherMouseDown, button: 2), "enabled status overlay captures wheel and middle button")
        check(!overlay.captures(type: .leftMouseDown, button: 0) && !overlay.captures(type: .rightMouseUp, button: 1) && !overlay.captures(type: .otherMouseDown, button: 3), "normal menu clicks and additional buttons pass through")
        var delta: Float32?
        overlay.adjust = { delta = $0 }
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        overlay.scrollWheel(with: NSEvent(cgEvent: wheel)!)
        check(delta != nil, "a real AppKit scroll event reaches the overlay action")
        enabled = false
        check(!overlay.captures(type: .scrollWheel, button: 0) && !overlay.captures(type: .otherMouseDown, button: 2), "disabled audio controls do not intercept input")
        let pref = PreferenceStore(defaults: MemoryDefaults())
        check(!pref.bool(.menuBarAudio), "audio control defaults off")

        var moving: WindowTarget!
        let pointer = CGPoint(x: 320, y: 200)
        if !NSScreen.screens.isEmpty {
        let own = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 640, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        own.minSize = CGSize(width: 300, height: 220); own.orderFrontRegardless()
        defer { own.orderOut(nil) }
        let transparent = NSPanel(contentRect: own.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        transparent.isOpaque = false; transparent.backgroundColor = .clear; transparent.ignoresMouseEvents = true
        transparent.orderFrontRegardless(); settle()
        let routedAccess = AccessibilityWindows(hitTest: { _, _ in AXUIElementCreateApplication(getpid()) })
        let routedFrame = AccessibilityWindows.screenFrame(own)
        var routed: WindowTarget?, routeFinished = false
        routedAccess.resolve(point: CGPoint(x: routedFrame.midX, y: routedFrame.midY), button: .left, preferences: GesturePreferences(),
            deadline: ProcessInfo.processInfo.systemUptime + 0.18, stillValid: { true }) { routed = $0; routeFinished = true }
        let routeDeadline = Date().addingTimeInterval(1)
        while !routeFinished && Date() < routeDeadline { settle() }
        let cocoaPoint = CGPoint(x: own.frame.midX, y: own.frame.midY)
        let hitNumber = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        if hitNumber == own.windowNumber {
            check(routeFinished && routed?.localWindow === own, "native hit routing skips our mouse-transparent effect surfaces")
        } else {
            check(routeFinished && routed == nil, "native hit routing does not reach through a foreign foreground surface")
            print("Positive native pointer routing is obscured by a foreign foreground surface; native frame transactions are tested independently.")
        }
        transparent.orderOut(nil)
        let access = AccessibilityWindows(hitTest: { _, _ in AXUIElementCreateApplication(getpid()) }, localHitTest: { _ in own })
        func resolve(_ point: CGPoint, _ button: MouseButton) -> WindowTarget? {
            var result: WindowTarget?, done = false
            access.resolve(point: point, button: button, preferences: GesturePreferences(), deadline: ProcessInfo.processInfo.systemUptime + 0.18, stillValid: { true }) { result = $0; done = true }
            let deadline = Date().addingTimeInterval(1)
            while !done && Date() < deadline { settle() }
            check(done, "own-window resolution completes on main without cross-process writes")
            return result
        }
        func apply(_ target: WindowTarget, _ pointer: CGPoint, valid: Bool = true) -> Result<CGRect, WindowAccessError> {
            let gate = GenerationGate(); if valid { gate.open(1) }
            var result: Result<CGRect, WindowAccessError>?
            access.apply(target: target, pointer: pointer, generation: 1, gate: gate, restoring: false) { result = $0 }
            let deadline = Date().addingTimeInterval(1)
            while result == nil && Date() < deadline { settle() }
            check(result != nil, "native frame operation completes")
            return result!
        }
        let initial = AccessibilityWindows.screenFrame(own)
        let pointer = CGPoint(x: initial.midX, y: initial.midY)
        moving = resolve(pointer, .left)!
        check(moving.usesNativeWindow && moving.seed.kind == .move, "Jimmy Tweaks' own window is an eligible move target")
        let accepted = try apply(moving, CGPoint(x: pointer.x + 31, y: pointer.y + 24)).get()
        check(abs(accepted.minX - initial.minX - 31) < 0.01 && abs(accepted.minY - initial.minY - 24) < 0.01, "own-window movement preserves the original pointer offset: initial=\(initial), accepted=\(accepted), seed=\(moving.seed), native=\(own.frame)")
        for corner in WindowCorner.allCases {
            let start = AccessibilityWindows.screenFrame(own)
            let p = corner.point(in: start)
            let target = resolve(p, .right)!
            let offset = CGPoint(x: p.x + (corner.isLeft ? -20 : 20), y: p.y + (corner.isTop ? -16 : 16))
            let resized = try apply(target, offset).get()
            check(WindowGeometry.distance(corner.anchor(in: resized), corner.anchor(in: start)) < 0.01, "all own-window resize corners preserve their opposite anchor")
        }
        let full = AccessibilityWindows.screenFrame(own)
        let corner = WindowCorner.topLeft
        let shrinking = resolve(corner.point(in: full), .right)!
        let small = try apply(shrinking, CGPoint(x: full.minX + 10_000, y: full.minY + 10_000)).get()
        check(small.width >= own.minSize.width && small.height >= own.minSize.height && WindowGeometry.distance(corner.anchor(in: small), corner.anchor(in: full)) < 0.01,
              "own-window minimum size preserves the opposite corner")
        let current = AccessibilityWindows.screenFrame(own)
        let cancelled = resolve(CGPoint(x: current.midX, y: current.midY), .left)!
        let before = own.frame
        if case .failure(.cancelled) = apply(cancelled, .zero, valid: false) { check(own.frame == before, "cancellation blocks late local writes") }
        else { check(false, "cancelled own-window operation must fail") }
        } else {
            // AppKit constrains real NSWindows to an empty frame when the test
            // process has no display. The native fixture runs this exact branch
            // with display access; keep non-display regression coverage here.
            moving = WindowTarget(element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "test.fixture",
                seed: GestureSeed(frame: CGRect(x: 0, y: 0, width: 640, height: 400), pointer: pointer, kind: .move))
            print("Own-window frame checks deferred to the native-display fixture.")
        }
        let terminal = CGRect(x: 0, y: 0, width: 640, height: 400)
        check(WindowGeometry.activationKind(at: CGPoint(x: 320, y: 200), frame: terminal, edgeZoneSize: 200) == .move, "a short Terminal-sized window retains a reachable moving centre")
        let observed = CGRect(x: 0, y: 0, width: 849, height: 497)
        check(WindowGeometry.activationKind(at: CGPoint(x: observed.midX, y: observed.midY + 70), frame: observed, edgeZoneSize: 200) == .move,
              "Terminal-sized windows have a broad moving centre rather than a narrow text-selection trap")
        let inset = WindowGeometry.effectiveEdgeZoneSize(frame: terminal, requested: 200)
        check(WindowGeometry.activationKind(at: CGPoint(x: 320, y: inset), frame: terminal, edgeZoneSize: 200) != .move &&
              WindowGeometry.activationKind(at: CGPoint(x: 320, y: inset + 0.01), frame: terminal, edgeZoneSize: 200) == .move, "adaptive zones still meet at exactly one boundary")

        let delayed = DelayedAdmissionWindows()
        let engine = WindowGestureController(preferences: GesturePreferences(), windows: delayed, logger: logger)
        engine.attachToCurrentRunLoopForTesting()
        let command = Modifiers(command: true, extra: false)
        engine.hoverForTesting(at: pointer, modifiers: command)
        check(delayed.hoverValid?() == true, "hover starts with a valid cancellable generation")
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pointer, mouseButton: .left)!
        _ = engine.handleForTesting(.down(.left, pointer, command), event: down)
        check(delayed.hoverValid?() == false, "starting a gesture invalidates queued hover work")
        settle(0.095)
        check(!engine.hasDeferredReplayForTesting && delayed.valid?() == true, "slow admission beyond the old 75 ms cutoff does not replay a Terminal text-selection drag")
        delayed.callback?(moving); settle()
        check(engine.handleForTesting(.drag(.left, CGPoint(x: pointer.x + 20, y: pointer.y))).suppress, "a delayed valid target claims the drag")
        settle()
        check(delayed.applyCount > 0 && !engine.hasDeferredReplayForTesting, "claimed drags change geometry without click replay")
        _ = engine.handleForTesting(.up(.left, pointer)); settle()

        let expired = DelayedAdmissionWindows()
        let late = WindowGestureController(preferences: GesturePreferences(), windows: expired, logger: logger)
        late.attachToCurrentRunLoopForTesting()
        _ = late.handleForTesting(.down(.left, pointer, command), event: down)
        settle(0.22)
        check(late.hasDeferredReplayForTesting, "admission remains bounded and preserves truly unclaimed clicks")
        expired.callback?(moving); settle()
        check(expired.applyCount == 0, "a late target cannot resurrect a timed-out gesture")
        late.stop(discardPending: true); settle(); _ = late.handleForTesting(.up(.left, pointer)); settle()
        try icons(root: root) { check($0, $1) }
        print("\(checks) desktop interaction checks passed: own-window geometry, delayed admission, audio routing/mute/scroll, themed icons, and safe fallbacks.")
    }
    private static func icons(root: URL, check: (Bool, String) -> Void) throws {
        for (token, style, dark) in [("RegularDark", ModuleIconAppearance.Style.dark, true), ("ClearLight", .clear, false), ("ClearDark", .clear, true),
                                     ("TintedLight", .tinted, false), ("TintedDark", .tinted, true), ("TintedAutomatic", .tinted, true)] {
            let appearance = ModuleIconAppearance.resolve(theme: token, systemDark: true)
            check(appearance.style == style && appearance.dark == dark, "system icon-style tokens map to the correct artwork")
        }
        check(ModuleIconAppearance.resolve(theme: "future-style", systemDark: true).style == .standard, "unknown icon styles safely fall back")
        let width = 820, height = 350
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(white: 0.25, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        for (row, style) in ModuleIconAppearance.Style.allCases.enumerated() {
            var signatures = Set<Data>()
            for (column, page) in SettingsPage.allCases.enumerated() {
                let appearance = ModuleIconAppearance(style: style, dark: style != .standard, tint: .systemPurple)
                let image = ModuleIcons.image(for: page, appearance: appearance)
                check(!image.isTemplate && image.size == NSSize(width: 64, height: 64), "each module has full-color, scale-independent artwork")
                signatures.insert(image.tiffRepresentation!)
                image.draw(in: NSRect(x: CGFloat(12 + column * 90), y: CGFloat(276 - row * 84), width: 62, height: 62))
            }
            check(signatures.count == SettingsPage.allCases.count, "every module icon is distinct in each appearance")
        }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("module-icon-variants.png"))
    }
}
