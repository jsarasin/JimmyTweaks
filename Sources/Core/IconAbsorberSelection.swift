import Foundation

/// Application ordering is independent of live status items and preview rendering.
struct IconAbsorberSelection: Equatable {
    private(set) var bundles: [String]
    init(_ values: [String] = [], excluding ownBundle: String = "local.jimmytweaks.app") {
        var seen = Set<String>()
        bundles = values.filter {
            !$0.isEmpty && $0.count <= 255 && $0.contains(".") && !$0.hasPrefix("com.apple.") && $0 != ownBundle
                && $0.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_" )).inverted) == nil
                && seen.insert($0).inserted
        }
    }
    mutating func select(_ bundle: String, selected: Bool) {
        if selected { self = Self(bundles + [bundle]) }
        else { bundles.removeAll { $0 == bundle } }
    }
    mutating func move(_ bundle: String, before next: String?) {
        guard bundles.contains(bundle), bundle != next, next == nil || bundles.contains(next!) else { return }
        bundles.removeAll { $0 == bundle }
        bundles.insert(bundle, at: next.flatMap { bundles.firstIndex(of: $0) } ?? bundles.count)
    }
}
