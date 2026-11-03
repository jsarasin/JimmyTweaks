import AppKit
import ApplicationServices

private final class FixtureAudio: OutputAudioHardware {
    var volume: Float32 = 0.5
    var muted = false
    var gainWrites = 0, muteWrites = 0
    func defaultOutput() throws -> AudioEndpoint { AudioEndpoint(id: 1, uid: "fixture-only") }
    func gains(_ device: UInt32) throws -> [AudioGain] { [AudioGain(channel: 0, value: volume)] }
    func setGain(_ device: UInt32, channel: UInt32, value: Float32) throws { volume = value; gainWrites += 1 }
    func mutes(_ device: UInt32) throws -> [AudioMute] { [AudioMute(channel: 0, muted: muted)] }
    func setMute(_ device: UInt32, channel: UInt32, muted: Bool) throws { self.muted = muted; muteWrites += 1 }
}

@main struct DesktopFeatureCheck {
    static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        guard !NSScreen.screens.isEmpty else { fatalError("Native display access is required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        try DesktopInteractionTests.run(logger: logger, root: root)
        try settings(root: root, logger: logger)
        try statusItem()
        terminalProbe()
        print("Native desktop feature checks passed; no real output volume or Terminal frames were changed.")
    }
    static func settle(_ duration: Double = 0.05) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
    static func settings(root: URL, logger: FileLogger) throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: prefs))
        let settings = SettingsWindowController(context: context)
        settings.showWindow(nil); let window = settings.window!
        window.orderFrontRegardless(); settle()
        defer { window.orderOut(nil); runtime.shortcuts.shutdown(); context.iconAbsorber.shutdown() }
        func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        let all = views(window.contentView!)
        let table = all.compactMap { $0 as? NSTableView }.first { $0.identifier?.rawValue == "settings.sidebar" }!
        print("Sidebar row geometry: \((0..<SettingsPage.allCases.count).map { table.rect(ofRow: $0).height }); spacing=\(table.intercellSpacing.height)")
        assert(abs(table.rect(ofRow: 0).height - table.intercellSpacing.height - 36) < 0.1)
        assert((1..<SettingsPage.allCases.count).allSatisfy { abs(table.rect(ofRow: $0).height - table.intercellSpacing.height - 26) < 0.1 })
        let audio = all.compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == "general.menuBarAudio" }!
        assert(audio.isEnabled && audio.state == .off)
        audio.performClick(nil)
        assert(prefs.bool(.menuBarAudio))
        prefs.set(false, for: .showMenuBarIcon); settings.refreshAll()
        assert(!audio.isEnabled && prefs.bool(.menuBarAudio))
        prefs.set(true, for: .showMenuBarIcon)
        window.layoutIfNeeded()
        let content = window.contentView!, bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("general-and-sidebar.png"))
        print("PASS: General is tall, other rows are compact, and the searchable audio toggle preserves intent")
    }
    static func statusItem() throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .menuBarAudio)
        let hardware = FixtureAudio()
        let bar = MenuBarController(preferences: prefs, openSettings: {}, restoreIcons: {}, audio: OutputAudioController(hardware: hardware))
        defer { bar.shutdown() }
        settle()
        let button = bar.buttonForTesting!
        let overlay = button.subviews.compactMap { $0 as? StatusAudioView }.first!
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
        overlay.scrollWheel(with: NSEvent(cgEvent: event)!)
        settle(0.15)
        assert(hardware.gainWrites == 1 && abs(hardware.volume - 0.54) < 0.001)
        assert(button.toolTip?.contains("54%") == true)
        func middle(_ type: CGEventType) -> NSEvent {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 12, y: (NSScreen.screens.first?.frame.maxY ?? 0) - 12), mouseButton: .center)!
            e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            return NSEvent(cgEvent: e)!
        }
        // Deliver native button events to the exact overlay; the fake hardware
        // lets this integration test check the real callback/queue without sound.
        overlay.otherMouseDown(with: middle(.otherMouseDown))
        // A detached event has no window; place the fixture overlay at its origin
        // for an in-bounds release rather than injecting a global mouse action.
        let hosted = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        overlay.removeFromSuperview(); overlay.frame = hosted.bounds; hosted.addSubview(overlay)
        overlay.otherMouseUp(with: middle(.otherMouseUp)); settle(0.15)
        assert(hardware.muted, "Middle click: point=\(middle(.otherMouseUp).locationInWindow), bounds=\(overlay.bounds)")
        prefs.set(true, for: .suspended)
        overlay.scrollWheel(with: NSEvent(cgEvent: event)!); settle(0.08)
        assert(hardware.gainWrites == 1)
        assert(button.window != nil && button.image?.isTemplate == true)
        print("PASS: native status item scroll/middle-click callbacks, asynchronous device updates, feedback, and suspension")
    }
    static func terminalProbe() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
        let pids = Set(apps.map(\.processIdentifier))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let sizes = list.compactMap { item -> CGSize? in
            guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                  let bounds = item[kCGWindowBounds as String] as? [String: NSNumber],
                  let width = bounds["Width"]?.doubleValue, let height = bounds["Height"]?.doubleValue else { return nil }
            return CGSize(width: width, height: height)
        }
        print("Read-only Terminal probe: running=\(!apps.isEmpty), visible window sizes=\(sizes), fixture AX trust=\(AXIsProcessTrusted()).")
    }
}
