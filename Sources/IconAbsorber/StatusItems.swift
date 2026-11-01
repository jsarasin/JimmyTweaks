import AppKit
import ApplicationServices

struct AbsorbedStatusItem: @unchecked Sendable {
    let id: String
    let bundle: String
    let name: String
    let pid: pid_t
    let index: Int
    let identifier: String
    let label: String
    let element: AXUIElement
    let frame: CGRect?
    let actions: [String]
}

struct StatusItemSnapshot: @unchecked Sendable {
    var items: [AbsorbedStatusItem] = []
    var systemItems: [AbsorbedStatusItem] = []
    var clock: AbsorbedStatusItem? { systemItems.first { $0.identifier.hasSuffix(".clock") } }
    var unsupportedSystemItems: [String] {
        systemItems.filter { item in
            let id = item.identifier.lowercased()
            return ![".battery", ".bluetooth", ".clock", ".display", ".displays", ".keyboard", ".keyboardbrightness", ".sound", ".volume", ".wifi", ".screenmirroring", ".airplay", ".controlcenter"].contains { id.hasSuffix($0) }
        }.map { $0.label.isEmpty ? $0.identifier : $0.label }
    }
}

enum StatusItemAccess {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
        return CGRect(origin: point, size: size)
    }
    /// Worker-only. Own-process AX traversal can deadlock AppKit and is excluded.
    static func scan() -> StatusItemSnapshot {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            guard $0.processIdentifier != getpid(), let bundle = $0.bundleIdentifier, bundle != own else { return false }
            return !bundle.hasPrefix("com.apple.") || bundle == "com.apple.MenuBarAgent"
        }
        let lock = NSLock(); var all: [AbsorbedStatusItem] = []
        DispatchQueue.concurrentPerform(iterations: min(8, max(1, apps.count))) { shard in
            var found: [AbsorbedStatusItem] = []
            for index in stride(from: shard, to: apps.count, by: 8) { found += items(in: apps[index]) }
            lock.lock(); all += found; lock.unlock()
        }
        return StatusItemSnapshot(items: all.filter { !$0.bundle.hasPrefix("com.apple.") }, systemItems: all.filter { $0.bundle == "com.apple.MenuBarAgent" })
    }
    static func items(in app: NSRunningApplication) -> [AbsorbedStatusItem] {
        guard let bundle = app.bundleIdentifier else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        guard let bar: AXUIElement = value(root, kAXExtrasMenuBarAttribute) else { return [] }
        AXUIElementSetMessagingTimeout(bar, 0.25)
        let children: [AXUIElement] = value(bar, kAXChildrenAttribute) ?? []
        return children.enumerated().compactMap { index, child in
            AXUIElementSetMessagingTimeout(child, 0.25)
            var element = child
            if (value(child, kAXRoleAttribute) as String?) == kAXGroupRole,
               let inner = (value(child, kAXChildrenAttribute) as [AXUIElement]?)?.first {
                element = inner; AXUIElementSetMessagingTimeout(element, 0.25)
            }
            guard (value(element, kAXRoleAttribute) as String?) == kAXMenuBarItemRole else { return nil }
            let identifier: String = value(element, kAXIdentifierAttribute) ?? ""
            let label: String = value(element, kAXTitleAttribute) ?? value(element, kAXDescriptionAttribute) ?? ""
            var actions: CFArray?; AXUIElementCopyActionNames(element, &actions)
            return AbsorbedStatusItem(id: "\(bundle)/\(identifier.isEmpty ? "item-\(index)" : identifier)", bundle: bundle,
                                     name: app.localizedName ?? bundle, pid: app.processIdentifier, index: index,
                                     identifier: identifier, label: label, element: element, frame: frame(element), actions: actions as? [String] ?? [])
        }
    }
    struct Surface: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
        let layer: Int
    }
    static func surfaces() -> [Surface] {
        let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32, let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = entry[kCGWindowBounds as String] as? CFDictionary, let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return Surface(id: id, pid: pid, frame: rect, layer: entry[kCGWindowLayer as String] as? Int ?? 0)
        }
    }
    /// Native floating panels only. Menus, protected surfaces and standard app windows stay put.
    static func repositionFloatingPanel(pid: pid_t, excluding baseline: [AXUIElement], near point: CGPoint, within visibleFrame: CGRect) {
        let root = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(root, 0.25)
        let windows: [AXUIElement] = value(root, kAXWindowsAttribute) ?? []
        for window in windows where !baseline.contains(where: { CFEqual($0, window) }) {
            AXUIElementSetMessagingTimeout(window, 0.25)
            guard (value(window, kAXRoleAttribute) as String?) == kAXWindowRole,
                  (value(window, kAXSubroleAttribute) as String?) == kAXFloatingWindowSubrole,
                  (value(window, kAXModalAttribute) as Bool?) != true,
                  let rect = frame(window), rect.width >= 100, rect.width <= 800, rect.height <= 900 else { continue }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success, settable.boolValue else { continue }
            var position = CGPoint(x: max(visibleFrame.minX, min(point.x, visibleFrame.maxX - rect.width)),
                                   y: max(visibleFrame.minY, min(point.y, visibleFrame.maxY - rect.height)))
            if let ax = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ax) }
        }
    }
}

final class StatusItemObservation {
    let pid: pid_t
    private var observer: AXObserver?
    private let changed: (String, AXUIElement) -> Void
    init(pid: pid_t, items: [AbsorbedStatusItem], changed: @escaping (String, AXUIElement) -> Void) {
        self.pid = pid; self.changed = changed
        var result: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let owner = Unmanaged<StatusItemObservation>.fromOpaque(context).takeUnretainedValue()
            owner.changed(notification as String, element)
        }, &result)
        guard error == .success, let result else { return }
        observer = result
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let root = AXUIElementCreateApplication(pid)
        for element in [root] + items.map(\.element) {
            for name in [kAXMenuOpenedNotification, kAXMenuClosedNotification, kAXWindowCreatedNotification, kAXUIElementDestroyedNotification] {
                // Unsupported notification registrations are normal for some applications.
                AXObserverAddNotification(result, element, name as CFString, pointer)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(result), .commonModes)
    }
    deinit { if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) } }
}
