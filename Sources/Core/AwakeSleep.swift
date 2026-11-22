import Foundation

enum PowerAction: String, CaseIterable {
    case keepAwake, sleep, shutDown
    var title: String {
        switch self {
        case .keepAwake: return "Keep Awake"
        case .sleep: return "Sleep After"
        case .shutDown: return "Shut Down After"
        }
    }
    var presets: [Int] { self == .keepAwake ? [30, 60, 120, 180, 300] : [1, 5, 10, 30, 60, 180, 300, 600] }
    static func durationTitle(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) \(minutes == 60 ? "hour" : "hours")" : "\(minutes) minutes"
    }
    static func duration(hours: String, minutes: String) -> TimeInterval? {
        guard let h = UInt64(hours.trimmingCharacters(in: .whitespaces)),
              let m = UInt64(minutes.trimmingCharacters(in: .whitespaces)), m < 60 else { return nil }
        let (hoursInMinutes, overflow) = h.multipliedReportingOverflow(by: 60)
        let (total, additionOverflow) = hoursInMinutes.addingReportingOverflow(m)
        // Retain whole-second precision, and never overflow DispatchTime arithmetic.
        guard !overflow, !additionOverflow, total > 0, total <= UInt64(Int64.max / 60_000_000_000) else { return nil }
        return Double(total) * 60
    }
}

struct PowerSession: Equatable {
    let id: UUID
    let action: PowerAction
    let deadline: TimeInterval?
    let duration: TimeInterval?
    func remaining(at now: TimeInterval) -> TimeInterval? { deadline.map { max(0, $0 - now) } }
}

enum AwakeSleepError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

/// The privileged helper's lease/rollback logic is independent of XPC and pmset.
/// Every method is called on one serial queue. A journal is written BEFORE changing power settings.
final class ClosedLidLease {
    private let read: () throws -> Bool
    private let write: (Bool) throws -> Void
    private let journal: (Bool?) throws -> Void
    private let now: () -> TimeInterval
    private(set) var owner: String?
    private(set) var original: Bool?
    private var expiry: TimeInterval = 0
    init(read: @escaping () throws -> Bool, write: @escaping (Bool) throws -> Void,
         journal: @escaping (Bool?) throws -> Void, now: @escaping () -> TimeInterval) {
        self.read = read; self.write = write; self.journal = journal; self.now = now
    }
    func recover(original: Bool) throws { self.original = original; try release() }
    func acquire(owner: String) throws {
        guard self.owner == nil || self.owner == owner else { throw AwakeSleepError.message("Another user already owns the closed-lid session.") }
        if self.owner == owner { try renew(owner: owner); return }
        if original != nil { try release() }
        let baseline = try read()
        try journal(baseline)
        original = baseline
        do { if !baseline { try write(true) } }
        catch { try? release(); throw error }
        self.owner = owner; expiry = now() + 20
    }
    func renew(owner: String) throws {
        guard self.owner == owner else { throw AwakeSleepError.message("The closed-lid session expired. Start a new session.") }
        // Power-adapter transitions can clear SleepDisabled on Apple silicon.
        if try !read() { try write(true) }
        expiry = now() + 20
    }
    func release(owner: String) throws {
        guard self.owner == owner else { return }
        try release()
    }
    func release() throws {
        owner = nil
        guard let original else { return }
        // If another utility already cleared the override, leave its value alone.
        if try read(), !original { try write(false) }
        try journal(nil)
        self.original = nil
    }
    func tick() throws {
        if original != nil && (owner == nil || now() >= expiry) { try release() }
    }
}
