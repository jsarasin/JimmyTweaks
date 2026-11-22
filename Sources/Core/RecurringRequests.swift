import Foundation

struct RequestHeader: Codable, Equatable {
    var name: String
    var value: String
}

enum RequestBodyKind: String, Codable, CaseIterable { case none = "None", json = "JSON", text = "Text" }

enum RequestSchedule: Codable, Equatable {
    case manual
    case interval(minutes: Int)
    case daily(hour: Int, minute: Int)

    var isValid: Bool {
        switch self {
        case .manual: return true
        case .interval(let minutes): return (1...525_600).contains(minutes)
        case .daily(let hour, let minute): return (0...23).contains(hour) && (0...59).contains(minute)
        }
    }
    func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        switch self {
        case .manual: return nil
        case .interval(let minutes): return date.addingTimeInterval(Double(minutes) * 60)
        case .daily(let hour, let minute):
            // Advance past this entire local day if its first occurrence already passed.
            // This prevents a second execution in the repeated hour at fall-back.
            let today = calendar.startOfDay(for: date)
            let match = DateComponents(hour: hour, minute: minute, second: 0)
            if let candidate = calendar.nextDate(after: today.addingTimeInterval(-1), matching: match,
                                                  matchingPolicy: .nextTime, repeatedTimePolicy: .first), candidate > date {
                return candidate
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return calendar.nextDate(after: tomorrow.addingTimeInterval(-1), matching: match,
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }
    }
}

struct RequestDefinition: Codable, Equatable, Identifiable {
    static let methods = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    var id = UUID()
    var name = "New Request"
    var url = ""
    var method = "GET"
    var headers: [RequestHeader] = []
    var bodyKind = RequestBodyKind.none
    var body = ""
    var schedule = RequestSchedule.manual
    var enabled = false
    var allowsBody: Bool { method != "GET" && method != "HEAD" }

    static func validURL(_ text: String) -> Bool {
        guard text.count <= 2048, !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.url != nil else { return false }
        return parts.port.map { (1...65535).contains($0) } ?? true
    }
    var validationError: String? {
        guard (1...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) else { return "Use a name between 1 and 80 characters." }
        guard Self.validURL(url) else { return "Enter an HTTP or HTTPS URL with a host, no credentials, spaces, or fragment, and at most 2,048 characters." }
        guard Self.methods.contains(method) else { return "Choose a supported HTTP method." }
        guard schedule.isValid else { return "Use an interval of 1–525,600 minutes or a valid daily time." }
        guard headers.count <= 100, headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 65_536 else { return "Headers must fit within 64 KiB and 100 rows." }
        var seen = Set<String>()
        let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for header in headers {
            guard !header.name.isEmpty, header.name.unicodeScalars.allSatisfy({ tokens.contains($0) }),
                  !header.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0.value != 9 }) else {
                return "Use valid header names and values without line breaks or control characters."
            }
            guard seen.insert(header.name.lowercased()).inserted else { return "Combine duplicate header names into one row." }
            if ["host", "content-length", "transfer-encoding", "connection"].contains(header.name.lowercased()) {
                return "Host, Content-Length, Transfer-Encoding, and Connection are managed automatically."
            }
        }
        guard body.utf8.count <= 1_048_576 else { return "Request bodies must be at most 1 MiB." }
        if allowsBody && bodyKind == .json {
            guard let data = body.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil else { return "Enter a valid JSON body." }
        }
        return nil
    }
}

struct RequestRun: Codable, Identifiable {
    var id = UUID()
    var requestID: UUID
    var name: String
    var started: Date
    var duration: TimeInterval
    var statusCode: Int?
    var outcome: String
    var headers: [RequestHeader] = []
    var body = Data()
    var truncated = false
}

struct RequestState: Codable {
    var version = 1
    var enabled = false
    var requests: [RequestDefinition] = []
    var history: [RequestRun] = []
    var lastDailyRuns: [String: Date] = [:]
}

enum RequestError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

/// A nil directory is an explicitly isolated, memory-only store for tests.
final class RequestStore {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.jimmytweaks.app", isDirectory: true)
            .appendingPathComponent("RecurringRequests", isDirectory: true)
    }
    let directory: URL?
    private(set) var state = RequestState()
    private(set) var loadError: String?
    init(directory: URL? = nil) {
        self.directory = directory
        guard let directory else { return }
        let url = directory.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 32 * 1_048_576 else { throw RequestError.message("Request data is too large.") }
            let decoded = try JSONDecoder().decode(RequestState.self, from: Data(contentsOf: url))
            guard decoded.version == 1, Set(decoded.requests.map(\.id)).count == decoded.requests.count else {
                throw RequestError.message("Unsupported or invalid request data.")
            }
            state = decoded
            state.history = Array(state.history.prefix(100))
            for index in state.history.indices {
                if state.history[index].body.count > 65_536 { state.history[index].body = Data(state.history[index].body.prefix(65_536)); state.history[index].truncated = true }
            }
        } catch { loadError = "Saved requests could not be loaded. Reset Recurring Requests to replace the saved data." }
    }
    func update(replacingUnreadableData: Bool = false, _ change: (inout RequestState) -> Void) throws {
        guard loadError == nil || replacingUnreadableData else { throw RequestError.message(loadError!) }
        var candidate = state; change(&candidate)
        candidate.history = Array(candidate.history.prefix(100))
        if let directory {
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let data = try JSONEncoder().encode(candidate)
                guard data.count <= 32 * 1_048_576 else { throw RequestError.message("Request data exceeds the 32 MiB storage limit.") }
                let file = directory.appendingPathComponent("state.json")
                try data.write(to: file, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { throw RequestError.message("Could not save request data. Check available disk space and folder access.") }
        }
        state = candidate; loadError = nil
    }
}
