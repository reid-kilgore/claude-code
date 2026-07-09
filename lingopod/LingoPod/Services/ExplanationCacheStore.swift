// M6
// `ModelActor` wrapping SwiftData CRUD for `ExplanationCacheEntry`
// (docs/specs/M6-explain.md §0.1, §5; architecture §11.2, §11.6). No
// `FoundationModels` import — this file is pure SwiftData plumbing, part of
// M6's "framework calls stay in one thin file" seam (M6-explain.md §0.1).
//
// Callers never receive the live `@Model` `ExplanationCacheEntry` across the
// actor boundary: `ExplanationCacheEntry` is a SwiftData model class and is
// not `Sendable`, so handing one from this actor to `ExplainService`
// (`@MainActor`) would violate architecture §7's "everything crossing
// module/actor boundaries is Sendable, never live `@Model` objects" rule.
// Instead this store exposes/accepts the plain `Sendable` value type
// `ExplanationCacheRecord`.
import Foundation
import SwiftData
import LingoPodKit

/// Sendable snapshot of an `ExplanationCacheEntry` row, safe to pass across
/// the actor boundary into `@MainActor`-isolated `ExplainService`.
struct ExplanationCacheRecord: Sendable {
    let key: String
    let passage: String
    let explanationJSON: Data
    let createdAt: Date
}

@ModelActor
actor ExplanationCacheStore {

    /// Looks up a cached explanation by its §5.1 cache key. Returns `nil`
    /// on a miss (including "not found" — callers use `try?` at the call
    /// site per M6-explain.md §5.2, so any thrown error is also treated as
    /// a miss and falls through to the normal generation path).
    func fetch(key: String) throws -> ExplanationCacheRecord? {
        guard let entry = try fetchEntry(key: key) else {
            return nil
        }
        return ExplanationCacheRecord(
            key: entry.key,
            passage: entry.passage,
            explanationJSON: entry.explanationJSON,
            createdAt: entry.createdAt
        )
    }

    /// Write-through on a successful (non-cached, still-current)
    /// generation (M6-explain.md §5.4). Updates in place if `key` already
    /// exists (e.g. a race between two in-flight requests for the same
    /// passage/context/language pair), otherwise inserts a new row.
    func upsert(key: String, passage: String, explanationJSON: Data, createdAt: Date = .now) throws {
        if let existing = try fetchEntry(key: key) {
            existing.passage = passage
            existing.explanationJSON = explanationJSON
            existing.createdAt = createdAt
        } else {
            modelContext.insert(
                ExplanationCacheEntry(key: key, passage: passage, explanationJSON: explanationJSON, createdAt: createdAt)
            )
        }
        try modelContext.save()
    }

    private func fetchEntry(key: String) throws -> ExplanationCacheEntry? {
        var descriptor = FetchDescriptor<ExplanationCacheEntry>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
