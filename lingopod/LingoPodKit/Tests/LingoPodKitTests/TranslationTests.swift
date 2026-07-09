// M5
// Real, `swift test`-runnable unit tests for the pure logic in
// Sources/LingoPodKit/Translation/ (architecture §9). Both
// TranslationCacheKey and TranslationCachePruning are covered here in one
// file per the M5 task brief (the spec's §7 file layout suggests splitting
// into two files; kept as one here since both are small and tightly
// related — not a behavioral deviation, just file organization).
import Foundation
import Testing
@testable import LingoPodKit

// MARK: - TranslationCacheKey

@Test func normalizeLowercasesAndNFCNormalizes() {
    // Combining-character vs. precomposed accented input should produce
    // the same normalized output.
    let precomposed = "café" // é as U+00E9
    let decomposed = "cafe\u{0301}" // e + combining acute accent
    #expect(TranslationCacheKey.normalize(precomposed) == TranslationCacheKey.normalize(decomposed))
    #expect(TranslationCacheKey.normalize("CAFÉ") == TranslationCacheKey.normalize("café"))
}

@Test func normalizeTrimsEndsButKeepsInternalPunctuation() {
    #expect(TranslationCacheKey.normalize("Wie geht's?") == "wie geht's")
    #expect(TranslationCacheKey.normalize("¿Cómo estás?") == "cómo estás")
}

@Test func normalizeCollapsesWhitespaceRuns() {
    #expect(TranslationCacheKey.normalize("hello   world") == "hello world")
    #expect(TranslationCacheKey.normalize("hello\n\n world") == "hello world")
    #expect(TranslationCacheKey.normalize("  hello  world  ") == "hello world")
}

@Test func makeProducesExactFormat() {
    let key = TranslationCacheKey.make(text: "  Hello World!  ", source: "en", target: "fr")
    #expect(key == "en|fr|hello world")
}

// MARK: - TranslationCachePruning

@Test func pruningUnderCapReturnsEmpty() {
    let entries = (0..<10).map { (key: "k\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
    let evicted = TranslationCachePruning.keysToEvict(entries: entries, cap: 5000, target: 4500)
    #expect(evicted.isEmpty)
}

@Test func pruningOverCapEvictsOldestFirst() {
    // 5001 entries, cap 5000, target 4500 -> evict 501, oldest createdAt first.
    let entries = (0..<5001).map { (key: "k\($0)", createdAt: Date(timeIntervalSince1970: Double($0))) }
    let evicted = TranslationCachePruning.keysToEvict(entries: entries, cap: 5000, target: 4500)

    #expect(evicted.count == 501)

    let evictedSet = Set(evicted)
    let expectedOldest = Set((0..<501).map { "k\($0)" })
    #expect(evictedSet == expectedOldest)

    // Disjoint from the newest `target` (4500) entries.
    let newestKeys = Set((501..<5001).map { "k\($0)" })
    #expect(evictedSet.isDisjoint(with: newestKeys))
}

@Test func pruningWithTiedCreatedAtDoesNotCrashAndReturnsExpectedCount() {
    // All entries share the same createdAt; ordering among ties is
    // unspecified, but count and "some N oldest" behavior must still hold.
    let sharedDate = Date(timeIntervalSince1970: 0)
    let entries = (0..<5010).map { (key: "k\($0)", createdAt: sharedDate) }
    let evicted = TranslationCachePruning.keysToEvict(entries: entries, cap: 5000, target: 4500)
    #expect(evicted.count == 510)
    // All evicted keys must have come from the original entry set.
    let allKeys = Set(entries.map(\.key))
    #expect(Set(evicted).isSubset(of: allKeys))
}
