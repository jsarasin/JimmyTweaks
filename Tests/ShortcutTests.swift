import AppKit

/// No global event posting or screenshot interaction: controlled physical-event values and
/// action definitions exercise the same production matcher, router, and cancellation runner.
enum ShortcutTests {
    static func run(logger: FileLogger) {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) { checks += 1; assert(value(), message) }
        func settle() { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { settle() }
            check(condition(), "Controlled shortcut operation timed out")
        }
        let keyboard = ShortcutCombination(input: .key, code: 40, modifiers: 1 << 20, keyLabel: "k")
        var shortcut = ShortcutDefinition(); shortcut.combination = keyboard
        shortcut.actions = [ShortcutActionInstance(actionID: "builtin.delay", parameters: ["seconds":"0.001"])]
        check(ShortcutDefinition().mode == .absorbing, "New shortcuts absorb by default")
        check(ShortcutDefinition().activation == .press && !ShortcutDefinition().configured, "Empty shortcuts are allowed and inactive")
        check(keyboard.display == "⌘ K", "Native modifier notation")
        check(keyboard == ShortcutCombination(input: .key, code: 40, modifiers: 1 << 20, keyLabel: "different layout"), "Hardware identity ignores displayed characters")
        check(ShortcutCombination(input: .key, code: 53, modifiers: 1 << 20).validationError != nil, "Modified Escape is forbidden")
        check(ShortcutCombination(input: .key, code: 53, modifiers: 0).validationError != nil, "Escape is forbidden")
        check(ShortcutCombination(input: .key, code: 0, modifiers: 0).validationError != nil, "Unmodified typing is forbidden")
        check(ShortcutCombination(input: .key, code: 56, modifiers: 1 << 17).validationError != nil, "Modifiers alone are forbidden")
        check(ShortcutCombination(input: .key, code: 122, modifiers: 0).validationError == nil, "Function keys may be unmodified")
        for code in UInt16(0)...8 {
            let mouse = ShortcutCombination(input: .mouse, code: code, modifiers: 0)
            check(mouse.validationError == nil && mouse.needsTransparent == (code < 2), "Only unmodified primary buttons need Transparent")
        }
        var duplicate = shortcut; duplicate.id = UUID(); duplicate.mode = .transparent; duplicate.activation = .release; duplicate.name = "Existing"
        check(ShortcutConflictChecker.error(for: shortcut, among: [duplicate], gestures: GesturePreferences())?.contains("Existing") == true, "Duplicates cross mode/activation boundaries")
        var mouseShortcut = shortcut; mouseShortcut.combination = ShortcutCombination(input: .mouse, code: 0, modifiers: 0)
        check(ShortcutConflictChecker.error(for: mouseShortcut, among: [], gestures: GesturePreferences()) != nil, "Absorbing ordinary left click rejected")
        mouseShortcut.mode = .transparent
        check(ShortcutConflictChecker.error(for: mouseShortcut, among: [], gestures: GesturePreferences()) == nil, "Transparent ordinary left click accepted")
        for code in UInt16(0)...1 {
            mouseShortcut.combination = ShortcutCombination(input: .mouse, code: code, modifiers: 1 << 20)
            check(ShortcutConflictChecker.error(for: mouseShortcut, among: [], gestures: GesturePreferences())?.contains("Window Resizer") == true, "Internal gesture conflicts rejected")
        }
        for mode in [ShortcutMode.transparent, .absorbing] {
            for activation in [ShortcutActivation.press, .release] {
                for mouse in [false, true] {
                    var row = shortcut; row.mode = mode; row.activation = activation
                    row.combination = mouse ? ShortcutCombination(input: .mouse, code: 3, modifiers: 1 << 19) : keyboard
                    let combination = row.combination!
                    var matcher = ShortcutMatcher()
                    let down = matcher.handle(combination, down: true, shortcuts: [row])
                    check(down.suppress == (mode == .absorbing), "Only active mode absorbs down")
                    check((down.activation != nil) == (activation == .press), "Press activation")
                    check(matcher.handle(combination, down: true, repeating: true, shortcuts: [row]).activation == nil, "Auto-repeat cannot reactivate")
                    var released = combination; released.modifiers = 0
                    let up = matcher.handle(released, down: false, shortcuts: [row])
                    check(up.suppress == (mode == .absorbing), "Balanced release suppression")
                    check((up.activation != nil) == (activation == .release), "Release uses initiating modifiers")
                    check(matcher.handle(released, down: false, shortcuts: [row]).activation == nil, "No orphan release activation")
                    check(matcher.handle(combination, down: true, excluded: true, shortcuts: [row]).activation == nil, "Own-window press is excluded")
                    let excludedRelease = matcher.handle(combination, down: false, shortcuts: [row])
                    check(!excludedRelease.suppress && excludedRelease.activation == nil, "Own press remains excluded on foreign release")
                    _ = matcher.handle(combination, down: true, shortcuts: [row])
                    let ownUp = matcher.handle(combination, down: false, excluded: true, shortcuts: [row])
                    check(ownUp.activation == nil, "Release over own window never activates")
                    _ = matcher.handle(combination, down: true, shortcuts: [row]); matcher.cancelActivations()
                    let disabledUp = matcher.handle(combination, down: false, shortcuts: [])
                    check(disabledUp.suppress == (mode == .absorbing) && disabledUp.activation == nil, "Disable drains held input without activation")
                }
            }
        }
        var dragMatcher = ShortcutMatcher(); var drag = shortcut
        drag.combination = ShortcutCombination(input: .mouse, code: 4, modifiers: 0)
        _ = dragMatcher.handle(drag.combination!, down: true, shortcuts: [drag])
        check(dragMatcher.absorbsDrag(button: 4) && !dragMatcher.absorbsDrag(button: 3), "Consume only corresponding drags")
        _ = dragMatcher.handle(drag.combination!, down: false, shortcuts: [drag])
        check(!dragMatcher.absorbsDrag(button: 4), "Drag ownership ends on release")

