import Foundation

enum SettingsPage: String, CaseIterable {
    case general, permissions, window, iconAbsorber, shortcuts, scripts, logging, about
    var title: String {
        switch self {
        case .permissions: return "Permissions"
        case .shortcuts: return "Custom Shortcuts"
        case .window: return "Window Resizer"
        case .iconAbsorber: return "Icon Absorber"
        case .scripts: return "Reoccurring Scripts"
        case .general: return "General"
        case .logging: return "Logging"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .permissions: return "lock.shield"
        case .shortcuts: return "keyboard"
        case .window: return "arrow.up.left.and.arrow.down.right"
        case .iconAbsorber: return "menubar.rectangle"
        case .scripts: return "terminal"
        case .general: return "gearshape"
        case .logging: return "doc.plaintext"
        case .about: return "info.circle"
        }
    }
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
enum PermissionEntry: String, CaseIterable {
    case accessibility, inputMonitoring, screenRecording
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        }
    }
    var controlID: String { "permissions.\(rawValue)" }
    var destination: SearchDestination { SearchDestination(page: .permissions, controlID: controlID) }
}
struct SearchDestination {
    var page: SettingsPage
    var controlID: String
    var sampleID: String? = nil
}
struct ControlMetadata {
    let id: String
    let label: String
    let description: String
    let keywords: [String]
    let section: String
    let destination: SearchDestination
    var availability: () -> String? = { nil }
    var value: () -> String? = { nil }
    var breadcrumb: String {
        [destination.page.title, section, label].filter { !$0.isEmpty }.joined(separator: " › ")
    }
}

final class SearchCatalog {
    private(set) var entries: [ControlMetadata] = []
    func register(_ entry: ControlMetadata) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.append(entry) }
    }
    func remove(where predicate: (ControlMetadata) -> Bool) { entries.removeAll(where: predicate) }
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func search(_ query: String) -> [ControlMetadata] {
        let normalized = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let scored: [(Int, Int, ControlMetadata)] = entries.enumerated().compactMap { index, entry in
            let label = Self.normalized(entry.label), description = Self.normalized(entry.description)
            let other = Self.normalized(entry.keywords.joined(separator: " ") + " " + entry.breadcrumb)
            var score = 0
            for token in tokens {
                let tier: Int
                if label == token { tier = 0 }
                else if label.hasPrefix(token) { tier = 1 }
                else if label.contains(token) { tier = 2 }
                else if description.contains(token) { tier = 3 }
                else if other.contains(token) { tier = 4 }
                else { return nil }
                score = max(score, tier)
            }
            if label == normalized { score = -1 }
            return (score, index, entry)
        }
        return scored.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.2.destination.page.order != $1.2.destination.page.order { return $0.2.destination.page.order < $1.2.destination.page.order }
            return $0.1 < $1.1
        }.map(\.2)
    }
}
