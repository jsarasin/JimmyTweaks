import AppKit

@main struct AwakeSleepFeatureCheck {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        AwakeSleepTests.run(logger: logger)
        try await WorkerLifecycleTests.run(root: root)
        try await degradedSettings(root: root, logger: logger)
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: prefs))
        let window = SettingsWindowController(context: context)
        window.showWindow(nil)
        for page in [SettingsPage.awakeSleep, .permissions] {
            context.navigate?(SearchDestination(page: page, controlID: ""))
            try await Task.sleep(nanoseconds: 100_000_000)
            window.window!.layoutIfNeeded()
            let view = window.window!.contentView!
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render settings") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(page.rawValue + ".png"))
        }
        assert(context.catalog.search("amphetamine").contains { $0.destination.page == .awakeSleep })
        assert(context.catalog.search("uninstall workers").contains { $0.id == "permissions.reset" })
        var confirmed = false, requested = false
        context.confirm = { title, detail, completion in
            assert(title == "Reset Permissions and Uninstall Workers?" && detail.contains("permanently deletes")); confirmed = true; completion()
        }
        context.resetAndUninstallWorkers = { requested = true }
        let permissionsPage = window.window!.contentViewController!.children.flatMap(\.children).compactMap { $0 as? PermissionsPageController }.first!
        (permissionsPage.controls["permissions.reset"] as! ActionButton).performClick(nil)
        assert(confirmed && requested, "Reset is routed through the confirmation before requesting cleanup")
        context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown(); window.close()
        print("Native Awake & Sleep / cleanup settings, searchable controls, and reset confirmation passed. No real power, worker-registration, privacy-reset, or user-data actions were performed.")
    }
    @MainActor private static func degradedSettings(root: URL, logger: FileLogger) async throws {
        let prefs = PreferenceStore(defaults: MemoryDefaults()), backend = FixturePower()
        backend.helperAvailable = false; backend.powerActionsAllowed = false
        backend.helperStatus = "Sleep restoration is unresolved. Power actions are paused; the existing helper and recovery data have been retained. Closed-lid support is disabled until reset."
        let power = AwakeSleepController(preferences: prefs, logger: logger, backend: backend,
            automaticTimer: false, observeSystem: false, showsWarnings: false)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger,
            login: LoginService(preferences: prefs), awakeSleep: power)
        let controller = SettingsWindowController(context: context)
        controller.showWindow(nil)
        context.navigate?(SearchDestination(page: .general, controlID: ""))
        context.navigate?(SearchDestination(page: .awakeSleep, controlID: ""))
        let page = controller.window!.contentViewController!.children.flatMap(\.children).compactMap { $0 as? AwakeSleepPageController }.first!
        for id in ["awakeSleep.keepAwake.start", "awakeSleep.sleep.start", "awakeSleep.shutDown.start", "awakeSleep.sleepNow", "awakeSleep.helper"] {
            assert((page.controls[id] as! NSControl).isEnabled == false, "Unresolved recovery disables \(id)")
        }
        for width in [960, 780] {
            controller.window!.setContentSize(NSSize(width: width, height: 800))
            context.navigate?(SearchDestination(page: .awakeSleep, controlID: "awakeSleep.helper"))
            try await Task.sleep(nanoseconds: 100_000_000)
            controller.window!.layoutIfNeeded()
            let view = controller.window!.contentView!, image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("helper-recovery-\(width).png"))
        }
        backend.powerActionsAllowed = true; page.refreshValues()
        assert((page.controls["awakeSleep.keepAwake.start"] as! NSControl).isEnabled)
        backend.powerActionsAllowed = false; backend.helperNeedsApproval = true; page.refreshValues()
        assert((page.controls["awakeSleep.helper"] as! ActionButton).title == "Open Login Items…")
        assert((page.controls["awakeSleep.helper"] as! NSControl).isEnabled, "Approval remains actionable while restoration is pending")
        context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown(); controller.close()
        print("Degraded startup Settings passed: unrelated navigation, power-action gating, approval action, ordinary fallback, and native renders at 960/780 points.")
    }

}