        // Recorder confirmation, rerecording restrictions, and continuous Escape holds.
        var recorded: ShortcutCombination?, cancelled = 0, now = 0.0, held = true
        let recorder = ShortcutRecorderController(now: { now }, escapeHeld: { held }, validate: { _ in nil }) { value in
            if let value = value { recorded = value } else { cancelled += 1 }
        }
        recorder.armForTesting()
        let ordinary = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)!
        recorder.receive(type:.keyDown,event:ordinary)
        check(recorder.candidateForTesting == nil, "Recorder rejects ordinary typing")
        let key = CGEvent(keyboardEventSource:nil,virtualKey:40,keyDown:true)!; key.flags = .maskCommand
        recorder.receive(type:.keyDown,event:key)
        check(recorder.candidateForTesting == keyboard && recorded == nil, "Recorder waits for explicit confirmation")
        recorder.confirmForTesting(); check(recorded == keyboard, "Recorder saves hardware identity on confirmation")
        let escapeRecorder = ShortcutRecorderController(now: { now }, escapeHeld: { held }, validate: { _ in nil }) { _ in cancelled += 1 }
        escapeRecorder.armForTesting()
        let escDown = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:true)!, escUp = CGEvent(keyboardEventSource:nil,virtualKey:53,keyDown:false)!
        escDown.flags = .maskCommand
        escapeRecorder.receive(type:.keyDown,event:escDown)
        check(escapeRecorder.candidateForTesting == nil, "Recorder never assigns modified Escape")
        now = 1.9; escapeRecorder.tickForTesting(); check(cancelled == 0, "Short Escape hold does not cancel")
        escapeRecorder.receive(type:.keyUp,event:escUp)
        now = 5; escapeRecorder.tickForTesting(); check(cancelled == 0, "Release resets Escape hold")
        escapeRecorder.receive(type:.keyDown,event:escDown); now = 6.9; escapeRecorder.tickForTesting()
        check(cancelled == 0, "Second hold starts a new timer")
        now = 7.01; escapeRecorder.tickForTesting(); check(cancelled == 1, "Two-second continuous hold cancels")
        held = false
        for code in UInt16(0)...5 {
            let mouseRecorder = ShortcutRecorderController(validate: { _ in nil }) { _ in }
            mouseRecorder.armForTesting()
            let mouseEvent = CGEvent(mouseEventSource:nil,mouseType:.otherMouseDown,mouseCursorPosition:.zero,mouseButton:CGMouseButton(rawValue:UInt32(code))!)!
            mouseEvent.flags = .maskAlternate
            mouseRecorder.receive(type:.otherMouseDown,event:mouseEvent)
            check(mouseRecorder.candidateForTesting == ShortcutCombination(input:.mouse,code:code,modifiers:1 << 19), "Recorder accepts every mouse button with modifiers")
            mouseRecorder.cancel()
        }

        let defaults = MemoryDefaults(), preferences = PreferenceStore(defaults: MemoryDefaults())
        let store = PreferenceStore(defaults: defaults)
        store.shortcuts = [shortcut, duplicate]; store.set(true, for: .shortcutsEnabled)
        let restored = PreferenceStore(defaults: defaults)
        check(restored.shortcuts == [shortcut, duplicate] && restored.bool(.shortcutsEnabled), "Ordered actions, identities, and toggles persist")
        store.resetAll(); check(store.shortcuts.isEmpty && !store.bool(.shortcutsEnabled), "Global reset removes shortcut data")

        let registry = ShortcutActionRegistry(), runner = ShortcutActionRunner(registry: ShortcutActionRegistry(), logger: logger)
        var events: [String] = []
        func register(_ id: String, execute: @escaping @MainActor (ShortcutActionInstance, ShortcutExecutionContext) async throws -> Void) {
            runner.registry.register(ShortcutActionDefinition(id: id, name: id, category: "Test", description: "", execute: execute))
        }
        register("first") { _, _ in events.append("first-start"); try await Task.sleep(nanoseconds: 30_000_000); events.append("first-end") }
        register("second") { _, _ in events.append("second") }
        register("concurrent") { _, _ in events.append("other-start"); try await Task.sleep(nanoseconds: 60_000_000); events.append("other-end") }
        var a = shortcut; a.actions = [ShortcutActionInstance(actionID:"first"),ShortcutActionInstance(actionID:"second"),ShortcutActionInstance(actionID:"second")]
        var b = a; b.id = UUID(); b.actions = [ShortcutActionInstance(actionID:"concurrent")]
        check(runner.start(a) && runner.start(b), "Different shortcuts start concurrently")
        check(!runner.start(a), "Same shortcut cannot overlap")
        wait { !runner.isRunning }
        check(events.filter { $0 != "other-start" && $0 != "other-end" } == ["first-start","first-end","second","second"], "Actions remain sequential and repeatable")
        check(events.firstIndex(of:"other-start")! < events.firstIndex(of:"first-end")!, "Sequences truly overlap")
        events.removeAll(); var notifications = 0
        runner.onEscape = { notifications += 1 }
        a.actions = [ShortcutActionInstance(actionID:"builtin.delay", parameters:["seconds":"60"]),ShortcutActionInstance(actionID:"second")]
        b.actions = a.actions
        _ = runner.start(a); _ = runner.start(b); for _ in 0..<3 { settle() }
        runner.cancelAll(escape: true); runner.cancelAll(escape: true)
        wait { !runner.isRunning }
        check(events.isEmpty && notifications == 1, "Escape cancels every delay, prevents next actions, and notifies once")
        _ = runner.start(a); runner.cancelAll(); wait { !runner.isRunning }
        check(notifications == 1, "Suspend cancellation has no Escape notification")
        var cancellationObserved = false
        register("cooperative") { _, _ in
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancellationObserved = true; throw error }
        }
        a.actions = [ShortcutActionInstance(actionID:"cooperative"),ShortcutActionInstance(actionID:"second")]
        _ = runner.start(a); for _ in 0..<3 { settle() }; runner.cancelAll(escape:true); wait { !runner.isRunning }
        check(cancellationObserved && events.isEmpty, "Current action receives cancellation and queued actions never start")
        register("failure") { _, _ in throw ShortcutActionError(message:"Controlled failure") }
        var failures = 0; runner.onFailure = { _, _ in failures += 1 }
        a.actions = [ShortcutActionInstance(actionID:"failure"),ShortcutActionInstance(actionID:"second")]
        _ = runner.start(a); wait { !runner.isRunning }
        check(failures == 1 && events.isEmpty, "Failure stops the sequence")
        let child = OwnedShortcutProcess(executable:"/bin/sleep",arguments:["60"])
        register("owned-process") { _, _ in _ = try await child.run() }
        a.actions = [ShortcutActionInstance(actionID:"owned-process"),ShortcutActionInstance(actionID:"second")]
        _ = runner.start(a); wait { child.isRunning }
        runner.cancelAll(escape:true); wait { !runner.isRunning }
        check(!child.isRunning && events.isEmpty, "Cancellation terminates the owned process and stops subsequent actions")
        let invalidChild = OwnedShortcutProcess(executable:"/nonexistent/jimmy-shortcuts-test",arguments:[])
        register("missing-process") { _, _ in _ = try await invalidChild.run() }
        a.actions = [ShortcutActionInstance(actionID:"missing-process"),ShortcutActionInstance(actionID:"second")]
        _ = runner.start(a); wait { !runner.isRunning }
        check(failures == 2 && events.isEmpty, "Process launch failures propagate without continuing")
        check(registry.categories.contains("Scripts"), "Dynamic Scripts category always exists")
        for value in ["0.001","0.25","1.5","30","60"] { check(registry.definition("builtin.delay")?.validate(["seconds":value]) == nil, "Valid decimal Delay") }
        for value in ["0","60.001","nan","inf","bad"] { check(registry.definition("builtin.delay")?.validate(["seconds":value]) != nil, "Invalid Delay rejected") }
        check(registry.unavailableReason([ShortcutActionInstance(actionID:"script:deleted")])?.contains("Unavailable") == true, "Deleted scripts remain explicitly unavailable")

        // Permission reset tests inject the executor: no real TCC decisions are changed.
        let resetCalls = Locked<[(String, [String])]>([])
        var resetCompleted = false, resetSucceeded = false
        Task { @MainActor in
            do {
                try await PermissionResetter.reset(bundleIdentifier: "local.jimmytweaks.app") { executable, arguments in
                    resetCalls.withValue { $0.append((executable.path, arguments)) }
                    return PermissionResetter.Output(status: 0, errorText: "")
                }
                resetSucceeded = true
            } catch { resetSucceeded = false }
            resetCompleted = true
        }
        wait { resetCompleted }
        check(resetSucceeded && resetCalls.snapshot.count == 1 && resetCalls.snapshot[0].0 == "/usr/bin/tccutil" && resetCalls.snapshot[0].1 == ["reset", "All", "local.jimmytweaks.app"], "Permission reset uses exactly one app-scoped system command")
        for invalid: String? in [nil, "", "*", "All", "local..app", "local.app;echo", "local.app\n", "../other.app"] {
            do { _ = try PermissionResetter.arguments(bundleIdentifier: invalid); check(false, "Unsafe reset identity accepted") }
            catch { check(true, "Unsafe or absent reset identity is rejected") }
        }
        resetCompleted = false; var resetFailed = false
        Task { @MainActor in
            do {
                try await PermissionResetter.reset(bundleIdentifier: "local.jimmytweaks.app") { _, _ in PermissionResetter.Output(status: 1, errorText: "Controlled denial") }
            } catch { resetFailed = error.localizedDescription.contains("Controlled denial") }
            resetCompleted = true
        }
        wait { resetCompleted }; check(resetFailed, "A rejected permission reset reports failure without claiming success")

        // Route Escape without posting a real key; synthetic-event recursion is separately rejected.
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false }, checkListening: { false }, requestListening: { false })
        var listeningRequests = 0
        var screenGranted = false
        let deniedListening = PermissionCoordinator(checkAccessibility:{false}, checkEventPosting:{false}, requestEventPosting:{false}, checkListening:{false}, requestListening:{ listeningRequests += 1; return false }, checkScreenRecording:{screenGranted})
        deniedListening.refresh(); check(listeningRequests == 0, "Permission polling never prompts for listening")
        deniedListening.requestShortcutObservation(); deniedListening.requestShortcutObservation()
        check(listeningRequests == 1 && !deniedListening.inputMonitoring, "Denied listening is requested only once explicitly")
        check(!deniedListening.screenRecording, "Screen Recording starts with its observed grant state")
        screenGranted = true; deniedListening.refresh()
        check(deniedListening.screenRecording && listeningRequests == 1, "Permission refresh observes Screen Recording grants without requesting other access")
        let controller = ShortcutController(preferences: preferences, permissions: permissions, logger: logger)
        var popupCount = 0; controller.runner.onEscape = { popupCount += 1 }
        a.actions = [ShortcutActionInstance(actionID:"builtin.delay", parameters:["seconds":"60"])]
        _ = controller.runner.start(a); for _ in 0..<3 { settle() }
        let escape = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)!
        escape.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        check(!controller.intercept(type:.keyDown,event:escape), "Global Escape passes through normally")
        wait { !controller.runner.isRunning }; check(popupCount == 1, "Router cancels Escape independent of foreground app")
        check(!controller.intercept(type:.keyDown,event:escape) && popupCount == 1, "Idle Escape has no side effects")
        _ = controller.runner.start(a); preferences.set(true, for:.suspended); controller.reconcile(sessionActive:true)
        wait { !controller.runner.isRunning }; check(popupCount == 1, "Master suspend cancels without notification")
        _ = controller.runner.start(a); preferences.set(false, for:.shortcutsEnabled); controller.reconcile(sessionActive:true)
        wait { !controller.runner.isRunning }; check(popupCount == 1, "Module disable cancels without notification")
        // Exercise both production routing paths without installing or posting global events.
        var routed = 0
        controller.registry.register(ShortcutActionDefinition(id:"route-test",name:"Route Test",category:"Test",description:"") { _, _ in routed += 1 })
        var routeShortcut = ShortcutDefinition(); routeShortcut.combination = ShortcutCombination(input:.mouse,code:4,modifiers:0)
        routeShortcut.actions = [ShortcutActionInstance(actionID:"route-test")]
        preferences.set(false,for:.suspended); preferences.set(true,for:.shortcutsEnabled); preferences.shortcuts = [routeShortcut]
        controller.reconcile(sessionActive:true)
        let mouseDown = CGEvent(mouseEventSource:nil,mouseType:.otherMouseDown,mouseCursorPosition:CGPoint(x:-10000,y:-10000),mouseButton:CGMouseButton(rawValue:4)!)!
        let mouseUp = CGEvent(mouseEventSource:nil,mouseType:.otherMouseUp,mouseCursorPosition:CGPoint(x:-10000,y:-10000),mouseButton:CGMouseButton(rawValue:4)!)!
        mouseDown.setIntegerValueField(.eventSourceUnixProcessID,value:Int64(getpid()))
        check(!controller.intercept(type:.otherMouseDown,event:mouseDown), "Ignore self-generated input")
        mouseDown.setIntegerValueField(.eventSourceUnixProcessID,value:0); mouseUp.setIntegerValueField(.eventSourceUnixProcessID,value:0)
        check(controller.intercept(type:.otherMouseDown,event:mouseDown), "Active router consumes a configured down")
        check(controller.intercept(type:.otherMouseUp,event:mouseUp), "Active router consumes its paired up")
        wait { routed == 1 }; wait { !controller.runner.isRunning }
        routeShortcut.mode = .transparent; preferences.shortcuts = [routeShortcut]; controller.reconcile(sessionActive:true)
        check(!controller.intercept(type:.otherMouseDown,event:mouseDown), "Active router never handles Transparent definitions")
        controller.observeForTesting(type:.otherMouseDown,event:mouseDown)
        controller.observeForTesting(type:.otherMouseUp,event:mouseUp)
        check(mouseDown.type == .otherMouseDown && mouseDown.location == CGPoint(x:-10000,y:-10000) && mouseDown.flags.isEmpty, "Passive routing preserves original event fields")
        wait { routed == 2 }; wait { !controller.runner.isRunning }
        preferences.set(false,for:.shortcutsEnabled); controller.reconcile(sessionActive:true)
        check(!controller.intercept(type:.otherMouseDown,event:mouseDown), "Disabled module passes input through")
        controller.shutdown()
        print("\(checks) Custom Shortcuts checks passed: matching, internal conflicts, persistence, concurrency, sequential actions, and cancellation.")
    }
}
