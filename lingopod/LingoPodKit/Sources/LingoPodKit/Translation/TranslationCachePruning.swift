// M5
// Pure logic, no SwiftData import — `TranslationCacheStore` (app target,
// LingoPod/Services/) projects `TranslationCacheEntry` rows down to
// `(key, createdAt)` tuples and calls this. See
// docs/specs/M5-translation.md §6.3.
import Foundation

public enum TranslationCachePruning {
    /// Given all entries' (key, createdAt), returns the keys to delete so
    /// the store drops from `cap` back down to `target`, oldest-createdAt-
    /// first. Returns [] if `entries.count <= cap`.
    public static func keysToEvict(
        entries: [(key: String, createdAt: Date)],
        cap: Int = 5000,
        target: Int = 4500
    ) -> [String] {
        guard entries.count > cap else { return [] }
        let evictCount = entries.count - target
        return entries
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(evictCount)
            .map(\.key)
    }
}
