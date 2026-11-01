import AppKit

/// An optional, first-party status item. It never changes foreign status items.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let preferences: PreferenceStore
    private let openSettings: () -> Void
    private let restoreIcons: () -> Void
    private var item: NSStatusItem?
    private var observation: NSObjectProtocol?
    private let suspendItem = NSMenuItem(title: "Suspend All", action: nil, keyEquivalent: "")
    init(preferences: PreferenceStore, openSettings: @escaping () -> Void, restoreIcons: @escaping () -> Void) {
        self.preferences = preferences; self.openSettings = openSettings; self.restoreIcons = restoreIcons
        super.init()
        observation = NotificationCenter.default.addObserver(forName: .preferencesChanged, object: preferences, queue: .main) { [weak self] _ in self?.update() }
        update()
    }
    static func makeIcon() -> NSImage {
        BrandIcon.menuBarImage()
    }
    private func update() {
        guard preferences.bool(.showMenuBarIcon) else {
            if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil; return
        }
        guard item == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.autosaveName = "JimmyTweaks.MenuBar"
        status.button?.image = Self.makeIcon(); status.button?.toolTip = "Jimmy Tweaks"
        status.button?.setAccessibilityLabel("Jimmy Tweaks")
        let menu = NSMenu(); menu.delegate = self
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self
        menu.addItem(settings); menu.addItem(.separator())
        suspendItem.target = self; suspendItem.action = #selector(toggleSuspension); menu.addItem(suspendItem)
        let restore = NSMenuItem(title: "Restore Absorbed Icons", action: #selector(restore), keyEquivalent: ""); restore.target = self; menu.addItem(restore)
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit Jimmy Tweaks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu; item = status
    }
    func menuNeedsUpdate(_ menu: NSMenu) { suspendItem.state = preferences.bool(.suspended) ? .on : .off }
    @objc private func showSettings() { openSettings() }
    @objc private func restore() { restoreIcons() }
    @objc private func toggleSuspension() { preferences.set(!preferences.bool(.suspended), for: .suspended) }
    func shutdown() {
        if let observation { NotificationCenter.default.removeObserver(observation) }; observation = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
    deinit { shutdown() }
}
