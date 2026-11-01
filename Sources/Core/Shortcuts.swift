import Foundation

struct ShortcutCombination: Codable, Hashable {
    enum Input: String, Codable { case key, mouse }
    var input: Input
    var code: UInt16
    var modifiers: UInt64
    var keyLabel: String = ""
    static let modifierMask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
    static let command: UInt64 = 1 << 20
    init(input: Input, code: UInt16, modifiers: UInt64, keyLabel: String = "") {
        self.input = input; self.code = code; self.modifiers = modifiers & Self.modifierMask; self.keyLabel = keyLabel
    }
    static func == (a: Self, b: Self) -> Bool { a.input == b.input && a.code == b.code && a.modifiers == b.modifiers }
    func hash(into hasher: inout Hasher) { hasher.combine(input); hasher.combine(code); hasher.combine(modifiers) }
    var validationError: String? {
        if input == .mouse { return code > 31 ? "This mouse button is unavailable." : nil }
        if code == 53 { return "Escape is reserved for cancellation." }
        if [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code) { return "Choose a key as well as modifiers." }
        if modifiers == 0 && ![122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90,115,119,116,121,123,124,125,126].contains(code) {
            return "Ordinary typing keys need a modifier for a global shortcut."
        }
        return nil
    }
    var needsTransparent: Bool { input == .mouse && code < 2 && modifiers == 0 }
    var display: String {
        let flags: [(UInt64, String)] = [(1 << 18,"⌃"),(1 << 19,"⌥"),(1 << 17,"⇧"),(1 << 20,"⌘"),(1 << 23,"fn"),(1 << 16,"⇪")]
        let prefix = flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined(separator: " ")
        let names: [UInt16: String] = [36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"↖",119:"↘",116:"⇞",121:"⇟",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        let suffix = input == .mouse ? ([0:"Left Click",1:"Right Click",2:"Middle Click"][Int(code)] ?? "Mouse Button \(Int(code) + 1)") : (names[code] ?? (keyLabel.isEmpty ? "Key \(code)" : keyLabel.uppercased()))
        return prefix.isEmpty ? suffix : prefix + (input == .mouse ? " + " : " ") + suffix
    }
}
enum ShortcutMode: String, Codable { case transparent = "Transparent", absorbing = "Absorbing" }
enum ShortcutActivation: String, Codable { case press = "Press", release = "Release" }
struct ShortcutScope: Codable, Equatable { var applicationBundleID: String? = nil }
struct ShortcutActionInstance: Codable, Equatable, Identifiable {
    var id = UUID()
    var actionID: String
    var parameters: [String: String] = [:]
}
struct ShortcutDefinition: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "New Shortcut"
    var enabled = true
    var combination: ShortcutCombination?
    var mode: ShortcutMode = .absorbing
    var activation: ShortcutActivation = .press
    var scope = ShortcutScope()
    var actions: [ShortcutActionInstance] = []
    var configured: Bool { combination != nil && !actions.isEmpty }
}
enum ShortcutConflictChecker {
    static func error(for shortcut: ShortcutDefinition, among shortcuts: [ShortcutDefinition], gestures: GesturePreferences) -> String? {
        guard let combination = shortcut.combination else { return nil }
        if let error = combination.validationError { return error }
        if combination.needsTransparent && shortcut.mode == .absorbing { return "Unmodified left and right clicks require Transparent mode. Choose Transparent or record another combination." }
        if let other = shortcuts.first(where: { $0.id != shortcut.id && $0.combination == combination }) { return "Already assigned to “\(other.name)”." }
        if gestures.enabled && combination.input == .mouse && combination.modifiers == ShortcutCombination.command && ((combination.code == 0 && gestures.moveEnabled) || (combination.code == 1 && gestures.resizeEnabled)) {
            return "Conflicts with Window Resizer’s Command + \(combination.code == 0 ? "left" : "right") mouse gesture. Disable that gesture or choose another combination."
        }
        if shortcut.scope.applicationBundleID != nil { return "Application-specific shortcuts are not supported yet." }
        return nil
    }
}

/// Pure press/release state. Retain an absorbed press until its release, even after settings change.
struct ShortcutMatcher {
    struct Press { let combination: ShortcutCombination; let shortcut: ShortcutDefinition?; let excluded: Bool; let absorbed: Bool }
    struct Result { var suppress = false; var activation: ShortcutDefinition? }
    private var presses: [String: Press] = [:]
    private func identity(_ combination: ShortcutCombination) -> String { "\(combination.input.rawValue):\(combination.code)" }
    func isTracking(_ combination: ShortcutCombination) -> Bool { presses[identity(combination)] != nil }
    var hasAbsorbedPress: Bool { presses.values.contains { $0.absorbed } }
    mutating func handle(_ combination: ShortcutCombination, down: Bool, repeating: Bool = false, excluded: Bool = false, shortcuts: [ShortcutDefinition]) -> Result {
        let key = identity(combination)
        if down {
            if let existing = presses[key] { return Result(suppress: existing.absorbed) }
            guard !repeating else { return Result() }
            let match = excluded ? nil : shortcuts.first { $0.enabled && $0.combination == combination }
            guard let match = match else { return Result() }
            let press = Press(combination: combination, shortcut: match, excluded: excluded, absorbed: match.mode == .absorbing)
            presses[key] = press
            return Result(suppress: press.absorbed, activation: match.activation == .press ? match : nil)
        }
        guard let press = presses.removeValue(forKey: key) else { return Result() }
        // Match the modifiers from the initiating press, never the possibly changed release flags.
        let match = press.shortcut.flatMap { original in shortcuts.first { $0.id == original.id && $0 == original } }
        return Result(suppress: press.absorbed, activation: !excluded && !press.excluded && match?.activation == .release ? match : nil)
    }
    func absorbsDrag(button: UInt16) -> Bool { presses["mouse:\(button)"]?.absorbed == true }
    mutating func cancelActivations() {
        presses = presses.mapValues { Press(combination: $0.combination, shortcut: nil, excluded: true, absorbed: $0.absorbed) }
    }
    mutating func discardReleased(_ isPressed: (ShortcutCombination.Input, UInt16) -> Bool) {
        presses = presses.filter { isPressed($0.value.combination.input, $0.value.combination.code) }
    }
    mutating func reset() { presses.removeAll() }
}

extension PreferenceStore {
    var shortcuts: [ShortcutDefinition] {
        get {
            guard let data = defaults.object(forKey: "customShortcuts.definitions") as? Data, let definitions = try? JSONDecoder().decode([ShortcutDefinition].self, from: data) else { return [] }
            // Malformed identities must not allow two executions sharing the same cancellation slot.
            var seen = Set<UUID>()
            return definitions.filter { seen.insert($0.id).inserted }
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: "customShortcuts.definitions")
            NotificationCenter.default.post(name: .preferencesChanged, object: self)
        }
    }
}
