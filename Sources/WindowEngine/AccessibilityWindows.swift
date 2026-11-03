import AppKit
import ApplicationServices

final class GenerationGate: @unchecked Sendable {
    private struct State { var generation: UInt64 = 0; var open = false }
    private let state = Locked(State())
    func open(_ generation: UInt64) { state.withValue { $0.generation = generation; $0.open = true } }
    func valid(_ generation: UInt64) -> Bool { state.withValue { $0.open && $0.generation == generation } }
    func close() { state.withValue { $0.open = false } }
}

final class WindowTarget: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let seed: GestureSeed
    let feedbackWindow: FeedbackWindow?
    weak var localWindow: NSWindow?
    let usesNativeWindow: Bool
    init(element: AXUIElement, pid: pid_t, bundleID: String, seed: GestureSeed, feedbackWindow: FeedbackWindow? = nil, localWindow: NSWindow? = nil) {
        self.element = element; self.pid = pid; self.bundleID = bundleID; self.seed = seed
        self.feedbackWindow = feedbackWindow
        self.localWindow = localWindow
        usesNativeWindow = localWindow != nil
    }
}

enum WindowAccessError: Error {
    case cancelled, unsupported, ax(AXError), incompatible
    case request(AXError, operation: String)
    var axCode: AXError? {
        switch self {
        case .ax(let code), .request(let code, _): return code
        default: return nil
        }
    }
    var category: String {
        switch self {
        case .cancelled: return "cancelled"
        case .unsupported: return "unsupported"
        case .ax(let e), .request(let e, _): return "AXError.\(e.rawValue)"
        case .incompatible: return "frame-constraint"
        }
    }
    var diagnostic: String {
        if case .request(_, let operation) = self { return category + "; operation=" + operation }
        return category
    }
}

/// A timed-out setter may already have taken effect. Start the bounded recovery
/// with a fresh frame read and reconcile the original absolute target, never a delta.
enum WindowAccessTransaction {
    static let initialTimeout: Float = 0.1
    static let recoveryTimeout: Float = 0.25
    static let budget: TimeInterval = 0.45

    static func apply(seed: GestureSeed, pointer: CGPoint, restoring: Bool,
                      valid: @escaping () -> Bool, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      setTimeout: @escaping (Float) throws -> Void,
                      readFrame: (_ check: () throws -> Void) throws -> CGRect,
                      setPosition: (CGPoint) throws -> Void, setSize: (CGSize) throws -> Void,
                      onRetry: (WindowAccessError) -> Void = { _ in }) throws -> CGRect {
        let deadline = now() + budget
        var timeout = initialTimeout
        func check() throws {
            guard valid() else { throw WindowAccessError.cancelled }
            let remaining = deadline - now()
            guard remaining > 0 else { throw WindowAccessError.request(.cannotComplete, operation: "update.deadline") }
            try setTimeout(min(timeout, Float(remaining)))
        }
        // Reset only this exact AX element; global hit-testing keeps its short timeout.
        defer { try? setTimeout(0) }
        for attempt in 0..<2 {
            do {
                return try WindowFrameTransaction.apply(seed: seed, pointer: pointer, restoring: restoring,
                    check: check, readFrame: { try readFrame(check) },
                    setPosition: setPosition, setSize: setSize)
            } catch let error as WindowAccessError {
                guard valid() else { throw WindowAccessError.cancelled }
                guard error.axCode == .cannotComplete, attempt == 0, now() < deadline else { throw error }
                onRetry(error)
                timeout = recoveryTimeout
            }
        }
        throw WindowAccessError.request(.cannotComplete, operation: "update.recovery")
    }
}

protocol WindowAccessing: AnyObject {
    func resolve(point: CGPoint, button: MouseButton?, preferences: GesturePreferences,
                 deadline: TimeInterval, stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void)
    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate,
               restoring: Bool, completion: @escaping (Result<CGRect, WindowAccessError>) -> Void)
}

