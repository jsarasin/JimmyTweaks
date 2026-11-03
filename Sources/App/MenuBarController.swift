import AppKit

/// An optional, first-party status item. It never changes foreign status items.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let preferences: PreferenceStore
    private let openSettings: () -> Void
    private let restoreIcons: () -> Void
    private var item: NSStatusItem?
    private var observation: NSObjectProtocol?
    private let audio: OutputAudioController
    private let audioQueue = DispatchQueue(label: "app.jimmytweaks.status-volume", qos: .userInitiated)
    private let audioAllowed = Locked(false)
    private var stopped = false
    private let suspendItem = NSMenuItem(title: "Suspend All", action: nil, keyEquivalent: "")
    init(preferences: PreferenceStore, openSettings: @escaping () -> Void, restoreIcons: @escaping () -> Void, audio: OutputAudioController = OutputAudioController()) {
        self.preferences = preferences; self.openSettings = openSettings; self.restoreIcons = restoreIcons
        self.audio = audio
        super.init()
        observation = NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in self?.update() }
        update()
    }
    static func makeIcon() -> NSImage {
        BrandIcon.menuBarImage()
    }
    private func update() {
        guard !stopped else { return }
        let enabled = preferences.bool(.showMenuBarIcon) && preferences.bool(.menuBarAudio) && !preferences.bool(.suspended)
        audioAllowed.withValue { $0 = enabled }
        item?.button?.toolTip = enabled ? "Jimmy Tweaks — scroll for volume; middle-click to mute" : "Jimmy Tweaks"
        guard preferences.bool(.showMenuBarIcon) else {
            if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil; return
        }
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = "JimmyTweaks.MenuBar"
        status.button?.image = Self.makeIcon(); status.button?.toolTip = "Jimmy Tweaks"
        status.button?.setAccessibilityLabel("Jimmy Tweaks")
        if let button = status.button {
            let overlay = StatusAudioView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.enabled = { [weak self] in self?.audioAllowed.snapshot == true }
            overlay.adjust = { [weak self] delta in self?.audioAction { try $0.adjust(by: delta) } }
            overlay.toggleMute = { [weak self] in self?.audioAction { try $0.toggleMute() } }
            overlay.setAccessibilityHidden(true)
            button.addSubview(overlay)
            button.toolTip = enabled ? "Jimmy Tweaks — scroll for volume; middle-click to mute" : "Jimmy Tweaks"
        }
        let menu = NSMenu(); menu.delegate = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(settings); menu.addItem(.separator())
        suspendItem.target = self; suspendItem.action = #selector(toggleSuspension); menu.addItem(suspendItem)
        let restore = NSMenuItem(title: "Restore Absorbed Icons", action: #selector(restore), keyEquivalent: ""); restore.target = self; menu.addItem(restore)
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Jimmy Tweaks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu; item = status
    }
    func menuNeedsUpdate(_ menu: NSMenu) { suspendItem.state = preferences.bool(.suspended) ? .on : .off }
    private func audioAction(_ operation: @escaping (OutputAudioController) throws -> AudioFeedback) {
        audioQueue.async { [weak self] in
            guard let self, self.audioAllowed.snapshot else { return }
            let message: String
            do { message = try operation(self.audio).text }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.stopped, self.audioAllowed.snapshot else { return }
                self.item?.button?.toolTip = "Jimmy Tweaks — " + message
                if let button = self.item?.button {
                    button.setAccessibilityValue(message)
                    NSAccessibility.post(element: button, notification: .announcementRequested, userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
        }
    }
    @objc private func showSettings() { openSettings() }
    @objc private func restore() { restoreIcons() }
    @objc private func toggleSuspension() { preferences.set(!preferences.bool(.suspended), for: .suspended) }
    func shutdown() {
        stopped = true; audioAllowed.withValue { $0 = false }
        if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
    deinit { shutdown() }
    #if TESTING
    var buttonForTesting: NSStatusBarButton? { item?.button }
    #endif
}
