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
}
