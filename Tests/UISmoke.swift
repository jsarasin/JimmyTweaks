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
        ShortcutTests.run(logger: logger)
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
        var demo = ShortcutDefinition(); demo.name = "Selection to Clipboard"
        demo.combination = ShortcutCombination(input: .key, code: 28, modifiers: (1 << 20) | (1 << 17), keyLabel: "8")
        demo.actions = [ShortcutActionInstance(actionID: "builtin.delay", parameters:["seconds":"0.25"]), ShortcutActionInstance(actionID:"builtin.screenshot.clipboard")]
        prefs.shortcuts = [demo]
        context.navigate?(SearchDestination(page:.shortcuts,controlID:"")); settle()
        try snapshot("shortcuts-populated")
        let shortcutPage = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? CustomShortcutsPageController }.first!
        shortcutPage.actionsTable.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); settle()
        let up = views(shortcutPage.view).compactMap { $0 as? ActionButton }.first { $0.title == "Up" }!
        up.handler?(); settle()
        assert(prefs.shortcuts[0].actions.map(\.actionID) == ["builtin.screenshot.clipboard","builtin.delay"], "Up reorders persisted action instances")
        views(shortcutPage.view).compactMap { $0 as? ActionButton }.first { $0.title == "Down" }!.handler?(); settle()
        assert(prefs.shortcuts[0].actions == demo.actions, "Down restores exact action identities and parameters")
        shortcutPage.actionsTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); settle()
        assert(views(shortcutPage.view).compactMap { $0 as? CommitField }.contains { $0.stringValue == "0.25" }, "Selected Delay exposes decimal editing")
        let picker = ShortcutActionPickerController(registry:runtime.shortcuts.registry) { _ in }
        let pickerSearch = views(picker.window!.contentView!).compactMap { $0 as? NSSearchField }.first!
        pickerSearch.stringValue = "delay"; picker.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:pickerSearch))
        let pickerTable = views(picker.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        assert(pickerTable.numberOfRows == 2, "Picker search keeps the category and matching action")
        picker.close()
        // Repeated opens must retain one responsive picker, never orphan its controller.
        let openPicker = views(shortcutPage.view).compactMap { $0 as? ActionButton }.first { $0.accessibilityLabel() == "Add Action" }!
        openPicker.handler?(); settle()
        let ownedPicker = window.childWindows!.first { $0.title == "Add Action" }!
        assert(ownedPicker.canBecomeKey && ownedPicker.isVisible, "Picker is visible and accepts keyboard focus")
        assert(ownedPicker.firstResponder is NSTextView, "Picker focuses its search editor")
        openPicker.handler?(); settle()
        assert(window.childWindows!.filter { $0.title == "Add Action" }.count == 1 && window.childWindows!.contains { $0 === ownedPicker }, "Repeated Add Action reuses its owned window")
        views(ownedPicker.contentView!).compactMap { $0 as? ActionButton }.first { $0.title == "Cancel" }!.performClick(nil); settle()
        assert(!ownedPicker.isVisible && ownedPicker.parent == nil, "Cancel closes and detaches the picker")
        openPicker.handler?(); settle()
        let reopenedPicker = window.childWindows!.first { $0.title == "Add Action" }!
        assert(reopenedPicker !== ownedPicker, "Closing releases the picker controller so reopening starts cleanly")
        reopenedPicker.performClose(nil); settle()
        assert(!reopenedPicker.isVisible && reopenedPicker.parent == nil, "Title-bar close closes and detaches the picker")
        openPicker.handler?(); settle()
        let parentBoundPicker = window.childWindows!.first { $0.title == "Add Action" }!
        window.close(); settle()
        assert(!parentBoundPicker.isVisible && parentBoundPicker.parent == nil, "Closing Settings closes its action picker")
        controller.showWindow(nil); settle()
        prefs.shortcuts = []
        for id in ["global.suspendAll", "window.move.threshold", "window.resize.activation", "scripts.runPreview", "permissions.accessibility.open", "general.menuBarIcon", "logging.open", "iconAbsorber.enabled", "iconAbsorber.restore", "iconAbsorber.preview"] {
            assert(context.catalog.entries.contains { $0.id == id }, "Missing required searchable control: \(id)")
        }
        print("UI content frame: \(window.contentView!.frame); metadata entries: \(context.catalog.entries.count)")
        assert(window.contentView!.frame.width >= 780, "Settings must preserve its minimum usable width")
        assert(context.catalog.search("move threshold").contains { $0.id == "window.move.threshold" })
        assert(context.catalog.search("script preview").contains { $0.destination.page == .scripts })
        assert(context.catalog.search("menu bar").contains { $0.destination.page == .iconAbsorber })
        assert(SettingsPage.allCases.map(\.title) == ["General", "Permissions", "Window Resizer", "Icon Absorber", "Custom Shortcuts", "Reoccurring Scripts", "Logging", "About"])
        assert(window.titlebarAccessoryViewControllers.isEmpty, "The redundant top status strip is removed")
        context.navigate?(SearchDestination(page: .general, controlID: "")); settle()
        let generalViews = views(window.contentView!)
        let systemSettingsButtons = generalViews.compactMap { $0 as? NSButton }.filter { $0.title == "Open System Settings" }
        assert(systemSettingsButtons.isEmpty, "General keeps preferences; permission controls live in Permissions")
        assert(!context.catalog.entries.contains { $0.id.hasPrefix("assistant.") || $0.id == "navigation.status" })
        assert(context.catalog.entries.contains { $0.id == "navigation.permissions" }, "Permissions has a sidebar and search destination")
        assert(!generalViews.contains { $0 is SystemAccessGuide }, "Permission guidance moved out of General")
        assert(!generalViews.compactMap { $0 as? NSTextField }.contains { ["BACKGROUND AGENT", "Diagnostics", "UI Stub", "UTILITIES", "APPLICATION"].contains($0.stringValue) })
        assert(generalViews.compactMap { $0 as? NSSearchField }.first!.frame.height >= 30, "Sidebar Search matches the taller system control")
        // Module links navigate inside Jimmy Tweaks; they never open system dialogs.
        prefs.shortcuts = [demo]
        for (source, entry) in [(SettingsPage.window, PermissionEntry.accessibility), (.iconAbsorber, .accessibility), (.iconAbsorber, .screenRecording), (.shortcuts, .accessibility), (.shortcuts, .inputMonitoring), (.shortcuts, .screenRecording)] {
            context.navigate?(SearchDestination(page:source, controlID:"")); settle()
            let linkID = "\(source.rawValue).permissions.\(entry.rawValue)"
            let link = views(window.contentView!).compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == linkID }!
            assert(!link.isHidden && !link.isBordered, "Each required permission is presented as a module hyperlink")
            link.performClick(nil); settle()
            let destinationPage = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? PermissionsPageController }.first!
            let target = destinationPage.controls[entry.controlID]!
            assert(destinationPage.scroll.documentVisibleRect.intersects(destinationPage.scroll.documentView!.convert(target.bounds,from:target)), "Link scrolls to the matching permission entry")
            assert(target.layer?.borderWidth == 2, "Link highlights its permission entry: \(source.rawValue)/\(entry.rawValue), border \(String(describing: target.layer?.borderWidth))")
            assert(views(destinationPage.view).contains { $0 is SystemAccessGuide }, "Permissions owns the System Settings guide")
        }
        assert(context.catalog.search("screen recording").contains { $0.destination.page == .permissions && $0.id == "permissions.screenRecording" }, "Permission entries are searchable")
        let permissionsPage = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? PermissionsPageController }.first!
        let resetButton = permissionsPage.controls["permissions.reset"] as! ActionButton
        let savedConfirm = context.confirm, savedReset = context.resetPermissionsAndQuit
        var permissionResetRequests = 0, permissionResetConfirmation: (() -> Void)?
        context.confirm = { title, _, completion in
            assert(title == "Reset macOS Permissions and Quit?")
            permissionResetConfirmation = completion
        }
        context.resetPermissionsAndQuit = { permissionResetRequests += 1 }
        resetButton.performClick(nil)
        assert(permissionResetConfirmation != nil && permissionResetRequests == 0, "Reset requires confirmation before requesting termination")
        permissionResetConfirmation?()
        assert(permissionResetRequests == 1, "Confirmation routes to the app's reset-and-quit lifecycle")
        context.confirm = savedConfirm; context.resetPermissionsAndQuit = savedReset

        prefs.shortcuts = []
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
