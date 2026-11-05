import Foundation
import CoreFoundation

extension Notification.Name {
    static let preferencesChanged = Notification.Name("JimmyTweaks.preferencesChanged")
    static let runtimeChanged = Notification.Name("JimmyTweaks.runtimeChanged")
    static let permissionsChanged = Notification.Name("JimmyTweaks.permissionsChanged")
    static let loggingChanged = Notification.Name("JimmyTweaks.loggingChanged")
    static let iconAbsorberChanged = Notification.Name("JimmyTweaks.iconAbsorberChanged")
    static let santaRequested = Notification.Name("JimmyTweaks.santaRequested")
    static let yetiRequested = Notification.Name("JimmyTweaks.yetiRequested")
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

enum WindowEffect: String, CaseIterable {
    case iridescentEnergy, furiousLightning, emberFlame, blueMist, auroraVeil, starlightSwirl, cartoonWind, none, crystalFrost

    static let resizeOptions: [WindowEffect] = [.none, .iridescentEnergy, .furiousLightning, .emberFlame, .crystalFrost]
    static let moveOptions: [WindowEffect] = [.none, .blueMist, .auroraVeil, .starlightSwirl, .cartoonWind]
    var title: String {
        switch self {
        case .iridescentEnergy: return "Iridescent Energy"
        case .furiousLightning: return "Furious Lightning"
        case .emberFlame: return "Ember Flame"
        case .blueMist: return "Blue Mist"
        case .auroraVeil: return "Aurora Veil"
        case .starlightSwirl: return "Starlight Swirl"
        case .cartoonWind: return "Cartoon Wind"
        case .crystalFrost: return "Crystal Frost"
        case .none: return "No Effect"
        }
    }
    var shaderStyle: Float { Float(Self.allCases.firstIndex(of: self)!) }
}

enum StaticEffect: String, CaseIterable {
    case none, rain, fireflies, snowStorm, fireStorm
    var title: String {
        switch self {
        case .none: return "No Effect"
        case .rain: return "Rain"
        case .fireflies: return "Fireflies"
        case .snowStorm: return "Snow Storm"
        case .fireStorm: return "Fire Storm"
        }
    }
    var options: [(String, PreferenceKey)] {
        switch self {
        case .none: return []
        case .rain: return [("Rainfall amount", .rainAmount), ("Fall speed", .rainSpeed),
                            ("Drop size", .rainSize), ("Splash frequency", .rainSplashFrequency)]
        case .fireflies: return [("Firefly amount", .fireflyAmount), ("Drift speed", .fireflySpeed), ("Glow size", .fireflySize)]
        case .snowStorm: return [("Snowfall intensity", .stormSnowfall), ("Maximum flake size", .stormFlakeSize), ("Wind gusts", .stormGusts)]
        case .fireStorm: return [("Ember density", .fireEmberDensity), ("Storm speed", .fireStormSpeed),
                                ("Flame height", .fireFlameHeight), ("Wind strength", .fireWindStrength),
                                ("Window ignition", .fireIgnitionChance)]
        }
    }
}

enum PreferenceKey: String, CaseIterable {
    case staticEffect = "visualEffects.static.effect"
    case stormSnowfall = "visualEffects.static.snowStorm.snowfall"
    case stormFlakeSize = "visualEffects.static.snowStorm.flakeSize"
    case stormGusts = "visualEffects.static.snowStorm.gusts"
    case stormBehindWindows = "visualEffects.static.snowStorm.behindWindows"
    case stormFireplace = "visualEffects.static.snowStorm.fireplace"
    case stormFireplaceWidth = "visualEffects.static.snowStorm.fireplaceWidth"
    case stormFireplaceHeight = "visualEffects.static.snowStorm.fireplaceHeight"
    case stormFireplaceOffset = "visualEffects.static.snowStorm.fireplaceOffset"
    case stormDecorations = "visualEffects.static.snowStorm.decorations"
    case stormLights = "visualEffects.static.snowStorm.lights"
    case rainAmount = "visualEffects.static.rain.amount"
    case rainSpeed = "visualEffects.static.rain.speed"
    case rainSize = "visualEffects.static.rain.size"
    case rainSplashFrequency = "visualEffects.static.rain.splashFrequency"
    case fireflyAmount = "visualEffects.static.fireflies.amount"
    case fireflySpeed = "visualEffects.static.fireflies.speed"
    case fireflySize = "visualEffects.static.fireflies.size"
    case fireEmberDensity = "visualEffects.static.fireStorm.emberDensity"
    case fireStormSpeed = "visualEffects.static.fireStorm.speed"
    case fireFlameHeight = "visualEffects.static.fireStorm.flameHeight"
    case fireWindStrength = "visualEffects.static.fireStorm.windStrength"
    case fireIgnitionChance = "visualEffects.static.fireStorm.ignitionChance"
    case fireSmoke = "visualEffects.static.fireStorm.smoke"
    case fireAsh = "visualEffects.static.fireStorm.ash"
    case fireHeatGlow = "visualEffects.static.fireStorm.heatGlow"
    case shortcutsEnabled = "customShortcuts.enabled"
    case suspended = "global.suspendAll"
    case enabled = "windowResizer.enabled"
    case resizeEnabled = "windowResizer.resizeEnabled"
    case activation = "windowResizer.resizeActivation"
    case resizeThreshold = "windowResizer.resizeThresholdPoints"
    // Retain the stored key so existing corner-size choices become the shared edge size.
    case edgeZoneSize = "windowResizer.cornerSizePoints"
    case moveEnabled = "windowResizer.moveEnabled"
    case moveThreshold = "windowResizer.moveThresholdPoints"
    case cursor = "windowResizer.changeCursor"
    case hints = "windowResizer.showCornerHints"
    case outline = "windowResizer.showWindowOutline"
    case animatedEffects = "windowResizer.animatedEffects"
    case resizeEffect = "windowResizer.resizeEffect"
    case moveEffect = "windowResizer.moveEffect"
    case normalWindowEffects = "windowResizer.normalWindowEffects"
    case loginRequested = "general.launchAtLoginRequested"
    case showMenuBarIcon = "general.showMenuBarIcon"
    case menuBarAudio = "general.menuBarAudio"
    case iconAbsorberEnabled = "iconAbsorber.enabled"
    case iconAbsorberHiddenPress = "iconAbsorber.hiddenPress"
    case iconAbsorberPositionPanels = "iconAbsorber.positionPanels"

