import AppKit

@main struct IconAbsorberTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(condition(), message)
        }
        let monitor = "app.monitorcontrol.MonitorControl", mouse = "com.lujjjh.LinearMouse", other = "org.example.status"
        var selection = IconAbsorberSelection([monitor, monitor, "com.apple.controlcenter", "local.jimmytweaks.app", "invalid", "bad/slash.bundle", mouse])
        check(selection.bundles == [monitor, mouse], "Reject duplicates, system apps, our own app, and invalid identities")
        selection.select(other, selected: true); selection.select(monitor, selected: true)
        check(selection.bundles == [monitor, mouse, other], "Repeated selection preserves chosen order")
        selection.move(other, before: monitor)
        check(selection.bundles == [other, monitor, mouse], "Move application as a whole")
        selection.move(other, before: nil)
        check(selection.bundles == [monitor, mouse, other], "Move application to the end")
        selection.move(monitor, before: monitor); selection.move(mouse, before: "org.missing.app")
        check(selection.bundles == [monitor, mouse, other], "Invalid/self drops preserve order")
        selection.select(mouse, selected: false)
        check(selection.bundles == [monitor, other], "Deselect removes only that application")
        let defaults = MemoryDefaults(), prefs = PreferenceStore(defaults: MemoryDefaults())
        check(!prefs.bool(.iconAbsorberEnabled) && !prefs.bool(.iconAbsorberHiddenPress), "Module and experimental activation are off by default")
        let original = PreferenceStore(defaults: defaults)
        original.iconAbsorberSelection = selection; original.set(true, for: .iconAbsorberEnabled)
        let reloaded = PreferenceStore(defaults: defaults)
        check(reloaded.iconAbsorberSelection == selection && reloaded.bool(.iconAbsorberEnabled), "Applications, ordering and enabled state survive store recreation")
        reloaded.set(true, for: .suspended); reloaded.resetWindow()
        check(reloaded.iconAbsorberSelection == selection && reloaded.bool(.iconAbsorberEnabled) && reloaded.bool(.suspended), "Window-only reset preserves Icon Absorber and suspension")
        reloaded.resetAll()
        check(reloaded.iconAbsorberSelection.bundles.isEmpty && !reloaded.bool(.iconAbsorberEnabled), "Reset All restores Icon Absorber defaults")
        defaults.set(42, forKey: "iconAbsorber.applications")
        check(reloaded.iconAbsorberSelection.bundles.isEmpty, "Malformed saved application lists fail safely")
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false })
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let logger = FileLogger(directory: root, maintenance: false)
        let module = IconAbsorberController(preferences: prefs, permissions: permissions, logger: logger)
        prefs.iconAbsorberSelection = IconAbsorberSelection([monitor]); prefs.set(true, for: .iconAbsorberEnabled)
        check(module.state == "Permission Required" && !module.isHolding, "Missing AX permission never starts a visibility assertion")
        module.restoreAll()
        check(!module.enabled && !module.isHolding && module.selectedBundles == [monitor], "Restore All disables the module while retaining selections")
        let client = IconAssertionClient()
        var completions = 0, failures = 0
        client.onFailure = { _ in failures += 1 }
        client.apply(hidden: [monitor]) { result in if case .failure = result { completions += 1 } }
        check(completions == 1 && failures == 1 && !client.held, "Missing bundled helper reports one failure and leaves the host running")
        var trusted = false
        let discoveryPermissions = PermissionCoordinator(checkAccessibility: { trusted }, checkEventPosting: { true }, requestEventPosting: { true })
        let scanCount = Locked(0)
        let discovery = IconAbsorberController(preferences: PreferenceStore(defaults: MemoryDefaults()), permissions: discoveryPermissions, logger: logger, scanItems: {
            scanCount.withValue { $0 += 1 }; return StatusItemSnapshot()
        })
        discovery.setPanelVisible(true)
        check(discovery.applicationListMessage?.contains("Permissions → Accessibility") == true, "An empty list explains missing access even while absorption is off")
        trusted = true; discoveryPermissions.refresh()
        let deadline = Date().addingTimeInterval(2)
        while scanCount.snapshot == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(scanCount.snapshot > 0 && !discovery.enabled && !discovery.isHolding, "Granting access starts discovery without enabling absorption")
        trusted = false; discoveryPermissions.refresh()
        check(discovery.items.isEmpty && discovery.applicationListMessage?.contains("Permissions → Accessibility") == true, "Revocation clears stale discoveries and restores guidance")
        discovery.shutdown()
        // Controlled native-operation boundaries: no status item is invoked and
        // no mouse event is posted to another process by these checks.
        func item(actions: [String] = []) -> AbsorbedStatusItem {
            AbsorbedStatusItem(id: "test/item", bundle: other, name: "Test", pid: 12345, index: 0, identifier: "item", label: "",
                               element: AXUIElementCreateApplication(12345), frame: CGRect(x: 100, y: 10, width: 24, height: 24), actions: actions)
        }
        for rightClick in [false, true] {
            var valid = true, actionCalls = 0, ownerChecks = 0, posts = 0
            var operations = StatusItemInvocation.Operations()
            operations.readWindows = { _ in valid = false; return [] }
            operations.performAction = { _, _ in actionCalls += 1; return .success }
            operations.canPost = { true }
            operations.hitOwner = { _ in ownerChecks += 1; return 12345 }
            operations.post = { _, _ in posts += 1 }
            for actions in [[], [kAXShowMenuAction]] {
                valid = true
                let result = StatusItemInvocation.invoke(item(actions: actions), rightClick: rightClick, stillValid: { valid }, operations: operations)
                check(result == nil && actionCalls == 0 && ownerChecks == 0 && posts == 0,
                      "Cancellation during the windows read prevents AXPress, AXShowMenu, and right-click posting")
            }
        }
        var valid = true, posts: [CGEventType] = []
        var operations = StatusItemInvocation.Operations()
        operations.readWindows = { _ in [] }
        operations.performAction = { _, _ in preconditionFailure("The right-click fallback must not perform an AX action") }
        operations.canPost = { true }
        operations.hitOwner = { _ in valid = false; return 12345 }
        operations.post = { event, pid in check(pid == 12345, "Posting is scoped to the item's owner"); posts.append(event.type); valid = false }
        check(StatusItemInvocation.invoke(item(), rightClick: true, stillValid: { valid }, operations: operations) == nil && posts.isEmpty,
              "Cancellation during owner hit testing prevents both right-click events")
        valid = true; operations.hitOwner = { _ in 12345 }
        check(StatusItemInvocation.invoke(item(), rightClick: true, stillValid: { valid }, operations: operations)?.error == .success,
              "An admitted right-click pair completes even if cancellation follows its down")
        check(posts == [.rightMouseDown, .rightMouseUp], "An admitted pair never leaves an orphan mouse down")
        for (rightClick, expectedAction) in [(false, kAXPressAction), (true, kAXShowMenuAction)] {
            var actions: [String] = []
            operations.performAction = { _, action in actions.append(action); return .success }
            let result = StatusItemInvocation.invoke(item(actions: [kAXShowMenuAction]), rightClick: rightClick, stillValid: { true }, operations: operations)
            check(result?.error == .success && actions == [expectedAction], "Valid original-control invocations retain their native action")
        }
        var reads = 0; operations.readWindows = { _ in reads += 1; return [] }
        check(StatusItemInvocation.invoke(item(), rightClick: false, stillValid: { false }, operations: operations) == nil && reads == 0,
              "Already cancelled requests perform no AX reads")
        client.stop(); module.shutdown()
        print("Icon Absorber: \(checks) selection, persistence, permission and service-isolation checks passed. No live hiding or private assertions used.")
    }
}
