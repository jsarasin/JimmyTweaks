import AppKit

@main struct UISmoke {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(), logger = FileLogger(directory: root.appendingPathComponent("logs"), maintenance: false)
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: prefs, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: prefs))
        EngineTests.run(logger: logger)
        let controller = SettingsWindowController(context: context)
        guard let window = controller.window else { fatalError("Settings window missing") }
        window.layoutIfNeeded()
        func settle() { let end = Date().addingTimeInterval(0.18); while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }; window.layoutIfNeeded() }
        func views(_ parent: NSView) -> [NSView] { [parent] + parent.subviews.flatMap(views) }
        func snapshot(_ name: String) throws {
            guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render Settings") }
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
        }
        for page in SettingsPage.allCases {
            context.navigate?(SearchDestination(page: page, controlID: "")); settle()
            assert(window.contentViewController is NSSplitViewController)
            try snapshot(page.rawValue)
        }
        for id in ["global.suspendAll", "window.move.threshold", "window.resize.activation", "scripts.runPreview", "general.openSystemSettings", "general.menuBarIcon", "logging.open", "iconAbsorber.enabled", "iconAbsorber.restore", "iconAbsorber.preview"] {
            assert(context.catalog.entries.contains { $0.id == id }, "Missing required searchable control: \(id)")
        }
        print("UI content frame: \(window.contentView!.frame); metadata entries: \(context.catalog.entries.count)")
        assert(window.contentView!.frame.width >= 780, "Settings must preserve its minimum usable width")
        assert(context.catalog.search("move threshold").contains { $0.id == "window.move.threshold" })
        assert(context.catalog.search("script preview").contains { $0.destination.page == .scripts })
        assert(context.catalog.search("menu bar").contains { $0.destination.page == .iconAbsorber })
        assert(SettingsPage.allCases.map(\.title) == ["General", "Window Resizer", "Icon Absorber", "Reoccurring Scripts", "Logging", "About"])
        assert(window.titlebarAccessoryViewControllers.isEmpty, "The redundant top status strip is removed")
        context.navigate?(SearchDestination(page: .general, controlID: "")); settle()
        let generalViews = views(window.contentView!)
        let systemSettingsButtons = generalViews.compactMap { $0 as? NSButton }.filter { $0.title == "Open System Settings" }
        assert(systemSettingsButtons.count == 1, "One System Settings entry point on General")
        assert(!context.catalog.entries.contains { $0.id.hasPrefix("assistant.") || $0.id == "navigation.permissions" || $0.id == "navigation.status" })
        assert(generalViews.contains { $0 is SystemAccessGuide }, "General includes the condensed fictional-account guide")
        assert(!generalViews.compactMap { $0 as? NSTextField }.contains { ["BACKGROUND AGENT", "Permissions", "Diagnostics", "UI Stub", "UTILITIES", "APPLICATION"].contains($0.stringValue) })
        assert(generalViews.compactMap { $0 as? NSSearchField }.first!.frame.height >= 30, "Sidebar Search matches the taller system control")
        let mark = MenuBarController.makeIcon()
        assert(mark.isTemplate && mark.size == NSSize(width: 20, height: 20), "Serif J adapts to the menu bar appearance")
        assert(context.catalog.search("not-a-setting-349138").isEmpty)
        context.navigate?(SearchDestination(page: .window, controlID: "window.move.threshold")); settle()
        if let field = views(window.contentView!).first(where: { $0.identifier?.rawValue == "window.move.threshold" }) as? NSTextField {
            assert(field.stringValue == "5")
        } else { fatalError("Threshold control missing") }
        if let field = views(window.contentView!).first(where: { $0.identifier?.rawValue == "window.resize.cornerSize" }) as? NSTextField {
            assert(field.stringValue == "200", "Corner size defaults to 200 points")
        } else { fatalError("Corner size control missing") }
        if let search = views(window.contentView!).compactMap({ $0 as? NSSearchField }).first {
            search.stringValue = "move threshold"
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search)); settle()
            if let action = search.action { _ = search.sendAction(action, to: search.target) }
            settle()
            assert(search.stringValue.isEmpty, "Return activation clears the query")
            assert(views(window.contentView!).contains { $0.identifier?.rawValue == "window.move.threshold" }, "Search activation must show the control's page")
            search.stringValue = "nothing-matches-193849"
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search)); settle()
            assert(views(window.contentView!).compactMap({ $0 as? NSTextField }).contains { $0.stringValue.hasPrefix("No settings found") })
            try snapshot("search-empty")
        } else { fatalError("Native search field missing") }
        // Own-process hits must be rejected before any attribute traversal.
        var hitTests = 0
        let ownWindows = AccessibilityWindows(hitTest: { _, _ in
            assert(Thread.isMainThread, "Local AppKit accessibility hit-testing requires main")
            hitTests += 1
            return AXUIElementCreateApplication(getpid())
        })
        let attributeReads = Locked(0)
        ownWindows.onAttributeReadForTesting = { attributeReads.withValue { $0 += 1 } }
        var localPID: pid_t = 0
        assert(AXUIElementGetPid(AXUIElementCreateApplication(getpid()), &localPID) == .success && localPID == getpid())
        let resolved = Locked(false)
        DispatchQueue.global(qos: .userInteractive).async {
            ownWindows.resolve(point: .zero, button: .right, preferences: prefs.gesture,
                               deadline: ProcessInfo.processInfo.systemUptime + 2, stillValid: { true }) { target in
                assert(target == nil, "Our own process must never become a window target")
                resolved.withValue { $0 = true }
            }
        }
        let resolutionDeadline = Date().addingTimeInterval(3)
        while !resolved.snapshot && Date() < resolutionDeadline { settle() }
        assert(resolved.snapshot && hitTests == 1, "Background resolution completes through main-thread hit testing")
        assert(attributeReads.snapshot == 0, "Reject own-process hits before traversing AppKit attributes")

        // Numeric resets replace invalid drafts even when the stored value was
        // already the default; unrelated refreshes preserve inline validation.
        context.navigate?(SearchDestination(page: .window, controlID: "window.move.threshold")); settle()
        let thresholdField = views(window.contentView!).first { $0.identifier?.rawValue == "window.move.threshold" } as! NSTextField
        let numeric = thresholdField.superview!.superview!.superview as! NumericEditor
        thresholdField.stringValue = "invalid"
        numeric.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: thresholdField))
        controller.refreshAll()
        assert(thresholdField.stringValue == "invalid", "Ordinary refresh preserves a rejected draft")
        prefs.resetWindow(); settle()
        assert(thresholdField.stringValue == "5" && numeric.stepper.integerValue == 5, "Reset clears invalid text even at the default value")
        assert(views(numeric).compactMap { $0 as? NSTextField }.filter { $0.textColor == .systemRed }.allSatisfy(\.isHidden))

        // Removed dynamic samples and seed rows must disappear from search;
        // Reset All must rebuild the catalog without reopening Settings.
        let scripts = ScriptsPageController(.scripts, context: context)
        _ = scripts.view
        context.preview.enabled = true
        let sample = context.preview.add()
        scripts.selectSample(sample)
        let savedEntry = context.catalog.entries.first { $0.destination.sampleID == sample }!
        context.preview.scripts.removeAll { $0.id == sample || $0.id == "sample.cleanup" }
        scripts.refreshValues()
        assert(!context.catalog.entries.contains { $0.destination.sampleID == sample || $0.destination.sampleID == "sample.cleanup" })
        assert(savedEntry.availability() != nil, "An already-rendered result explains that its sample was removed")
        context.preview.reset(); scripts.refreshValues()
        assert(context.catalog.entries.contains { $0.destination.sampleID == "sample.cleanup" })
        assert(!context.catalog.entries.contains { $0.destination.sampleID == sample })

        // Closing Settings preserves the application and its live runtime.
        let lifecycle = AppDelegate()
        assert(!lifecycle.applicationShouldTerminateAfterLastWindowClosed(app))
        window.close(); settle()
        assert(!window.isVisible)
        prefs.set(false, for: .enabled); prefs.set(false, for: .suspended)
        assert(runtime.state == .disabled, "Runtime still observes preferences after Settings closes")
        controller.showWindow(nil); settle()
        assert(window.isVisible, "Settings can reopen without recreating the agent")
        print("Native UI smoke passed: \(SettingsPage.allCases.count) AppKit pages, search/navigation, defaults, main-thread hit testing, and Settings close/reopen with a live runtime.")
        window.orderOut(nil)
    }
}
