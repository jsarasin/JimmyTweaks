import Foundation

struct SampleScript {
    var id: String
    var name: String
    var url: String
    var interval: String
    var enabled = false
}
struct SampleHistory {
    let time: String
    let name: String
    let result: String
    let duration: String
}
/// Deliberately only an in-memory view model: no clocks, networking, processes, or execution hooks.
final class ScriptsPreview {
    static let intervals = ["Every 5 minutes", "Every 30 minutes", "Every 1 hour", "Every 6 hours", "Every day"]
    var enabled = false
    var scripts: [SampleScript] = []
    var history: [SampleHistory] = []
    init() { reset() }
    func reset() {
        enabled = false
        scripts = [
            SampleScript(id: "sample.cleanup", name: "Temporary File Cleanup", url: "https://example.com/scripts/cleanup.sh", interval: "Every 1 hour"),
            SampleScript(id: "sample.backup", name: "Notes Backup", url: "https://example.org/scripts/backup.sh", interval: "Every 6 hours"),
            SampleScript(id: "sample.health", name: "System Health Check", url: "https://example.net/scripts/health-check.sh", interval: "Every 30 minutes")
        ]
        history = [SampleHistory(time: "Example day · 09:00", name: "Temporary File Cleanup", result: "Sample success", duration: "0.4 seconds"),
                   SampleHistory(time: "Example day · 08:30", name: "System Health Check", result: "Sample failure", duration: "1.2 seconds"),
                   SampleHistory(time: "Example day · 06:00", name: "Notes Backup", result: "Sample skipped", duration: "—")]
    }
    static func validURL(_ text: String) -> Bool {
        guard text.count <= 2048, let c = URLComponents(string: text), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        return true
    }
    func add() -> String {
        let id = "preview.\(UUID().uuidString)"
        scripts.append(SampleScript(id: id, name: "New Sample", url: "https://example.com/scripts/sample.sh", interval: "Every 1 hour"))
        return id
    }
    func duplicate(_ id: String) -> String? {
        guard var row = scripts.first(where: { $0.id == id }) else { return nil }
        row.id = "preview.\(UUID().uuidString)"; row.name = String((row.name + " Copy").prefix(80))
        scripts.append(row); return row.id
    }
}
