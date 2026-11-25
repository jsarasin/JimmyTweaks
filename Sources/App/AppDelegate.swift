import AppKit
import CoreServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var context: SettingsContext?
    private var settings: SettingsWindowController?
    private var menuBar: MenuBarController?
    private var staticEffects: StaticEffectsController?
    private var quitting = false
    private var shutdownFinished = false
    private var freshInstallOnQuit = false
    func applicationWillFinishLaunching(_ notification: Notification) { createMenu() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preferences = PreferenceStore()
        let logger = FileLogger()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchProperties = launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        let loginLaunch = launchProperties?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) || launchProperties?.forKeyword(AEKeyword(keyAELaunchedAsLogInItem)) != nil
        let workers = WorkerLifecycle(defaults: preferences.defaults, log: { event, detail in
            logger.log("power-helper", event, detail, severity: "WARN")
        })
        let power = AwakeSleepController(preferences: preferences, logger: logger, backend: SystemPowerBackend(workers: workers, logger: logger))
        Task { @MainActor [weak self] in
            guard let self else { return }
            await workers.prepareForLaunch { try await power.prepareHelperForUninstall() }
            guard !self.quitting else { return }
            if let error = workers.blockingError {
                let alert = NSAlert(); alert.messageText = "Couldn’t Start Jimmy Tweaks"; alert.informativeText = error
                alert.addButton(withTitle: "Quit"); alert.runModal()
                NSApp.terminate(nil); return
            }
            let permissions = PermissionCoordinator()
            let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
            let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: preferences), awakeSleep: power, workers: workers)
            self.context = context
            context.resetAndUninstallWorkers = { [weak self] in
                guard let self, !self.quitting else { return }
                self.freshInstallOnQuit = true; NSApp.terminate(nil)
            }
            self.finishLaunching(context, loginLaunch: loginLaunch)
        }
    }
    private func finishLaunching(_ context: SettingsContext, loginLaunch: Bool) {
        let preferences = context.preferences, logger = context.logger, runtime = context.runtime
        menuBar = MenuBarController(preferences: preferences, openSettings: { [weak self] in self?.showSettings(nil) }, restoreIcons: { [weak self] in self?.context?.iconAbsorber.restoreAll() }, awakeSleep: context.awakeSleep, iconAbsorber: context.iconAbsorber)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        logger.log("application", "launch", "version=\(version); build=\(build); session=\(UUID().uuidString); reason=\(loginLaunch ? "login" : "deliberate")")
        if preferences.repairMessage != nil { logger.log("preferences", "repair", "Invalid stored values repaired or replaced with safe values.", severity: "WARN") }
        if preferences.newerSchema { logger.log("preferences", "newer-schema", "Unknown newer preferences preserved.", severity: "WARN") }
        runtime.reconcile()
        staticEffects = StaticEffectsController(preferences: preferences)
        if !loginLaunch { showSettings(nil) }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.quitting else { return }
            self.context?.permissions.showStartupNotice { title, detail in
                let alert = NSAlert(); alert.alertStyle = .informational
                alert.messageText = title; alert.informativeText = detail
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
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
        settings?.window?.isRestorable = false; settings?.close(); settings = nil
        context.permissions.stopMonitoringForTermination()
        context.requests.shutdown()
        staticEffects?.shutdown()
        menuBar?.shutdown()
        context.iconAbsorber.shutdown()
        context.awakeSleep.shutdown { [weak self] powerResult in
            if case .failure(let error) = powerResult {
                context.logger.log("awake-sleep", "shutdown.restore.failure", error.localizedDescription, severity: "WARN")
            }
            self?.shutdownRuntime(context, powerResult: powerResult)
        }
        return .terminateLater
    }
    private func shutdownRuntime(_ context: SettingsContext, powerResult: Result<Void, Error>) {
        context.runtime.shutdown { [weak self] result in
            guard let self = self else { return }
            if self.freshInstallOnQuit {
                Task { @MainActor [self] in
                    do {
                        try result.get()
                        try powerResult.get()
                        try await context.workers.uninstall { try await context.awakeSleep.prepareHelperForUninstall() }
                        try await PermissionResetter.reset(bundleIdentifier: Bundle.main.bundleIdentifier)
                        context.logger.shutdown { [weak self] in
                            do {
                                guard let id = Bundle.main.bundleIdentifier else { throw PermissionResetter.Failure.missingIdentity }
                                try FreshInstallCleanup.removeUserData(bundleIdentifier: id, defaults: context.preferences.defaults)
                            } catch { self?.showCleanupFailure(error, settingsPreserved: false) }
                            self?.shutdownFinished = true; NSApp.reply(toApplicationShouldTerminate: true)
                        }
                    } catch {
                        context.logger.log("application", "cleanup.failure", error.localizedDescription, severity: "WARN")
                        self.showCleanupFailure(error, settingsPreserved: true)
                        self.finishTermination(context)
                    }
                }
            } else { self.finishTermination(context) }
        }
    }
    private func showCleanupFailure(_ error: Error, settingsPreserved: Bool) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Cleanup Incomplete"
        alert.informativeText = error.localizedDescription + (settingsPreserved ? " Your saved settings have been retained so you can reopen Jimmy Tweaks and retry cleanup." : " Some app data may remain. Reopen Jimmy Tweaks and retry cleanup.")
        alert.addButton(withTitle: "Quit"); alert.runModal()
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
