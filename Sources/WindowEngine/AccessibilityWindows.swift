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
    init(element: AXUIElement, pid: pid_t, bundleID: String, seed: GestureSeed) {
        self.element = element; self.pid = pid; self.bundleID = bundleID; self.seed = seed
    }
}

enum WindowAccessError: Error {
    case cancelled, unsupported, ax(AXError), incompatible
    var category: String {
        switch self {
        case .cancelled: return "cancelled"
        case .unsupported: return "unsupported"
        case .ax(let e): return "AXError.\(e.rawValue)"
        case .incompatible: return "frame-constraint"
        }
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
    #if TESTING
    var onAttributeReadForTesting: (() -> Void)?
    #endif
    init(hitTest: ((AXUIElement, CGPoint) -> AXUIElement?)? = nil) {
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
    private func point(_ element: AXUIElement, _ attribute: String) throws -> CGPoint {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        guard status == .success, let raw = raw, CFGetTypeID(raw) == AXValueGetTypeID() else { throw WindowAccessError.ax(status) }
        var p = CGPoint.zero
        guard AXValueGetValue(raw as! AXValue, .cgPoint, &p) else { throw WindowAccessError.unsupported }
        return p
    }
    private func size(_ element: AXUIElement) throws -> CGSize {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &raw)
        guard status == .success, let raw = raw, CFGetTypeID(raw) == AXValueGetTypeID() else { throw WindowAccessError.ax(status) }
        var s = CGSize.zero
        guard AXValueGetValue(raw as! AXValue, .cgSize, &s) else { throw WindowAccessError.unsupported }
        return s
    }
    func frame(_ element: AXUIElement) throws -> CGRect {
        let frame = try CGRect(origin: point(element, kAXPositionAttribute as String), size: size(element))
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
            guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID != getpid() else { completion(nil); return }
            self.queue.async {
                guard valid() else { completion(nil); return }
                var element = hit
                var visited: [AXUIElement] = []
                var candidate: AXUIElement?
                for _ in 0..<32 {
                    guard valid(), !visited.contains(where: { CFEqual($0, element) }) else { break }
                    visited.append(element)
                    let role = self.value(element, kAXRoleAttribute as String) as? String ?? ""
                    if role == (kAXWindowRole as String) || role == (kAXSheetRole as String) { candidate = element; break }
                    // A menu/popover is a foreground surface, never permission to manipulate the window behind it.
                    if [kAXMenuRole as String, kAXMenuBarRole as String, kAXPopoverRole as String].contains(role) { break }
                    guard valid() else { break }
                    if let owner = self.value(element, kAXWindowAttribute as String), CFGetTypeID(owner) == AXUIElementGetTypeID(), !CFEqual(owner, element) {
                        element = owner as! AXUIElement
                    } else if let parent = self.value(element, kAXParentAttribute as String), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                        element = parent as! AXUIElement
                    } else { break }
                }
                guard let window = candidate, valid() else { completion(nil); return }
                var pid: pid_t = 0
                guard AXUIElementGetPid(window, &pid) == .success, pid != getpid(),
                      let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                      app.activationPolicy != .prohibited, valid() else { completion(nil); return }
                if (self.value(window, kAXMinimizedAttribute as String) as? Bool) == true { completion(nil); return }
                guard valid() else { completion(nil); return }
                // AXFullScreen is the documented accessibility attribute name; support is optional on foreign apps.
                if (self.value(window, "AXFullScreen") as? Bool) == true { completion(nil); return }
                guard valid(), let frame = try? self.frame(window), valid(),
                      cursor.x >= frame.minX - 0.5, cursor.x <= frame.maxX + 0.5,
                      cursor.y >= frame.minY - 0.5, cursor.y <= frame.maxY + 0.5,
                      self.settable(window, kAXPositionAttribute as String), valid() else { completion(nil); return }
                var kind: GestureKind?
                if button != .left, preferences.resizeEnabled,
                   let corner = WindowGeometry.corner(at: cursor, frame: frame, size: preferences.cornerSize),
                   self.settable(window, kAXSizeAttribute as String), valid() { kind = .resize(corner) }
                if kind == nil, button != .right, preferences.moveEnabled {
                    var contentTop: Double?
                    if valid(), let title = self.value(window, kAXTitleUIElementAttribute as String), CFGetTypeID(title) == AXUIElementGetTypeID(),
                       let titleFrame = try? self.frame(title as! AXUIElement), valid(),
                       titleFrame.minY >= frame.minY, titleFrame.maxY < frame.minY + 80 {
                        contentTop = max(frame.minY + 24, titleFrame.maxY + 8)
                    }
                    if WindowGeometry.interiorContains(cursor, frame: frame, contentTop: contentTop) { kind = .move }
                }
                guard valid(), let kind = kind else { completion(nil); return }
                completion(WindowTarget(element: window, pid: pid, bundleID: app.bundleIdentifier ?? "unknown.application",
                                        seed: GestureSeed(frame: frame, pointer: cursor, kind: kind)))
            }
        }
    }

    func apply(target: WindowTarget, pointer: CGPoint, generation: UInt64, gate: GenerationGate,
               restoring: Bool = false, completion: @escaping (Result<CGRect, WindowAccessError>) -> Void) {
        let targetQueue = target.pid == getpid() ? DispatchQueue.main : queue
        targetQueue.async { [weak self] in
            guard let self = self else { completion(.failure(.cancelled)); return }
            func check() throws {
                guard gate.valid(generation) else { throw WindowAccessError.cancelled }
            }
            func write(_ attribute: String, _ payload: AXValue) throws {
                try check()
                let result = AXUIElementSetAttributeValue(target.element, attribute as CFString, payload)
                if result != .success { throw WindowAccessError.ax(result) }
            }
            do {
                try check()
                let accepted = try WindowFrameTransaction.apply(seed: target.seed, pointer: pointer, restoring: restoring,
                    check: check, readFrame: { try self.frame(target.element) }, readSize: { try self.size(target.element) },
                    setPosition: { origin in
                        var origin = origin
                        guard let payload = AXValueCreate(.cgPoint, &origin) else { throw WindowAccessError.unsupported }
                        try write(kAXPositionAttribute as String, payload)
                    }, setSize: { size in
                        var size = size
                        guard let payload = AXValueCreate(.cgSize, &size) else { throw WindowAccessError.unsupported }
                        try write(kAXSizeAttribute as String, payload)
                    })
                completion(.success(accepted))
            } catch is WindowFrameTransaction.Failure { completion(.failure(.incompatible))
            } catch let error as WindowAccessError { completion(.failure(error)) }
            catch { completion(.failure(.unsupported)) }
        }
    }
}
