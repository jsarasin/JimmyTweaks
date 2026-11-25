import AppKit

/// An optional, first-party status item. It never changes foreign status items.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let preferences: PreferenceStore
    private let openSettings: () -> Void
    private let restoreIcons: () -> Void
    private var item: NSStatusItem?
    private var observation: NSObjectProtocol?
    private let audio: OutputAudioController
    private let powerMenu: AwakeSleepMenu?
    private let iconAbsorber: IconAbsorberController?
    private var absorbedMenuItems: [NSMenuItem] = []
    private let audioQueue = DispatchQueue(label: "app.jimmytweaks.status-volume", qos: .userInitiated)
    private let audioAllowed = Locked(false)
    private var stopped = false
    private let suspendItem = NSMenuItem(title: "Suspend All", action: nil, keyEquivalent: "")
    init(preferences: PreferenceStore, openSettings: @escaping () -> Void, restoreIcons: @escaping () -> Void, audio: OutputAudioController = OutputAudioController(), awakeSleep: AwakeSleepController? = nil, iconAbsorber: IconAbsorberController? = nil) {
        self.preferences = preferences; self.openSettings = openSettings; self.restoreIcons = restoreIcons
        self.audio = audio
        self.powerMenu = awakeSleep.map(AwakeSleepMenu.init(controller:))
        self.iconAbsorber = iconAbsorber
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
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        powerMenu?.append(to: menu)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(settings); menu.addItem(.separator())
        suspendItem.target = self; suspendItem.action = #selector(toggleSuspension); menu.addItem(suspendItem)
        let restore = NSMenuItem(title: "Restore Absorbed Icons", action: #selector(restore), keyEquivalent: ""); restore.target = self; menu.addItem(restore)
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Jimmy Tweaks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu; item = status
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        suspendItem.state = preferences.bool(.suspended) ? .on : .off; powerMenu?.refresh()
        refreshAbsorbedItems(in: menu)
    }
    private func refreshAbsorbedItems(in menu: NSMenu) {
        for row in absorbedMenuItems where row.menu === menu { menu.removeItem(row) }
        absorbedMenuItems = []
        guard let iconAbsorber, iconAbsorber.enabled, !iconAbsorber.absorbedItems.isEmpty else { return }
        absorbedMenuItems.append(.sectionHeader(title: "Absorbed Icons"))
        for absorbed in iconAbsorber.absorbedItems {
            let siblings = iconAbsorber.absorbedItems.filter { $0.bundle == absorbed.bundle }
            var title = absorbed.name
            if siblings.count > 1 {
                let label = absorbed.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let uniqueLabel = !label.isEmpty && label != absorbed.name && siblings.filter { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) == label }.count == 1
                title += uniqueLabel ? " — \(label)" : " — Item \(absorbed.index + 1)"
            }
            let row = NSMenuItem(title: title, action: #selector(openAbsorbedItem(_:)), keyEquivalent: "")
            row.target = self; row.representedObject = absorbed
            row.isEnabled = iconAbsorber.canInvokeStatusItems
            let picture = iconAbsorber.images[absorbed.id]
            let source = picture ?? NSRunningApplication(processIdentifier: absorbed.pid)?.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: absorbed.name)
            if let image = source?.copy() as? NSImage {
                let longest = max(image.size.width, image.size.height)
                if longest > 0 { image.size = NSSize(width: image.size.width * 18 / longest, height: image.size.height * 18 / longest) }
                row.image = image
            }
            row.toolTip = iconAbsorber.previewBlockedReason ?? "Open \(absorbed.name)’s original controls" + (picture == nil ? " (application icon; use Refresh Icon Pictures in Settings for the original icon)." : ".")
            absorbedMenuItems.append(row)
        }
        absorbedMenuItems.append(.separator())
        for (index, row) in absorbedMenuItems.enumerated() { menu.insertItem(row, at: index) }
    }
    @objc private func openAbsorbedItem(_ sender: NSMenuItem) {
        guard let absorbed = sender.representedObject as? AbsorbedStatusItem else { return }
        // Let the J menu finish closing before opening another application's controls.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, let iconAbsorber = self.iconAbsorber else { return }
            var anchor: CGPoint?, visibleFrame = CGRect.zero
            if let button = self.item?.button, let window = button.window, let primaryHeight = NSScreen.screens.first?.frame.height {
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                let screen = window.screen?.visibleFrame ?? .zero
                anchor = CGPoint(x: rect.minX, y: primaryHeight - rect.minY + 8)
                visibleFrame = CGRect(x: screen.minX, y: primaryHeight - screen.maxY, width: screen.width, height: screen.height)
            }
            iconAbsorber.activate(absorbed, anchor: anchor, visibleFrame: visibleFrame)
        }
    }
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
    var menuForTesting: NSMenu? { item?.menu }
    #endif
}
