import Foundation

final class MemoryDefaults: UserDefaults {
    private var memory: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    init(memoryOnly: Bool = true) { super.init(suiteName: "local.jimmytweaks.isolated-tests")! }
    override func object(forKey defaultName: String) -> Any? { memory[defaultName] ?? registered[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { memory[defaultName] = value }
    override func removeObject(forKey defaultName: String) { memory.removeValue(forKey: defaultName) }
    override func register(defaults registrationDictionary: [String: Any]) { registered.merge(registrationDictionary) { _, new in new } }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
}
