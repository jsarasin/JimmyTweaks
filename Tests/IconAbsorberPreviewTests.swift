import AppKit

enum IconAbsorberPreviewTests {
    static func run(logger: FileLogger) {
        func settle() { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(3)
            while !condition() && Date() < end { settle() }
            assert(condition(), "Timed out waiting for the preview invocation")
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let preferences = PreferenceStore(defaults: MemoryDefaults())
        preferences.set(false, for: .enabled)
        preferences.set(false, for: .iconAbsorberPositionPanels)
        preferences.iconAbsorberSelection = IconAbsorberSelection(["org.example.preview"])
        preferences.set(true, for: .iconAbsorberEnabled)
        var trusted = true
        let permissions = PermissionCoordinator(checkAccessibility: { trusted }, checkEventPosting: { false }, requestEventPosting: { false },
                                              checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let item = AbsorbedStatusItem(id: "preview/item", bundle: "org.example.preview", name: "Preview Fixture", pid: 12345, index: 0,
                                     identifier: "item", label: "", element: AXUIElementCreateApplication(12345), frame: CGRect(x: 100, y: 0, width: 24, height: 24), actions: [kAXPressAction])
        let unsupported = AbsorbedStatusItem(id: "system/item", bundle: "com.apple.MenuBarAgent", name: "System", pid: 12346, index: 0,
                                            identifier: "com.apple.menuextra.audiovideo", label: "Audio and Video Controls", element: AXUIElementCreateApplication(12346), frame: nil, actions: [])
        let snapshot = Locked(StatusItemSnapshot(items: [item], systemItems: [unsupported]))
        let calls = Locked<[String]>([]), actionResult = Locked(AXError.actionUnsupported)
        let visibleSurfaces = Locked<[StatusItemAccess.Surface]>([])
        var time = Date(timeIntervalSince1970: 1_000)
        var operations = StatusItemInvocation.Operations()
        operations.readWindows = { _ in [] }
        operations.performAction = { _, action in calls.withValue { $0.append(action) }; return actionResult.snapshot }
        operations.canPost = { preconditionFailure("Preview tests must not post native mouse events") }
        let module = IconAbsorberController(preferences: preferences, permissions: permissions, logger: logger,
                                            scanItems: { snapshot.snapshot }, invocationOperations: operations,
                                            surfaces: { visibleSurfaces.snapshot }, now: { time })
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger,
                                      login: LoginService(preferences: preferences), iconAbsorber: module)
        let settings = SettingsWindowController(context: context), window = settings.window!
        context.navigate?(SearchDestination(page: .iconAbsorber, controlID: ""))
        module.setPanelVisible(true)
        wait { module.state == "Compatibility Pause" && !module.items.isEmpty }
        window.layoutIfNeeded()
        func button() -> NSButton {
            views(window.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Open Preview Fixture status item 1" }!
        }
        func message() -> NSTextField {
            views(window.contentView!).first { $0.identifier?.rawValue == "iconAbsorber.invocation" } as! NSTextField
        }
        assert(button().isEnabled && module.canInvokeStatusItems && !module.isHolding,
               "A compatibility pause must restore icons while leaving native preview invocation enabled")
        let bar = MenuBarController(preferences: preferences, openSettings: {}, restoreIcons: { module.restoreAll() }, iconAbsorber: module)
        let menu = bar.menuForTesting!
        func menuRows() -> [NSMenuItem] { menu.items.filter { $0.representedObject is AbsorbedStatusItem } }
        bar.menuNeedsUpdate(menu); bar.menuNeedsUpdate(menu)
        assert(menuRows().count == 1 && menuRows()[0].title == item.name && menuRows()[0].image != nil,
               "Reopening the J menu lists each selected status item once with its application name and fallback icon")
        assert(menuRows()[0].isEnabled && menuRows()[0].image!.size.width <= 18 && menuRows()[0].image!.size.height <= 18)
        menu.performActionForItem(at: menu.index(of: menuRows()[0]))
        wait { calls.snapshot == [kAXPressAction] && module.invocationFailed }
        calls.withValue { $0 = [] }
        button().performClick(nil)
        wait { calls.snapshot == [kAXPressAction] && module.invocationFailed }
        assert(module.state == "Compatibility Pause" && !module.isHolding, "Opening controls must preserve the hiding compatibility guard")
        assert(message().stringValue.contains("Accessibility error") && !message().isHidden,
               "A rejected action must remain visible after visibility-state reconciliation")

        actionResult.withValue { $0 = .success }
        button().performClick(nil)
        wait { calls.snapshot.count == 2 }
        time = time.addingTimeInterval(3)
        wait { module.invocationFailed && message().stringValue.contains("No original menu or panel") }
        assert(module.state == "Compatibility Pause", "Missing controls must not falsely mark hiding Enabled")

        button().performClick(nil)
        wait { calls.snapshot.count == 3 }
        visibleSurfaces.withValue { $0 = [StatusItemAccess.Surface(id: 42, pid: item.pid, frame: CGRect(x: 100, y: 30, width: 200, height: 200), layer: 1)] }
        wait { message().stringValue.contains("Using the application") }
        assert(!module.invocationFailed)
        visibleSurfaces.withValue { $0 = [] }
        wait { message().stringValue.contains("have closed") }
        assert(module.state == "Compatibility Pause" && !module.isHolding)

        preferences.set(true, for: .suspended)
        assert(!button().isEnabled && message().stringValue.contains("Resume All"))
        bar.menuNeedsUpdate(menu)
        assert(menuRows().count == 1 && !menuRows()[0].isEnabled && menuRows()[0].toolTip?.contains("Resume All") == true,
               "Suspension keeps absorbed items listed but disables their menu actions")
        let previous = calls.snapshot.count
        button().performClick(nil)
        button().rightMouseDown(with: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        for _ in 0..<3 { settle() }
        assert(calls.snapshot.count == previous, "Suspended preview buttons must ignore both mouse buttons")
        preferences.set(false, for: .suspended)
        wait { module.state == "Compatibility Pause" }

        // Missing helper is a visibility failure, not a failure to open visible controls.
        snapshot.withValue { $0.systemItems = [] }; module.refresh()
        wait { module.failure != nil }
        assert(button().isEnabled && module.canInvokeStatusItems && !module.isHolding)
        button().performClick(nil)
        wait { calls.snapshot.count == previous + 1 }

        let second = AbsorbedStatusItem(id: "preview/second", bundle: item.bundle, name: item.name, pid: item.pid, index: 1,
                                       identifier: "second", label: "Secondary Controls", element: item.element, frame: item.frame, actions: item.actions)
        snapshot.withValue { $0.items = [second, item] }; module.refresh()
        wait { module.items.count == 2 }
        bar.menuNeedsUpdate(menu)
        assert(menuRows().map(\.title) == ["Preview Fixture — Item 1", "Preview Fixture — Secondary Controls"],
               "Multiple status items retain their native order and get distinct names")
        snapshot.withValue { $0.items = [item] }; module.refresh()
        wait { module.items.count == 1 }
        bar.menuNeedsUpdate(menu)
        assert(menuRows().map(\.title) == [item.name], "Disappearing status items are removed when the menu opens again")
        trusted = false; permissions.refresh()
        assert(!module.canInvokeStatusItems && message().stringValue.contains("Accessibility"), "Revoked access must explain blocked preview invocation")
        assert(module.invocationMessage == nil, "Cancellation must not leave a stale Opening Controls message")
        bar.menuNeedsUpdate(menu)
        assert(menuRows().isEmpty, "Revoking access removes stale menu discoveries")
        module.restoreAll(); bar.menuNeedsUpdate(menu)
        assert(menuRows().isEmpty && !menu.items.contains { $0.title == "Absorbed Icons" },
               "Restore All removes the absorbed section while preserving the normal J menu")
        assert(menu.items.contains { $0.title == "Settings…" } && menu.items.contains { $0.title == "Restore Absorbed Icons" })
        bar.shutdown(); module.shutdown(); runtime.shortcuts.shutdown(); window.orderOut(nil)
        print("Icon Absorber preview and J-menu regressions passed: named icons, native action routing, multiple/disappearing items, suspension/restoration, persistent errors, and surface tracking. No real status item was invoked.")
    }
}
