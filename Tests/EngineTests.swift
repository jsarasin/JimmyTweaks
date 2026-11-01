import AppKit

private final class ControlledWindows: WindowAccessing {
    var resolutions: [(WindowTarget?) -> Void] = []
    var writes: [(Result<CGRect, WindowAccessError>) -> Void] = []
    func resolve(point: CGPoint, button: MouseButton?, preferences: GesturePreferences,
                 deadline: TimeInterval, stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void) {
        resolutions.append(completion)
    }
    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate,
               restoring: Bool, completion: @escaping (Result<CGRect, WindowAccessError>) -> Void) {
        writes.append(completion)
    }
}

enum EngineTests {
    static func run(logger: FileLogger) {
        func settle() { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !condition() && Date() < end { settle() }
            assert(condition(), "Timed out waiting for controlled engine work")
        }
        let modifiers = Modifiers(command: true, extra: false)
        let frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        func target(_ kind: GestureKind) -> WindowTarget {
            WindowTarget(element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: "test.fixture",
                         seed: GestureSeed(frame: frame, pointer: .zero, kind: kind))
        }
        // Disable either gesture after mouse-up, both before and during its final write.
        for button in [MouseButton.left, .right] {
            for inFlight in [false, true] {
                let windows = ControlledWindows()
                var preferences = GesturePreferences()
                let engine = WindowGestureController(preferences: preferences, windows: windows, logger: logger)
                engine.attachToCurrentRunLoopForTesting()
                assert(engine.handleForTesting(.down(button, .zero, modifiers)).suppress)
                windows.resolutions.removeFirst()(target(button == .left ? .move : .resize(.bottomRight)))
                if button == .left {
                    // Resolve before sending the drag that crosses the move threshold.
                    for _ in 0..<3 { settle() }
                    _ = engine.handleForTesting(.drag(button, CGPoint(x: 10, y: 10)))
                }
                wait { !windows.writes.isEmpty }
                if inFlight {
                    windows.writes.removeFirst()(.success(frame))
                    for _ in 0..<3 { settle() }
                }
                _ = engine.handleForTesting(.up(button, CGPoint(x: 20, y: 20)))
                if inFlight { wait { !windows.writes.isEmpty } }
                if button == .right { preferences.resizeEnabled = false } else { preferences.moveEnabled = false }
                engine.update(preferences)
                for _ in 0..<3 { settle() }
                while !windows.writes.isEmpty { windows.writes.removeFirst()(.failure(.cancelled)) }
                for _ in 0..<3 { settle() }
                let next = button == .right ? MouseButton.left : .right
                assert(engine.handleForTesting(.down(next, .zero, modifiers)).suppress,
                       "The remaining enabled gesture must work after final-write cancellation")
                _ = engine.handleForTesting(.escapeDown)
                _ = engine.handleForTesting(.up(next, .zero))
                _ = engine.handleForTesting(.escapeUp)
            }
        }
        // A rejected down awaits a callback proxy. A later discard must remove
        // that unsent replay and consume its physical up, including stop escalation.
        for (ordinaryStopFirst, releaseBeforeCleanup) in [(false, false), (true, false), (false, true)] {
            let windows = ControlledWindows()
            let engine = WindowGestureController(preferences: GesturePreferences(), windows: windows, logger: logger)
            engine.attachToCurrentRunLoopForTesting()
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left)!
            _ = engine.handleForTesting(.down(.left, .zero, modifiers), event: down)
            windows.resolutions.removeFirst()(nil)
            wait { engine.hasDeferredReplayForTesting }
            if ordinaryStopFirst {
                engine.stop(discardPending: false)
                for _ in 0..<3 { settle() }
            }
            engine.stop(discardPending: true)
            if !releaseBeforeCleanup {
                wait { !engine.hasDeferredReplayForTesting }
                assert(engine.ownsSequenceForTesting)
            }
            // Also exercise a physical release arriving before the queued stop block.
            assert(engine.handleForTesting(.up(.left, .zero)).suppress, "A discarded down must not leak an orphan up")
            assert(!engine.hasDeferredReplayForTesting)
            assert(!engine.ownsSequenceForTesting)
        }
        // Wait for a child that ignores SIGTERM, including its delayed SIGKILL,
        // before allowing ordinary shutdown to complete.
        let prefs = PreferenceStore(defaults: MemoryDefaults()); prefs.set(true, for: .suspended)
        let permissions = PermissionCoordinator(checkAccessibility: { false }, checkEventPosting: { false }, requestEventPosting: { false },
                                              checkListening: { false }, requestListening: { false }, checkScreenRecording: { false })
        let runtime = RuntimeCoordinator(preferences: prefs, permissions: permissions, logger: logger)
        let readyFile = logger.directory.appendingPathComponent("shutdown-child-\(UUID().uuidString).ready")
        try! FileManager.default.createDirectory(at: logger.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: readyFile) }
        let child = OwnedShortcutProcess(executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
                                         arguments: ["--shutdown-child", readyFile.path])
        runtime.shortcuts.registry.register(ShortcutActionDefinition(id: "test.shutdown-child", name: "Shutdown child", category: "Test", description: "") { _, _ in _ = try await child.run() })
        var shortcut = ShortcutDefinition(); shortcut.actions = [ShortcutActionInstance(actionID: "test.shutdown-child")]
        assert(runtime.shortcuts.runner.start(shortcut))
        wait { FileManager.default.fileExists(atPath: readyFile.path) }
        var shutdownFinished = false
        runtime.shutdown { result in
            if case .failure(let error) = result { assertionFailure(error.localizedDescription) }
            assert(!child.isRunning && !runtime.shortcuts.runner.isRunning, "Shutdown must finish owned process cancellation before completion")
            shutdownFinished = true
        }
        for _ in 0..<3 { settle() }
        assert(!shutdownFinished && child.isRunning, "A SIGTERM-resistant child keeps shutdown pending")
        wait { shutdownFinished }
        print("Engine regressions passed: final-write cancellation, balanced deferred replay/discard, and shutdown through owned-process escalation.")
    }
}
