import AppKit
import QuartzCore
import IOKit.hidsystem

enum SettingsRegressionTests {
    static func run(logger: FileLogger) {
        inputMonitoringStatusReflectsExplicitGrant(logger: logger)
        permissionControls(logger: logger)
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
        assert(area.frame.height == 320 && views(area).compactMap { $0 as? NSSlider }.count == 6)
        let snowOptions = page.controls["visualEffects.static.option.behindWindows"] as! SnowStormOptionsControl
        for width in [960.0, 780.0] {
            window.setContentSize(NSSize(width: width, height: 700)); window.layoutIfNeeded()
            for control in views(area).filter({ $0 is NSButton || $0 is NSSlider || $0 is NSSegmentedControl }) {
                assert(area.bounds.contains(control.convert(control.bounds, to: area)), "Snow Storm controls fit at the default and minimum Settings widths")
            }
            assert(snowOptions.frame.width >= snowOptions.intrinsicContentSize.width,
                   "All four full segment labels fit without compression")
            let segments = snowOptions.accessibilitySegments
            assert(segments.count == 4, "The native control exposes four independent accessibility segments")
            for (index, segment) in segments.enumerated() {
                let labelWidth = (snowOptions.label(forSegment: index)! as NSString).size(withAttributes: [.font: snowOptions.font!]).width
                assert(segment.accessibilityFrame().width >= labelWidth + 12,
                       "Each native segment has room for its complete label and padding")
            }
        }
        window.setContentSize(NSSize(width: 960, height: 700)); window.layoutIfNeeded()
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
    private static func permissionControls(logger: FileLogger) {
        let preferences = PreferenceStore(defaults: MemoryDefaults()); preferences.set(true, for: .suspended)
        var trusted = false, posting = false, listening = false, recording = false
        var requests = [0, 0, 0], expectedRequests = [0, 0, 0], postingRequests = 0
        var openedSettings: [URL] = []
        let permissions = PermissionCoordinator(
            checkAccessibility: { trusted }, checkEventPosting: { posting }, requestEventPosting: { postingRequests += 1; return false },
            checkListening: { listening }, requestListening: { requests[1] += 1; return false }, checkScreenRecording: { recording },
            requestAccessibility: { requests[0] += 1; return false }, requestScreenRecording: { requests[2] += 1; return false },
            settingsOpener: { openedSettings.append($0); return true })
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: preferences))
        let settings = SettingsWindowController(context: context), window = settings.window!
        defer { settings.close(); permissions.stopMonitoringForTermination(); context.iconAbsorber.shutdown(); runtime.shortcuts.shutdown() }
        settings.present()
        context.navigate?(SearchDestination(page: .permissions, controlID: ""))
        let page = window.contentViewController!.children.flatMap(\.children).compactMap { $0 as? PermissionsPageController }.first!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        for (index, permission) in PermissionEntry.allCases.enumerated() {
            let card = page.controls[permission.controlID]!
            assert(views(card).compactMap { $0 as? NSTextField }.contains { $0.stringValue == permission.title })
            let buttons = ["open", "request", "check"].map { page.controls["\(permission.controlID).\($0)"] as! ActionButton }
            assert(buttons.map(\.title) == ["Open \(permission.title)", "Request \(permission.title)", "Check for approval"])
            assert(buttons.allSatisfy { $0.isEnabled && $0.acceptsFirstResponder && $0.accessibilityLabel() == $0.title })
            let status = views(card).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "\(permission.controlID).status" }!
            assert(status.textColor == (permission == .inputMonitoring && trusted ? .systemGreen : .systemOrange))
            expectedRequests[index] += 1
            buttons[1].performClick(nil)
            assert(requests == expectedRequests, "Each Request calls only its matching API")
            if permission == .inputMonitoring {
                assert(status.stringValue.hasPrefix("Covered by Device Control and Data Access"))
                assert(openedSettings.count == 1 && openedSettings[0].absoluteString.hasSuffix("Privacy_ListenEvent"))
                let feedback = views(card).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "permissions.inputMonitoring.requestFeedback" }!
                assert(!feedback.isHidden && feedback.stringValue.contains("Request sent to macOS") && feedback.stringValue.contains(Bundle.main.bundleURL.path))
            } else { assert(status.textColor == .systemOrange, "A request is not an approval") }
            for granted in [true, false, true] {
                switch permission {
                case .accessibility: trusted = granted; posting = granted
                case .inputMonitoring: listening = granted
                case .screenRecording: recording = granted
                }
                buttons[2].performClick(nil)
                assert(status.textColor == (granted || permission == .inputMonitoring && trusted ? .systemGreen : .systemOrange), "Check immediately reflects available access")
                assert(requests == expectedRequests && postingRequests == 0, "Checking never requests access")
            }
            if permission == .inputMonitoring { expectedRequests[index] += 1 }
            buttons[1].performClick(nil)
            assert(requests == expectedRequests, "Input Monitoring always requests even when listening is already available")
            assert(context.catalog.entries.contains { $0.id == "\(permission.controlID).request" })
            assert(context.catalog.entries.contains { $0.id == "\(permission.controlID).check" })
        }
        posting = false
        (page.controls["permissions.accessibility.check"] as! ActionButton).performClick(nil)
        let axStatus = views(page.view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "permissions.accessibility.status" }!
        assert(axStatus.textColor == .systemOrange && axStatus.stringValue.contains("input control is unavailable"))
        (page.controls["permissions.accessibility.request"] as! ActionButton).performClick(nil)
        assert(postingRequests == 1 && axStatus.textColor == .systemOrange)
        posting = true
        (page.controls["permissions.accessibility.check"] as! ActionButton).performClick(nil)
        assert(axStatus.textColor == .systemGreen && requests == expectedRequests)
        var cardWidths: [CGFloat] = []
        for width in [960.0, 780.0] {
            window.setContentSize(NSSize(width: width, height: 700))
            let deadline = Date().addingTimeInterval(0.1)
            while Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            NSApp.updateWindows()
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            page.view.layoutSubtreeIfNeeded()
            cardWidths.append(page.controls[PermissionEntry.accessibility.controlID]!.bounds.width)
            for permission in PermissionEntry.allCases {
                let card = page.controls[permission.controlID]!
                let buttons = ["open", "request", "check"].map { page.controls["\(permission.controlID).\($0)"] as! ActionButton }
                let rects = buttons.map { $0.convert($0.bounds, to: card) }
                assert(rects.allSatisfy(card.bounds.contains), "Every permission button fits at default and minimum widths")
                assert(rects[0].maxX < rects[1].minX && rects[1].maxX < rects[2].minX && rects.allSatisfy { abs($0.midY - rects[0].midY) < 1 })
                for button in buttons {
                    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
                    let text = (button.title as NSString).boundingRect(with: NSSize(width: button.bounds.width - 20, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: button.font!, .paragraphStyle: paragraph])
                    assert(text.height <= button.bounds.height - 16, "Full button labels fit without truncation")
                    assert(button.cell?.wraps == true && button.cell?.lineBreakMode == .byWordWrapping)
                }
            }
        }
        assert(cardWidths[0] > cardWidths[1] + 150, "Both default and minimum pane widths were laid out: \(cardWidths)")
        assert(context.catalog.search("accessibility").contains { $0.id == "permissions.accessibility" })
        assert(context.catalog.search("screen recording").contains { $0.id == "permissions.screenRecording" })
        print("Permission controls passed: exact labels, isolated requests, immediate read-only checks, grant/revocation colors, and wrapped layout at both window widths.")
    }
    static func inputMonitoringStatusReflectsExplicitGrant(logger: FileLogger) {
        let preferences = PreferenceStore(defaults: MemoryDefaults())
        preferences.set(true, for: .suspended)
        var access = kIOHIDAccessTypeUnknown, requests = 0, openedSettings = 0
        var trusted = true, canOpenSettings = true
        let native = InputMonitoringAccess(checkAccess: { type in
            assert(type == kIOHIDRequestTypeListenEvent)
            return access
        }, requestAccess: { type in
            assert(type == kIOHIDRequestTypeListenEvent)
            requests += 1
            return true
        })
        let permissions = PermissionCoordinator(
            checkAccessibility: { trusted }, checkEventPosting: { true }, requestEventPosting: { false },
            checkScreenRecording: { true }, requestAccessibility: { false }, requestScreenRecording: { false },
            inputMonitoringAccess: native, settingsOpener: { _ in openedSettings += 1; return canOpenSettings })
        let runtime = RuntimeCoordinator(preferences: preferences, permissions: permissions, logger: logger)
        let context = SettingsContext(preferences: preferences, permissions: permissions, runtime: runtime, logger: logger, login: LoginService(preferences: preferences))
        let settings = SettingsWindowController(context: context)
        defer { settings.close(); permissions.stopMonitoringForTermination() }
        context.navigate?(SearchDestination(page: .permissions, controlID: PermissionEntry.inputMonitoring.controlID))
        let page = settings.window!.contentViewController!.children.flatMap(\.children).compactMap { $0 as? PermissionsPageController }.first!
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let card = page.controls[PermissionEntry.inputMonitoring.controlID]!
        let fields = views(card).compactMap { $0 as? NSTextField }
        let status = fields.first { $0.identifier?.rawValue == "permissions.inputMonitoring.status" }!
        assert(fields.contains { $0.stringValue.hasPrefix("Example System Settings") }, "The enabled example switch is visibly identified as an illustration")
        func assertUngranted() {
            assert(status.stringValue == "Enable Jimmy Tweaks in Input Monitoring in System Settings." && status.textColor == .systemOrange,
                   "Accessibility alone must not produce a green Input Monitoring grant")
        }
        assert(status.stringValue.hasPrefix("Covered by Device Control and Data Access") && status.textColor == .systemGreen)
        trusted = false
        permissions.refresh(); page.refreshValues()
        assertUngranted()
        (page.controls["permissions.inputMonitoring.request"] as! ActionButton).performClick(nil)
        assert(requests == 1, "Accessibility must not suppress the Input Monitoring request")
        assertUngranted()
        for state in [kIOHIDAccessTypeDenied, kIOHIDAccessTypeGranted, kIOHIDAccessTypeDenied] {
            access = state
            permissions.refresh()
            // Let the real notification-driven Settings refresh run; do not call
            // the page's refreshers directly.
            let end = Date().addingTimeInterval(0.1)
            while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
            if state == kIOHIDAccessTypeGranted {
                assert(status.stringValue == "Input observation available." && status.textColor == .systemGreen)
            } else { assertUngranted() }
        }
        (page.controls["permissions.inputMonitoring.check"] as! ActionButton).performClick(nil)
        assert(requests == 1, "Status updates must not repeat the native request")
        trusted = true; access = kIOHIDAccessTypeGranted; canOpenSettings = false
        permissions.refresh(); page.refreshValues()
        (page.controls["permissions.inputMonitoring.request"] as! ActionButton).performClick(nil)
        assert(requests == 2 && openedSettings == 2, "Broader/effective access must not skip the native request or settings navigation")
        assert(status.stringValue.hasPrefix("Covered by Device Control and Data Access") && !status.stringValue.contains("Permission granted"))
        let feedback = views(card).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "permissions.inputMonitoring.requestFeedback" }!
        assert(!feedback.isHidden && feedback.stringValue.contains("manually"), "A failed settings deep link gives a visible manual route")
        print("Input Monitoring UI regression passed: explicit requests despite broader/effective access, visible feedback/settings navigation, no false approval, and grant/revocation.")
    }
}
