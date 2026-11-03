import AppKit
import QuartzCore

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
        visualEffects(context: context, settings: settings)
        context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown(); window.orderOut(nil)
        print("Settings regressions passed: recorder identity/deletion and immediate search submission/navigation.")
    }

    private static func visualEffects(context: SettingsContext, settings: SettingsWindowController) {
        let preferences = context.preferences, window = settings.window!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        context.navigate?(SearchDestination(page: .window, controlID: ""))
        let gesturePage = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? WindowPageController }.first!
        assert(gesturePage.controls["window.resize.effect"] == nil && gesturePage.controls["window.feedback.animatedEffects"] == nil)
        context.navigate?(SearchDestination(page: .visualEffects, controlID: ""))
        window.layoutIfNeeded()
        let page = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? VisualEffectsPageController }.first!
        assert(["window.resize.effect", "window.move.effect", "window.feedback.animatedEffects", "window.feedback.cornerHints", "window.feedback.frame"].allSatisfy { page.controls[$0] != nil })
        assert(context.catalog.search("Furious Lightning").contains { $0.destination.page == .visualEffects })
        let picker = page.controls["visualEffects.static.effect"] as! ActionPopup
        let area = views(page.view).first { $0.identifier?.rawValue == "visualEffects.static.configuration" }!
        func select(_ effect: StaticEffect) {
            picker.selectItem(withTitle: effect.title); _ = picker.sendAction(picker.action!, to: picker.target)
            page.refreshValues(); window.layoutIfNeeded()
        }
        assert(picker.itemTitles == StaticEffect.allCases.map(\.title) && picker.titleOfSelectedItem == "No Effect")
        assert(area.frame.height == 320 && views(area).contains { $0.identifier?.rawValue == "visualEffects.static.empty" })
        assert(!picker.itemTitles.contains("Snowfall"), "The retired Snowfall effect is absent from the menu")
        select(.fireflies)
        let amount = page.controls["visualEffects.static.option.fireflyamount"] as! NSSlider
        amount.integerValue = 73; _ = amount.sendAction(amount.action!, to: amount.target)
        assert(preferences.int(.fireflyAmount) == 73)
        select(.rain)
        assert(area.frame.height == 320 && views(area).compactMap { $0 as? NSSlider }.count == 4)
        assert(!context.catalog.entries.contains { $0.id == "visualEffects.static.option.fireflyamount" })
        select(.fireflies)
        assert((page.controls["visualEffects.static.option.fireflyamount"] as! NSSlider).integerValue == 73)
        assert(preferences.int(.rainAmount) == 50, "Each effect keeps independent options")
        select(.snowStorm)
        assert(area.frame.height == 320 && views(area).compactMap { $0 as? NSSlider }.count == 5)
        for slider in views(area).compactMap({ $0 as? NSSlider }) {
            assert(area.bounds.contains(slider.convert(slider.bounds, to: area)), "Storm controls fit inside the fixed configuration area")
        }
        let gusts = page.controls["visualEffects.static.option.windgusts"] as! NSSlider
        gusts.integerValue = 81; _ = gusts.sendAction(gusts.action!, to: gusts.target)
        assert(preferences.int(.stormGusts) == 81 && context.catalog.search("Snow Storm").contains { $0.id == "visualEffects.static.effect" })
        select(.fireflies)

        var reduced = false, presentations = 0
        var targets: [UInt32?] = []
        var screens = [StaticEffectScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                       StaticEffectScreen(id: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080))]
        let top = SnowStormWindow(id: 301, owner: 1, frame: CGRect(x: 100, y: 100, width: 600, height: 500), level: 0)
        let other = SnowStormWindow(id: 302, owner: 2, frame: CGRect(x: -1000, y: 0, width: 600, height: 500), level: 0)
        let controller = StaticEffectsController(preferences: preferences, reducedMotion: { reduced }, screens: { screens },
            present: { _, window in presentations += 1; targets.append(window?.id) }, query: { _, _ in [top, other] }, automaticPlacement: false)
        assert(controller.panelsForTesting.isEmpty, "Suspend All prevents particle surfaces")
        preferences.set(false, for: .suspended)
        assert(controller.panelsForTesting.count == screens.count && presentations > 0)
        assert(Set(targets.compactMap { $0 }) == Set([top.id, other.id]), "Rain and Fireflies target each display's foremost window")
        assert(screens.allSatisfy { screen in controller.panelsForTesting.contains { $0.frame == screen.frame } })
        let panel = controller.panelsForTesting[0]
        assert(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain && panel.level == .floating)
        let emitter = panel.contentView!.layer!.sublayers!.first as! CAEmitterLayer
        assert(emitter.emitterCells?.first?.contents != nil && emitter.emitterCells!.first!.velocity > 0)
        window.close()
        assert(controller.panelsForTesting.count == screens.count, "Closing Settings leaves Static running")
        settings.showWindow(nil)
        reduced = true; controller.reconcile()
        assert(controller.panelsForTesting.isEmpty && preferences.staticEffect == .fireflies)
        reduced = false; controller.reconcile()
        assert(!controller.panelsForTesting.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        assert(controller.panelsForTesting.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        assert(!controller.panelsForTesting.isEmpty)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        assert(controller.panelsForTesting.isEmpty, "A waking display cannot override an inactive session")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        assert(!controller.panelsForTesting.isEmpty)
        screens.removeFirst()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        assert(controller.panelsForTesting.count == screens.count && controller.panelsForTesting[0].frame == screens[0].frame)
        for effect in [StaticEffect.fireflies] {
            for value in [1, 100] {
                preferences.batch {
                    preferences.set(effect.rawValue, for: .staticEffect)
                    for (_, key) in effect.options { preferences.set(value, for: key) }
                }
                let configuration = StaticEffectConfiguration(preferences: preferences)
                let model = StaticEffectsController.makeEmitter(configuration: configuration, bounds: CGRect(x: 0, y: 0, width: 8000, height: 4000))
                let cell = model.emitterCells!.first!
                assert(cell.lifetime.isFinite && cell.lifetime > 0 && cell.birthRate > 0)
                assert(cell.birthRate * cell.lifetime <= 961, "Static simulation stays bounded on large displays")
            }
        }
        select(.rain)
        let rain = controller.rainForTesting!
        assert(controller.panelsForTesting.contains { $0.frame == screens[0].frame }, "Selecting Rain presents a screen surface")
        assert(!rain.simulation.drops.isEmpty && rain.simulation.drops.count <= RainEffectSimulation.maximumDropsPerScreen,
               "Rain seeds visible drops immediately within its particle budget")
        assert(!rain.timerRunningForTesting, "The controlled Rain fixture does not start a live timer")
        select(.none)
        assert(area.frame.height == 320 && views(area).contains { $0.identifier?.rawValue == "visualEffects.static.empty" } &&
               controller.panelsForTesting.isEmpty)
        assert(!context.catalog.entries.contains { $0.id.hasPrefix("visualEffects.static.option.") })
        controller.shutdown()
        select(.rain)
        assert(controller.panelsForTesting.isEmpty, "Shutdown cannot restart particles from a late preference notification")
        preferences.set(true, for: .suspended); select(.none)
        print("Visual Effects regressions passed: relocated controls/search, fixed configuration size, per-effect persistence, click-through surfaces, bounded particles, pause/resume, and shutdown.")
    }
}
