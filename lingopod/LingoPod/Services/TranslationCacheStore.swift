// M5
// App-target service implementation needing a SwiftData ModelActor
// (architecture §11.2: "New directory LingoPod/Services/ ... translation/
// explanation cache stores"). Placed here rather than under
// LingoPod/Intelligence/ per that reconciliation note, which supersedes
// docs/specs/M5-translation.md §7's file-layout listing (this file is a
// deliberate, documented placement deviation from the spec, not from the
// binding architecture doc). Filename is disjoint from M1's Catalog*/
// Download* files.
import Foundation
import SwiftData
import LingoPodKit
import os

@ModelActor
actor TranslationCacheStore {
    private let logger = Logger(subsystem: "com.lingopod.app", category: "Translation")

    private static let cacheCap = 5000
    private static let cacheTarget = 4500

    func lookup(key: String) async -> String? {
        let descriptor = FetchDescriptor<TranslationCacheEntry>(
            predicate: #Predicate { $0.key == key }
        )
        do {
            return try modelContext.fetch(descriptor).first?.translatedText
        } catch {
            logger.error("cache lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Insert-or-overwrite (key is `@Attribute(.unique)`), then save.
    /// Write-through only — callers translate first, then write; this
    /// method never fabricates a cache entry ahead of a confirmed
    /// translation.
    func store(
        key: String,
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async {
        let descriptor = FetchDescriptor<TranslationCacheEntry>(
            predicate: #Predicate { $0.key == key }
        )
        do {
            if let existing = try modelContext.fetch(descriptor).first {
                existing.sourceText = sourceText
                existing.translatedText = translatedText
                existing.sourceLanguage = sourceLanguage
                existing.targetLanguage = targetLanguage
                existing.createdAt = .now
            } else {
                let entry = TranslationCacheEntry(
                    key: key,
                    sourceText: sourceText,
                    translatedText: translatedText,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                modelContext.insert(entry)
            }
            try modelContext.save()
        } catch {
            logger.error("cache store failed: \(String(describing: error), privacy: .public)")
            return
        }
        await pruneIfNeeded()
    }

    /// Batched pruning: evict down to `cacheTarget` whenever the count
    /// exceeds `cacheCap`, rather than on every single insert (spec §6.3).
    private func pruneIfNeeded() async {
        let descriptor = FetchDescriptor<TranslationCacheEntry>()
        do {
            let all = try modelContext.fetch(descriptor)
            guard all.count > Self.cacheCap else { return }

            let projection = all.map { (key: $0.key, createdAt: $0.createdAt) }
            let toEvict = Set(
                TranslationCachePruning.keysToEvict(entries: projection, cap: Self.cacheCap, target: Self.cacheTarget)
            )
            guard !toEvict.isEmpty else { return }

            for entry in all where toEvict.contains(entry.key) {
                modelContext.delete(entry)
            }
            try modelContext.save()
        } catch {
            logger.error("cache prune failed: \(String(describing: error), privacy: .public)")
        }
    }
}