    var defaultValue: Any {
        switch self {
        case .staticEffect: return StaticEffect.none.rawValue
        case .fireIgnitionChance: return 15
        case .fireWindStrength: return 0
        case .rainAmount, .rainSpeed, .rainSize, .rainSplashFrequency, .fireflyAmount, .fireflySpeed, .fireflySize, .stormSnowfall, .stormFlakeSize, .stormGusts, .stormFireplaceWidth, .fireEmberDensity, .fireStormSpeed, .fireFlameHeight: return 50
        case .stormFireplaceHeight: return 158
        case .stormFireplaceOffset: return 0
        case .shortcutsEnabled, .suspended, .outline, .normalWindowEffects, .loginRequested, .iconAbsorberEnabled, .iconAbsorberHiddenPress, .menuBarAudio, .stormBehindWindows, .stormFireplace, .stormDecorations, .stormLights, .fireAsh: return false
        case .fireSmoke, .fireHeatGlow: return true
        case .iconAbsorberPositionPanels: return true
        case .enabled, .resizeEnabled, .moveEnabled, .cursor, .hints, .animatedEffects, .showMenuBarIcon: return true
        case .activation: return "immediate"
        case .resizeEffect: return WindowEffect.iridescentEnergy.rawValue
        case .moveEffect: return WindowEffect.blueMist.rawValue
        case .resizeThreshold, .moveThreshold: return 5
        case .edgeZoneSize: return 200
        }
    }
    var range: ClosedRange<Int>? {
        switch self {
        case .rainAmount, .rainSpeed, .rainSize, .fireflyAmount, .fireflySpeed, .fireflySize, .stormSnowfall, .stormFlakeSize, .stormGusts, .fireEmberDensity, .fireStormSpeed, .fireFlameHeight: return 1...100
        case .fireWindStrength, .rainSplashFrequency, .fireIgnitionChance: return 0...100
        case .stormFireplaceWidth: return 30...80
        case .stormFireplaceHeight: return 80...320
        case .stormFireplaceOffset: return -100...100
        case .resizeThreshold, .moveThreshold: return 1...30
        case .edgeZoneSize: return 8...400
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
    var edgeZoneSize = 200.0
    var changeCursor = true
    var cornerHints = true
    var outline = false
    var animatedEffects = true
    var normalWindowEffects = false
    var resizeEffect: WindowEffect = .iridescentEnergy
    var moveEffect: WindowEffect = .blueMist
    var anyGesture: Bool { enabled && (resizeEnabled || moveEnabled) }
    var normalWindowEffectsActive: Bool { normalWindowEffects && animatedEffects && (resizeEffect != .none || moveEffect != .none) }
    func effect(for kind: GestureKind) -> WindowEffect { kind == .move ? moveEffect : resizeEffect }
    func effectsEnabled(for kind: GestureKind) -> Bool { effect(for: kind) != .none }
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
        if !newerSchema {
            // The old switches become the No Effect choices once, before the
            // new defaults are registered. A disabled saved effect stays off.
            for (legacy, selection) in [("windowResizer.resizeEffectsEnabled", PreferenceKey.resizeEffect),
                                        ("windowResizer.moveEffectsEnabled", PreferenceKey.moveEffect)] {
                if let enabled = defaults.object(forKey: legacy) as? Bool, !enabled {
                    defaults.set(WindowEffect.none.rawValue, forKey: selection.rawValue)
                }
                defaults.removeObject(forKey: legacy)
            }
        }
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
        if key == .resizeEffect || key == .moveEffect {
            let options = key == .resizeEffect ? WindowEffect.resizeOptions : WindowEffect.moveOptions
            guard let raw = raw as? String, let effect = WindowEffect(rawValue: raw), options.contains(effect) else { return key.defaultValue }
            return effect.rawValue
        }
        if key == .staticEffect {
            if raw as? String == "snowfall" { return StaticEffect.snowStorm.rawValue }
            return (raw as? String).flatMap(StaticEffect.init(rawValue:))?.rawValue ?? key.defaultValue
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
    var staticEffect: StaticEffect { StaticEffect(rawValue: string(.staticEffect)) ?? .none }
    func set(_ value: Any, for key: PreferenceKey) {
        defaults.set(normalized(value, key: key), forKey: key.rawValue)
        changed()
    }
    func requestSanta() { NotificationCenter.default.post(name: .santaRequested, object: self) }
    func requestYeti() { NotificationCenter.default.post(name: .yetiRequested, object: self) }
    var gesture: GesturePreferences {
        GesturePreferences(enabled: bool(.enabled), resizeEnabled: bool(.resizeEnabled), moveEnabled: bool(.moveEnabled),
            immediateResize: string(.activation) == "immediate", resizeThreshold: Double(int(.resizeThreshold)),
            moveThreshold: Double(int(.moveThreshold)), edgeZoneSize: Double(int(.edgeZoneSize)),
            changeCursor: bool(.cursor), cornerHints: bool(.hints), outline: bool(.outline), animatedEffects: bool(.animatedEffects),
            normalWindowEffects: bool(.normalWindowEffects),
            resizeEffect: WindowEffect(rawValue: string(.resizeEffect)) ?? .iridescentEnergy,
            moveEffect: WindowEffect(rawValue: string(.moveEffect)) ?? .blueMist)
    }
    var needsAssistant: Bool { defaults.string(forKey: "onboarding.assistantDisposition") == "notStarted" }
    func finishAssistant(skipped: Bool) {
        defaults.set(1, forKey: "onboarding.assistantVersion")
        defaults.set(skipped ? "skipped" : "completed", forKey: "onboarding.assistantDisposition")
    }
    func resetWindow() { reset(keys: PreferenceKey.allCases.filter { $0.rawValue.hasPrefix("windowResizer.") }) }
    func resetAll() {
        defaults.removeObject(forKey: "iconAbsorber.applications")
        defaults.removeObject(forKey: "customShortcuts.definitions")
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
