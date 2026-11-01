import AppKit
import CoreServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: SettingsContext?
    private var settings: SettingsWindowController?
    private var menuBar: MenuBarController?
    private var quitting = false
    private var shutdownFinished = false
    private var resetPermissionsOnQuit = false
    func applicationWillFinishLaunching(_ notification: Notification) { createMenu() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = PreferenceStore()
        let logger = FileLogger()
        let permissions = PermissionCoordinator()
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let login = LoginService(preferences: preferences)
        context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: login)
        context?.resetPermissionsAndQuit = { [weak self] in
            guard let self = self, !self.quitting else { return }
            self.resetPermissionsOnQuit = true
            NSApp.terminate(nil)
        }
        menuBar = MenuBarController(preferences: preferences, openSettings: { [weak self] in self?.showSettings(nil) }, restoreIcons: { [weak self] in self?.context?.iconAbsorber.restoreAll() })
        let event = NSAppleEventManager.shared().currentAppleEvent
        let properties = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        let loginLaunch = properties?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) || properties?.forKeyword(AEKeyword(keyAELaunchedAsLogInItem)) != nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        logger.log("application", "launch", "version=\(version); build=\(build); session=\(UUID().uuidString); reason=\(loginLaunch ? "login" : "deliberate")")
        if preferences.repairMessage != nil { logger.log("preferences", "repair", "Invalid stored values repaired or replaced with safe values.", severity: "WARN") }
        if preferences.newerSchema { logger.log("preferences", "newer-schema", "Unknown newer preferences preserved.", severity: "WARN") }
        runtime.reconcile()
        if !loginLaunch { showSettings(nil) }
    }
    @objc func showSettings(_ sender: Any?) {
        guard let context = context else { return }
        if settings == nil { settings = SettingsWindowController(context: context) }
        settings?.present()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(nil); return false }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownFinished || context == nil { return .terminateNow }
        guard !quitting else { return .terminateLater }; quitting = true
        guard let context = context else { return .terminateNow }
        context.permissions.stopMonitoringForTermination()
        menuBar?.shutdown()
        context.iconAbsorber.shutdown()
        context.runtime.shutdown { [weak self] in
            guard let self = self else { return }
            if self.resetPermissionsOnQuit {
                Task { @MainActor in
                    do {
                        try await context.runtime.shortcuts.runner.waitForCancellation()
                        try await PermissionResetter.reset(bundleIdentifier: Bundle.main.bundleIdentifier)
                        context.logger.log("permissions", "reset", "App-scoped macOS privacy permission reset completed.")
                    } catch {
                        context.logger.log("permissions", "reset.failure", error.localizedDescription, severity: "WARN")
                        let alert = NSAlert(); alert.alertStyle = .warning
                        alert.messageText = "Couldn’t Reset All Permissions"
                        alert.informativeText = error.localizedDescription + " Jimmy Tweaks will quit. Reopen it before trying again."
                        alert.addButton(withTitle: "Quit"); alert.runModal()
                    }
                    self.finishTermination(context)
                }
            } else { self.finishTermination(context) }
        }
        return .terminateLater
    }
    private func finishTermination(_ context: SettingsContext) {
        context.logger.log("application", "shutdown", "Explicit application quit.")
        context.logger.shutdown { [weak self] in
            self?.shutdownFinished = true; NSApp.reply(toApplicationShouldTerminate: true)
        }
    }
    private func createMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu(title: "Jimmy Tweaks")
        main.addItem(appItem); appItem.submenu = appMenu
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ","); settings.target = self
        appMenu.addItem(settings); appMenu.addItem(.separator())
        let restore = NSMenuItem(title: "Restore Absorbed Menu Bar Items", action: #selector(restoreIcons), keyEquivalent: "")
        restore.target = self; appMenu.addItem(restore)
        appMenu.addItem(NSMenuItem(title: "Quit Jimmy Tweaks", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = main
    }
    @objc private func restoreIcons() { context?.iconAbsorber.restoreAll() }
}
