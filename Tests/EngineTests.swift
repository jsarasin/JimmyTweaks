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
        accessibilityRecovery()
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

    private static func accessibilityRecovery() {
        let original = CGRect(x: 200, y: 150, width: 600, height: 400)
        let kinds = [GestureKind.move] + WindowCorner.allCases.map { .resize($0) }
        for kind in kinds {
            let pointer: CGPoint
            if case .resize(let corner) = kind { pointer = CGPoint(x: corner.isLeft ? -40 : 40, y: corner.isTop ? -30 : 30) }
            else { pointer = CGPoint(x: 40, y: 30) }
            let seed = GestureSeed(frame: original, pointer: .zero, kind: kind)
            for operation in ["read.position", "read.size", "write.position", "write.size"] {
                if kind == .move && operation == "write.size" { continue }
                if kind == .resize(.bottomRight) && operation == "write.position" { continue }
                for alreadyApplied in [false, true] {
                    var frame = original, fault = false, time = 0.0, reads = 0, writes = 0
                    var timeout: Float = 0, timeouts: [Float] = []
                    func fail(_ stage: String) throws {
                        if stage == operation && !fault {
                            fault = true; time += Double(timeout)
                            throw WindowAccessError.request(.cannotComplete, operation: stage)
                        }
                    }
                    let accepted = try! WindowAccessTransaction.apply(seed: seed, pointer: pointer, restoring: false,
                        valid: { true }, now: { time }, setTimeout: { timeout = $0; timeouts.append($0) },
                        readFrame: { check in
                            reads += 1
                            try check(); try fail("read.position")
                            try check(); try fail("read.size")
                            return frame
                        }, setPosition: { position in
                            writes += 1
                            if alreadyApplied { frame.origin = position }
                            try fail("write.position"); frame.origin = position
                        }, setSize: { size in
                            writes += 1
                            if alreadyApplied { frame.size = size }
                            try fail("write.size"); frame.size = size
                        })
                    assert(fault && reads >= 2, "A transient failure must restart with a fresh frame read: \(kind.name)/\(operation)")
                    assert(WindowGeometry.approximatelyEqual(accepted, seed.desiredFrame(at: pointer)), "Recovery must reconcile the original absolute frame after a possibly applied setter")
                    assert(timeouts.contains { $0 > WindowAccessTransaction.initialTimeout } && timeouts.last == 0, "Only the active target receives a longer recovery timeout, and it is restored afterward")
                    if kind == .move && operation == "write.position" && alreadyApplied {
                        assert(writes == 1, "A timed-out write that already took effect must not be repeated")
                    }
                }
            }
            var frame = original.offsetBy(dx: 20, dy: 10), reads = 0
            let restored = try! WindowAccessTransaction.apply(seed: seed, pointer: pointer, restoring: true,
                valid: { true }, setTimeout: { _ in }, readFrame: { check in
                    try check(); reads += 1
                    if reads == 1 { throw WindowAccessError.request(.cannotComplete, operation: "read.position") }
                    return frame
                }, setPosition: { frame.origin = $0 }, setSize: { frame.size = $0 })
            assert(WindowGeometry.approximatelyEqual(restored, original), "Escape restoration uses the same bounded recovery")
        }
        let seed = GestureSeed(frame: original, pointer: .zero, kind: .move)
        // Model a 150 ms Messages-style setter: it outlasts the old timeout but
        // answers within the recovery allowance. No real time or permission changes.
        var slowFrame = original, slowTime = 0.0, slowTimeout: Float = 0.05, slowWrites = 0
        func slowSet(_ point: CGPoint) throws {
            slowWrites += 1; slowTime += min(0.15, Double(slowTimeout))
            guard slowTimeout >= 0.15 else { throw WindowAccessError.request(.cannotComplete, operation: "write.position") }
            slowFrame.origin = point
        }
        do {
            _ = try WindowFrameTransaction.apply(seed: seed, pointer: CGPoint(x: 20, y: 10), check: {},
                readFrame: { slowFrame }, setPosition: slowSet, setSize: { _ in assertionFailure() })
            assertionFailure("The original short timeout must reproduce the failure")
        } catch let error as WindowAccessError { assert(error.axCode == .cannotComplete && slowFrame == original) }
        catch { assertionFailure("Unexpected simulated timeout: \(error)") }
        slowTime = 0; slowWrites = 0
        var retries = 0
        let recovered = try! WindowAccessTransaction.apply(seed: seed, pointer: CGPoint(x: 20, y: 10), restoring: false,
            valid: { true }, now: { slowTime }, setTimeout: { slowTimeout = $0 }, readFrame: { check in try check(); return slowFrame },
            setPosition: slowSet, setSize: { _ in assertionFailure() }, onRetry: { error in
                retries += 1; assert(error.diagnostic.contains("operation=write.position"))
            })
        assert(WindowGeometry.approximatelyEqual(recovered, original.offsetBy(dx: 20, dy: 10)) && slowWrites == 2 && retries == 1 && slowTime < WindowAccessTransaction.budget,
               "The same delayed setter must recover within the bounded update budget")
        for code in [AXError.apiDisabled, .attributeUnsupported, .invalidUIElement, .notImplemented, .cannotComplete] {
            var reads = 0, writes = 0, resets = 0
            do {
                _ = try WindowAccessTransaction.apply(seed: seed, pointer: CGPoint(x: 10, y: 10), restoring: false,
                    valid: { true }, setTimeout: { if $0 == 0 { resets += 1 } }, readFrame: { check in
                        try check(); reads += 1; throw WindowAccessError.request(code, operation: "read.position")
                    }, setPosition: { _ in writes += 1 }, setSize: { _ in writes += 1 })
                assertionFailure("Persistent failures must be returned")
            } catch let error as WindowAccessError {
                assert(error.axCode == code && writes == 0 && resets == 1)
                assert(reads == (code == .cannotComplete ? 2 : 1), "Retry exactly once for communication failures; never retry permanent/permission failures")
                assert(error.diagnostic.contains("operation=read.position"), "Failure diagnostics identify the exact AX operation")
            } catch { assertionFailure("Unexpected recovery error: \(error)") }
        }
        var valid = true, writes = 0
        do {
            _ = try WindowAccessTransaction.apply(seed: seed, pointer: CGPoint(x: 10, y: 10), restoring: false,
                valid: { valid }, setTimeout: { _ in }, readFrame: { check in try check(); return original },
                setPosition: { _ in
                    writes += 1; valid = false
                    throw WindowAccessError.request(.cannotComplete, operation: "write.position")
                }, setSize: { _ in assertionFailure("Moving must not resize") })
            assertionFailure("Cancellation must end recovery")
        } catch WindowAccessError.cancelled { assert(writes == 1, "Disable/Escape/generation changes prevent a retry write") }
        catch { assertionFailure("Unexpected cancellation error: \(error)") }
        var time = 0.0, deadlineWrites = 0
        do {
            _ = try WindowAccessTransaction.apply(seed: seed, pointer: CGPoint(x: 10, y: 10), restoring: false,
                valid: { true }, now: { time }, setTimeout: { _ in }, readFrame: { check in
                    try check(); time += 0.3; try check(); time += 0.2; return original
                }, setPosition: { _ in deadlineWrites += 1 }, setSize: { _ in deadlineWrites += 1 })
            assertionFailure("Slow requests must respect the total deadline")
        } catch let error as WindowAccessError {
            assert(error.axCode == .cannotComplete && deadlineWrites == 0, "No geometry is written after the recovery budget expires")
        } catch { assertionFailure("Unexpected deadline error: \(error)") }
        print("Accessibility recovery regressions passed: slow reads/setters, already-applied writes, all corners, Escape, permanent failures, cancellation, and deadline.")
    }
}
