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
        check(discovery.applicationListMessage?.contains("Open System Settings") == true, "An empty list explains missing access even while absorption is off")
        trusted = true; discoveryPermissions.refresh()
        let deadline = Date().addingTimeInterval(2)
        while scanCount.snapshot == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(scanCount.snapshot > 0 && !discovery.enabled && !discovery.isHolding, "Granting access starts discovery without enabling absorption")
        trusted = false; discoveryPermissions.refresh()
        check(discovery.items.isEmpty && discovery.applicationListMessage?.contains("Open System Settings") == true, "Revocation clears stale discoveries and restores guidance")
        discovery.shutdown()
        client.stop(); module.shutdown()
        print("Icon Absorber: \(checks) selection, persistence, permission and service-isolation checks passed. No live hiding or private assertions used.")
    }
}
