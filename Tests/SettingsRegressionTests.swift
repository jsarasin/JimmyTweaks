import AppKit

enum SettingsRegressionTests {
    static func run(logger: FileLogger) {
        let preferences = PreferenceStore(defaults: MemoryDefaults()); preferences.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false },
                                              checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: preferences))
        var a = ShortcutDefinition(); a.name = "A"
        var b = ShortcutDefinition(); b.name = "B"
        preferences.shortcuts = [a, b]
        let settings = SettingsWindowController(context: context)
        let window = settings.window!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func settle(_ seconds: Double = 0.03) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        }
        context.navigate?(SearchDestination(page: .shortcuts, controlID: "")); settle()
        let page = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? CustomShortcutsPageController }.first!
        func startRecording(_ title: String) {
            views(page.view).compactMap { $0 as? ActionButton }.first { $0.title == title }!.performClick(nil)
            settle(0.25)
        }
        func confirmRecording() {
            let key = CGEvent(keyboardEventSource: nil, virtualKey: 40, keyDown: true)!
            key.flags = .maskCommand; key.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            _ = runtime.shortcuts.intercept(type: .keyDown, event: key)
            let confirm = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(views).compactMap { $0 as? NSButton }.first { $0.title == "Use Shortcut" }!
            assert(confirm.isEnabled); confirm.performClick(nil); settle()
        }
        startRecording("Record Shortcut…")
        page.shortcutsTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        confirmRecording()
        let expected = ShortcutCombination(input: .key, code: 40, modifiers: ShortcutCombination.command)
        assert(preferences.shortcuts[0].id == a.id && preferences.shortcuts[0].combination == expected,
               "Recording must update its original shortcut even after selection changes")
        assert(preferences.shortcuts[1] == b, "Recording must preserve the newly selected shortcut")
        page.shortcutsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        startRecording(preferences.shortcuts[0].combination!.display)
        preferences.shortcuts = [b]
        confirmRecording()
        assert(preferences.shortcuts == [b], "Deleting the original shortcut must discard its recording result")

        context.navigate?(SearchDestination(page: .general, controlID: "")); settle()
        let search = views(window.contentView!).compactMap { $0 as? NSSearchField }.first!
        func query(_ text: String) {
            search.stringValue = text
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        func command(_ name: String) {
            assert(search.delegate?.control?(search, textView: NSTextView(), doCommandBy: NSSelectorFromString(name)) == true)
        }
        func currentPage() -> SettingsPage? { window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? SettingsPageController }.first?.page }
        query("move threshold"); settle(0.15)
        query("menu bar icon")
        _ = search.sendAction(search.action!, to: search.target)
        assert(currentPage() == .general && search.stringValue.isEmpty, "Immediate Return must activate the edited query, not stale results")
        settle(0.15)
        assert(currentPage() == .general, "A cancelled debounce must not replace the activated page")
        query("move threshold"); command("insertNewlineIgnoringFieldEditor:")
        assert(currentPage() == .window, "A first query must support Return before its debounce fires")
        query("permission"); command("moveDown:"); command("moveDown:")
        let results = views(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Settings search results" }!
        assert(results.selectedRow == 1, "Repeated arrow commands must retain search selection after flushing the query")
        query("   "); command("insertNewline:")
        assert(currentPage() == .window, "Whitespace queries must not reactivate old results")
        context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown(); window.orderOut(nil)
        print("Settings regressions passed: recorder identity/deletion and immediate search submission/navigation.")
    }
}