final class AccessibilityWindows: WindowAccessing, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.jimmytweaks.accessibility", qos: .userInteractive)
    private let system = AXUIElementCreateSystemWide()
    private let hitTest: (AXUIElement, CGPoint) -> AXUIElement?
    private let logger: FileLogger?
    private let localHitTest: (CGPoint) -> NSWindow?
    #if TESTING
    var onAttributeReadForTesting: (() -> Void)?
    #endif
    init(hitTest: ((AXUIElement, CGPoint) -> AXUIElement?)? = nil, logger: FileLogger? = nil,
         localHitTest: @escaping (CGPoint) -> NSWindow? = AccessibilityWindows.localWindow) {
        self.logger = logger
        self.localHitTest = localHitTest
        self.hitTest = hitTest ?? { system, cursor in
            precondition(Thread.isMainThread)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(cursor.x), Float(cursor.y), &hit) == .success else { return nil }
            return hit
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = AXUIElementSetMessagingTimeout(self.system, 0.05)
            if result != .success { NSLog("Jimmy Tweaks: could not set AX messaging timeout (%d)", result.rawValue) }
        }
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        #if TESTING
        onAttributeReadForTesting?()
        #endif
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private func values(_ element: AXUIElement, _ attributes: [String]) -> [Any]? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &result) == .success else { return nil }
        return result as? [Any]
    }
    private func windowFrame(_ values: [Any]) -> CGRect? {
        guard values.count >= 4, CFGetTypeID(values[2] as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(values[3] as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let position = values[2] as! AXValue, size = values[3] as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        let frame = CGRect(origin: point, size: extent)
        return WindowGeometry.valid(frame) ? frame : nil
    }
    private static func localWindow(at point: CGPoint) -> NSWindow? {
        let screenPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
        // AX has already identified our process. Do not fall through an owned
        // sheet, alert, menu, or popover to an underlying Settings window.
        var number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
        for _ in 0..<64 {
            guard number > 0, let window = NSApp.windows.first(where: { $0.windowNumber == number }) else { return nil }
            if !window.ignoresMouseEvents { return window }
            number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: number)
        }
        return nil
    }
    static func screenFrame(_ window: NSWindow) -> CGRect {
        let f = window.frame
        return CGRect(x: f.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - f.maxY, width: f.width, height: f.height)
    }
    private func resolveLocal(point: CGPoint, button: MouseButton?, preferences: GesturePreferences) -> WindowTarget? {
        guard NSApp.modalWindow == nil, let window = localHitTest(point), window.isVisible, !window.isMiniaturized,
              window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen),
              window.attachedSheet == nil, window.sheetParent == nil else { return nil }
        let frame = Self.screenFrame(window)
        guard let kind = WindowGeometry.activationKind(at: point, frame: frame, edgeZoneSize: preferences.edgeZoneSize) else { return nil }
        switch kind {
        case .move: guard button != .right, preferences.moveEnabled else { return nil }
        case .resize: guard button != .left, preferences.resizeEnabled, window.styleMask.contains(.resizable) else { return nil }
        }
        return WindowTarget(element: AXUIElementCreateApplication(getpid()), pid: getpid(), bundleID: Bundle.main.bundleIdentifier ?? "local.jimmytweaks.app",
            seed: GestureSeed(frame: frame, pointer: point, kind: kind),
            feedbackWindow: FeedbackWindow(number: window.windowNumber, level: window.level.rawValue), localWindow: window)
    }
    private func point(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success else { throw WindowAccessError.request(status, operation: "read.position") }
        guard let raw = raw, CFGetTypeID(raw) == AXValueGetTypeID() else { throw WindowAccessError.unsupported }
        var p = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &p) else { throw WindowAccessError.unsupported }
        return p
    }
    private func size(_ element: AXUIElement) throws -> CGSize {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw)
        guard status == .success else { throw WindowAccessError.request(status, operation: "read.size") }
        guard let raw = raw, CFGetTypeID(raw) == AXValueGetTypeID() else { throw WindowAccessError.unsupported }
        var s = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &s) else { throw WindowAccessError.unsupported }
        return s
    }
    func frame(_ element: AXUIElement, check: () throws -> Void = {}) throws -> CGRect {
        try check()
        let origin = try point(element, kAXPositionAttribute as String)
        try check()
        let frame = try CGRect(origin: origin, size: size(element))
        guard WindowGeometry.valid(frame) else { throw WindowAccessError.unsupported }
        return frame
    }
    private func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var yes: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &yes) == .success && yes.boolValue
    }

    func resolve(point cursor: CGPoint, button: MouseButton?, preferences: GesturePreferences,
                 deadline: TimeInterval, stillValid: @escaping () -> Bool, completion: @escaping (WindowTarget?) -> Void) {
        // A system-wide AX hit can be serviced locally by AppKit when the
        // pointer is over our Settings or feedback windows. That call must run
        // on main; dispatch only foreign-element traversal/writes to the worker.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            func valid() -> Bool { stillValid() && ProcessInfo.processInfo.systemUptime < deadline }
            guard valid(), let hit = self.hitTest(self.system, cursor), valid() else { completion(nil); return }
            var hitPID: pid_t = 0
            guard AXUIElementGetPid(hit, &hitPID) == .success else { completion(nil); return }
            if hitPID == getpid() {
                let target = self.resolveLocal(point: cursor, button: button, preferences: preferences)
                completion(valid() ? target : nil); return
            }
            self.queue.async {
                let bundle = NSRunningApplication(processIdentifier: hitPID)?.bundleIdentifier ?? "unknown.application"
                func reject(_ reason: String) {
                    if button != nil {
                        self.logger?.rateLimited(bundle + ".admission." + reason, component: "accessibility", event: "target.unclaimed",
                            message: "target=\(bundle); reason=\(reason)")
                    }
                    completion(nil)
                }
                guard valid() else { reject("admission-deadline"); return }
                var element = hit
                var visited: [AXUIElement] = []
                var candidate: AXUIElement?
                for _ in 0..<32 {
                    guard valid(), !visited.contains(where: { CFEqual($0, element) }) else { break }
                    visited.append(element)
                    guard let attributes = self.values(element, [kAXRoleAttribute as String, kAXWindowAttribute as String, kAXParentAttribute as String]), attributes.count == 3 else { break }
                    let role = attributes[0] as? String ?? ""
                    if role == (kAXWindowRole as String) || role == (kAXSheetRole as String) { candidate = element; break }
                    // A menu/popover is a foreground surface, never permission to manipulate the window behind it.
                    if [kAXMenuRole as String, kAXMenuBarRole as String, kAXPopoverRole as String].contains(role) { break }
                    guard valid() else { break }
                    let owner = attributes[1] as CFTypeRef, parent = attributes[2] as CFTypeRef
                    if CFGetTypeID(owner) == AXUIElementGetTypeID(), !CFEqual(owner, element) {
                        element = owner as! AXUIElement
                    } else if CFGetTypeID(parent) == AXUIElementGetTypeID() {
                        element = parent as! AXUIElement
                    } else { break }
                }
                guard let window = candidate, valid() else { reject(valid() ? "no-accessible-window" : "admission-deadline"); return }
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success, pid != getpid(),
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      app.activationPolicy != .prohibited, valid() else { completion(nil); return }
                // Batch Terminal's often-deep AX tree and frame reads to avoid
                // spending the admission budget on separate cross-process calls.
                guard let attributes = self.values(window, [kAXMinimizedAttribute as String, "AXFullScreen", kAXPositionAttribute as String, kAXSizeAttribute as String]),
                      let frame = self.windowFrame(attributes), valid() else { reject("frame-unavailable-or-deadline"); return }
                if (attributes[0] as? Bool) == true || (attributes[1] as? Bool) == true { reject("minimized-or-fullscreen"); return }
                guard valid(),
                      cursor.x >= frame.minX - 0.5, cursor.x <= frame.maxX + 0.5,
                      cursor.y >= frame.minY - 0.5, cursor.y <= frame.maxY + 0.5,
                      self.settable(window, kAXPositionAttribute as String), valid() else { completion(nil); return }
                guard let kind = WindowGeometry.activationKind(at: cursor, frame: frame, edgeZoneSize: preferences.edgeZoneSize) else { completion(nil); return }
                switch kind {
                case .resize:
                    guard button != .left, preferences.resizeEnabled,
                          self.settable(window, kAXSizeAttribute as String), valid() else { reject(button == .left ? "left-button-in-resize-zone" : "resize-unavailable"); return }
                case .move:
                    guard button != .right, preferences.moveEnabled else { reject("right-button-in-move-zone"); return }
                }
                guard valid() else { completion(nil); return }
                completion(WindowTarget(element: window, pid: pid, bundleID: app.bundleIdentifier ?? "unknown.application",
                                        seed: GestureSeed(frame: frame, pointer: cursor, kind: kind),
                                        feedbackWindow: FeedbackWindow.match(pid: pid, frame: frame)))
            }
        }
    }

    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate,
               restoring: Bool = false, completion: @escaping (Result<CGRect, WindowAccessError>) -> Void) {
        let targetQueue = target.pid == getpid() ? DispatchQueue.main : queue
        targetQueue.async { [weak self] in
            guard let self = self else { completion(.failure(.cancelled)); return }
            if target.usesNativeWindow {
                do { completion(.success(try self.applyLocal(target: target, pointer: pointer, generation: generation, gate: gate, restoring: restoring))) }
                catch let error as WindowAccessError { completion(.failure(error)) }
                catch { completion(.failure(.unsupported)) }
                return
            }
            func check() throws {
                guard gate.valid(generation) else { throw WindowAccessError.cancelled }
            }
            func write(_ attribute: String, _ payload: AXValue) throws {
                try check()
                let result = AXUIElementSetAttributeValue(target.element, attribute as CFString, payload)
                if result != .success { throw WindowAccessError.request(result, operation: attribute == kAXPositionAttribute as String ? "write.position" : "write.size") }
            }
            do {
                try check()
                let accepted = try WindowAccessTransaction.apply(seed: target.seed, pointer: pointer, restoring: restoring,
                    valid: { gate.valid(generation) },
                    setTimeout: { timeout in
                        let status = AXUIElementSetMessagingTimeout(target.element, timeout)
                        if status != .success { throw WindowAccessError.request(status, operation: "update.timeout") }
                    }, readFrame: { try self.frame(target.element, check: $0) },
                    setPosition: { origin in
                        var origin = origin
                        guard let payload = AXValueCreate(.cgPoint, &origin) else { throw WindowAccessError.unsupported }
                        try write(kAXPositionAttribute as String, payload)
                    }, setSize: { size in
                        var size = size
                        guard let payload = AXValueCreate(.cgSize, &size) else { throw WindowAccessError.unsupported }
                        try write(kAXSizeAttribute as String, payload)
                    }, onRetry: { error in
                        self.logger?.rateLimited(target.bundleID + ".retry", component: "accessibility", event: "target.retry",
                            message: "target=\(target.bundleID); \(error.diagnostic)")
                    })
                completion(.success(accepted))
            } catch is WindowFrameTransaction.Failure { completion(.failure(.incompatible))
            } catch let error as WindowAccessError { completion(.failure(error)) }
            catch { completion(.failure(.unsupported)) }
        }
    }
    private func applyLocal(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate, restoring: Bool) throws -> CGRect {
        precondition(Thread.isMainThread)
        guard gate.valid(generation), let window = target.localWindow, window.isVisible, !window.isMiniaturized,
              window.attachedSheet == nil, !window.styleMask.contains(.fullScreen) else { throw WindowAccessError.cancelled }
        var desired = restoring ? target.seed.frame : target.seed.desiredFrame(at: pointer)
        if case .resize(let corner) = target.seed.kind {
            let contentMinimum = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
            let proposed = CGSize(width: max(window.minSize.width, contentMinimum.width, desired.width),
                                  height: max(window.minSize.height, contentMinimum.height, desired.height))
            let constrained = window.delegate?.windowWillResize?(window, to: proposed) ?? proposed
            desired.size = CGSize(width: min(window.maxSize.width, max(window.minSize.width, contentMinimum.width, constrained.width)),
                                  height: min(window.maxSize.height, max(window.minSize.height, contentMinimum.height, constrained.height)))
            desired.origin = corner.origin(size: desired.size, anchor: corner.anchor(in: target.seed.frame))
        }
        guard gate.valid(generation) else { throw WindowAccessError.cancelled }
        let cocoa = CGRect(x: desired.minX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - desired.maxY, width: desired.width, height: desired.height)
        window.setFrame(cocoa, display: true)
        return Self.screenFrame(window)
    }
}
