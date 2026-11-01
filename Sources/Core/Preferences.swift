import Foundation
import CoreFoundation

extension Notification.Name {
    static let preferencesChanged = Notification.Name("JimmyTweaks.preferencesChanged")
    static let runtimeChanged = Notification.Name("JimmyTweaks.runtimeChanged")
    static let permissionsChanged = Notification.Name("JimmyTweaks.permissionsChanged")
    static let loggingChanged = Notification.Name("JimmyTweaks.loggingChanged")
    static let iconAbsorberChanged = Notification.Name("JimmyTweaks.iconAbsorberChanged")
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
    var snapshot: Value { withValue { $0 } }
}

enum PreferenceKey: String, CaseIterable {
    case suspended = "global.suspendAll"
    case enabled = "windowResizer.enabled"
    case resizeEnabled = "windowResizer.resizeEnabled"
    case activation = "windowResizer.resizeActivation"
    case resizeThreshold = "windowResizer.resizeThresholdPoints"
    case cornerSize = "windowResizer.cornerSizePoints"
    case moveEnabled = "windowResizer.moveEnabled"
    case moveThreshold = "windowResizer.moveThresholdPoints"
    case cursor = "windowResizer.changeCursor"
    case hints = "windowResizer.showCornerHints"
    case outline = "windowResizer.showWindowOutline"
    case loginRequested = "general.launchAtLoginRequested"
    case iconAbsorberEnabled = "iconAbsorber.enabled"
    case iconAbsorberHiddenPress = "iconAbsorber.hiddenPress"
    case iconAbsorberPositionPanels = "iconAbsorber.positionPanels"

    var defaultValue: Any {
        switch self {
        case .suspended, .outline, .loginRequested, .iconAbsorberEnabled, .iconAbsorberHiddenPress: return false
        case .iconAbsorberPositionPanels: return true
        case .enabled, .resizeEnabled, .moveEnabled, .cursor, .hints: return true
        case .activation: return "immediate"
        case .resizeThreshold, .moveThreshold: return 5
        case .cornerSize: return 200
        }
    }
    var range: ClosedRange<Int>? {
        switch self {
        case .resizeThreshold, .moveThreshold: return 1...30
        case .cornerSize: return 8...400
        default: return nil
        }
    }
}

struct GesturePreferences: Equatable {
    var enabled = true
    var resizeEnabled = true
    var moveEnabled = true
    var immediateResize = true
    var resizeThreshold = 5.0
    var moveThreshold = 5.0
    var cornerSize = 200.0
    var changeCursor = true
    var cornerHints = true
    var outline = false
    var anyGesture: Bool { enabled && (resizeEnabled || moveEnabled) }
}

final class PreferenceStore {
    let defaults: UserDefaults
    private(set) var repairMessage: String?
    private(set) var newerSchema = false
    private let schemaKey = "preferences.schemaVersion"
    private var batchDepth = 0
    private var notificationPending = false
    private(set) var resetRevision: UInt64 = 0
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let schema = defaults.integer(forKey: schemaKey)
        newerSchema = schema > 1
        var registered = Dictionary(uniqueKeysWithValues: PreferenceKey.allCases.map { ($0.rawValue, $0.defaultValue) })
        registered["onboarding.assistantVersion"] = 0
        registered["onboarding.assistantDisposition"] = "notStarted"
        defaults.register(defaults: registered)
        var repaired = false
        for key in PreferenceKey.allCases {
            let raw = defaults.object(forKey: key.rawValue)
            let valid = normalized(raw, key: key)
            if !equal(raw, valid) {
                repaired = true
                if !newerSchema { defaults.set(valid, forKey: key.rawValue) }
            }
        }
        if repaired { repairMessage = "Some invalid preferences were replaced with safe values." }
        if !newerSchema { defaults.set(1, forKey: schemaKey) }
    }
    private func normalized(_ raw: Any?, key: PreferenceKey) -> Any {
        if let range = key.range {
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return key.defaultValue }
            return min(range.upperBound, max(range.lowerBound, n.intValue))
        }
        if key == .activation {
            guard let s = raw as? String, ["immediate", "threshold"].contains(s) else { return key.defaultValue }
            return s
        }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return key.defaultValue }
        return n.boolValue
    }
    private func equal(_ a: Any?, _ b: Any) -> Bool {
        guard let a = a else { return false }
        return (a as? NSObject)?.isEqual(b) ?? false
    }
    func bool(_ key: PreferenceKey) -> Bool { normalized(defaults.object(forKey: key.rawValue), key: key) as? Bool ?? false }
    func int(_ key: PreferenceKey) -> Int { normalized(defaults.object(forKey: key.rawValue), key: key) as? Int ?? 0 }
    func string(_ key: PreferenceKey) -> String { normalized(defaults.object(forKey: key.rawValue), key: key) as? String ?? "" }
    func set(_ value: Any, for key: PreferenceKey) {
        defaults.set(normalized(value, key: key), forKey: key.rawValue)
        changed()
    }
    var gesture: GesturePreferences {
        GesturePreferences(enabled: bool(.enabled), resizeEnabled: bool(.resizeEnabled), moveEnabled: bool(.moveEnabled),
            immediateResize: string(.activation) == "immediate", resizeThreshold: Double(int(.resizeThreshold)),
            moveThreshold: Double(int(.moveThreshold)), cornerSize: Double(int(.cornerSize)),
            changeCursor: bool(.cursor), cornerHints: bool(.hints), outline: bool(.outline))
    }
    var needsAssistant: Bool { defaults.string(forKey: "onboarding.assistantDisposition") == "notStarted" }
    func finishAssistant(skipped: Bool) {
        defaults.set(1, forKey: "onboarding.assistantVersion")
        defaults.set(skipped ? "skipped" : "completed", forKey: "onboarding.assistantDisposition")
    }
    func resetWindow() { reset(keys: PreferenceKey.allCases.filter { $0.rawValue.hasPrefix("windowResizer.") }) }
    func resetAll() {
        defaults.removeObject(forKey: "iconAbsorber.applications")
        reset(keys: PreferenceKey.allCases)
        defaults.removeObject(forKey: "NSWindow Frame JimmyTweaks.Settings")
    }
    var iconAbsorberSelection: IconAbsorberSelection {
        get { IconAbsorberSelection(defaults.object(forKey: "iconAbsorber.applications") as? [String] ?? [], excluding: Bundle.main.bundleIdentifier ?? "local.jimmytweaks.app") }
        set {
            defaults.set(IconAbsorberSelection(newValue.bundles, excluding: Bundle.main.bundleIdentifier ?? "local.jimmytweaks.app").bundles, forKey: "iconAbsorber.applications")
            changed()
        }
    }
    private func reset(keys: [PreferenceKey]) {
        for key in keys { defaults.set(key.defaultValue, forKey: key.rawValue) }
        resetRevision &+= 1
        changed()
    }
    func batch(_ changes: () -> Void) {
        batchDepth += 1; changes(); batchDepth -= 1
        if batchDepth == 0 && notificationPending { notificationPending = false; changed() }
    }
    private func changed() {
        if batchDepth > 0 { notificationPending = true; return }
        NotificationCenter.default.post(name: .preferencesChanged, object: self)
    }
}
