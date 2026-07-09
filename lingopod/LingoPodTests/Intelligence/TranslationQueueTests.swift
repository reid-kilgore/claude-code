// M5
// App-target tests for TranslationService's queue/coalescing logic and
// availability mapping (architecture §9: "framework-touching seams ...
// wrapped in thin protocols and left for on-device verification" — these
// tests exercise everything up to that seam via MockTranslationSession /
// FakeLanguageAvailability / FakeNetworkReachability, never the real
// Translation framework). See docs/specs/M5-translation.md §9.
import Foundation
import SwiftData
import Testing
import LingoPodKit
@testable import LingoPod

// MARK: - Test doubles

/// Records every batch it's asked to translate; responses are computed
/// per-call from the actual request batch (request ids are UUIDs generated
/// internally by TranslationService, unknown ahead of time), so tests can
/// simulate a missing-clientIdentifier response precisely.
actor MockTranslationSession: TranslationSessionProtocol {
    typealias Responder = @Sendable ([PendingTranslationRequest]) -> Result<[String: String], Error>

    private(set) var batches: [[PendingTranslationRequest]] = []
    private var responders: [Responder]
    private let defaultResponder: Responder
    private var callIndex = 0

    init(
        responders: [Responder] = [],
        defaultResponder: @escaping Responder = { requests in
            .success(Dictionary(uniqueKeysWithValues: requests.map { ($0.id.uuidString, "[\($0.text)]") }))
        }
    ) {
        self.responders = responders
        self.defaultResponder = defaultResponder
    }

    var callCount: Int { batches.count }

    func performBatch(_ requests: [PendingTranslationRequest]) async throws -> [String: String] {
        batches.append(requests)
        defer { callIndex += 1 }
        let responder = callIndex < responders.count ? responders[callIndex] : defaultResponder
        switch responder(requests) {
        case .success(let dict): return dict
        case .failure(let error): throw error
        }
    }

    func prepareTranslation() async throws {}
}

struct MockSessionError: Error, Equatable, Sendable {
    let message: String
}

struct FakeLanguageAvailability: LanguageAvailabilityChecking {
    let fixedStatus: LanguageAvailabilityCheckStatus
    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailabilityCheckStatus {
        fixedStatus
    }
}

struct FakeNetworkReachability: NetworkReachabilityChecking {
    let isSatisfied: Bool
}

@MainActor
private func makeCacheStore() throws -> TranslationCacheStore {
    let schema = Schema([TranslationCacheEntry.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return TranslationCacheStore(modelContainer: container)
}

@MainActor
private func makeService(
    availability: LanguageAvailabilityCheckStatus = .installed,
    network: Bool = true
) throws -> TranslationService {
    TranslationService(
        cache: try makeCacheStore(),
        availabilityChecker: FakeLanguageAvailability(fixedStatus: availability),
        networkMonitor: FakeNetworkReachability(isSatisfied: network),
        sleeper: { _ in } // instant: real timing is exercised manually in these tests, not via wall-clock waits
    )
}

private let fr = Locale.Language(identifier: "fr")
private let en = Locale.Language(identifier: "en")
private let es = Locale.Language(identifier: "es")

/// Lets concurrently-issued `translate()` calls settle into the queue
/// before a queue loop is (deliberately) started later, so coalescing
/// assertions don't race against the injected instant sleeper.
private func settle() async {
    try? await Task.sleep(for: .milliseconds(50))
}

// MARK: - Coalescing

@MainActor
@Test func backToBackRequestsForSamePairCoalesceIntoOneBatch() async throws {
    let service = try makeService()
    let mock = MockTranslationSession()

    async let first = service.translate("bonjour", from: fr, to: en)
    async let second = service.translate("chat", from: fr, to: en)
    await settle() // let both enqueue before the loop (and its flush) starts

    let loop = Task { await service.runQueueLoop(pair: LanguagePair(source: fr, target: en), adapter: mock) }
    defer { loop.cancel() }

    _ = try await (first, second)
    #expect(await mock.callCount == 1)
    #expect(await mock.batches.first?.count == 2)
}

@MainActor
@Test func requestsFromSeparateFlushCyclesProduceSeparateBatches() async throws {
    let service = try makeService()
    let mock = MockTranslationSession()
    let pair = LanguagePair(source: fr, target: en)

    let loop = Task { await service.runQueueLoop(pair: pair, adapter: mock) }
    defer { loop.cancel() }
    await settle() // let the loop reach waitForWork before issuing requests

    _ = try await service.translate("bonjour", from: fr, to: en)
    _ = try await service.translate("chat", from: fr, to: en)

    #expect(await mock.callCount == 2)
}

@MainActor
@Test func batchLargerThanMaxSizeSplitsAcrossTwoCalls() async throws {
    let service = try makeService()
    let mock = MockTranslationSession()
    let pair = LanguagePair(source: fr, target: en)

    try await withThrowingTaskGroup(of: String.self) { group in
        for i in 0..<21 {
            group.addTask { try await service.translate("word\(i)", from: fr, to: en) }
        }
        await settle() // let all 21 enqueue before the loop starts

        let loop = Task { await service.runQueueLoop(pair: pair, adapter: mock) }
        defer { loop.cancel() }

        for try await _ in group {}
    }

    #expect(await mock.callCount == 2)
    let sizes = await mock.batches.map(\.count).sorted()
    #expect(sizes == [1, 20])
}

@MainActor
@Test func performBatchThrowingFailsEveryContinuationInBatch() async throws {
    let service = try makeService()
    let mock = MockTranslationSession(responders: [{ _ in .failure(MockSessionError(message: "boom")) }])
    let pair = LanguagePair(source: fr, target: en)

    async let first = service.translate("bonjour", from: fr, to: en)
    async let second = service.translate("chat", from: fr, to: en)
    await settle()

    let loop = Task { await service.runQueueLoop(pair: pair, adapter: mock) }
    defer { loop.cancel() }

    var firstFailed = false
    var secondFailed = false
    do { _ = try await first } catch let error as MockSessionError { firstFailed = (error.message == "boom") } catch {}
    do { _ = try await second } catch let error as MockSessionError { secondFailed = (error.message == "boom") } catch {}

    #expect(firstFailed)
    #expect(secondFailed)
}

@MainActor
@Test func missingClientIdentifierFailsOnlyThatRequest() async throws {
    let service = try makeService()
    let pair = LanguagePair(source: fr, target: en)

    let mock = MockTranslationSession(responders: [{ requests in
        // Intentionally answer only the first request in the batch.
        guard let firstRequest = requests.first else { return .success([:]) }
        return .success([firstRequest.id.uuidString: "translated"])
    }])

    async let first = service.translate("bonjour", from: fr, to: en)
    async let second = service.translate("chat", from: fr, to: en)
    await settle()

    let loop = Task { await service.runQueueLoop(pair: pair, adapter: mock) }
    defer { loop.cancel() }

    var successes: [String] = []
    var failures: [TranslationError] = []

    do { successes.append(try await first) } catch let error as TranslationError { failures.append(error) }
    do { successes.append(try await second) } catch let error as TranslationError { failures.append(error) }

    #expect(successes.count == 1)
    #expect(failures.count == 1)
    if let failure = failures.first, case .sessionUnavailable = failure {
        // expected
    } else {
        Issue.record("expected .sessionUnavailable, got \(String(describing: failures.first))")
    }
}

@MainActor
@Test func differentPairsDoNotCoalesce() async throws {
    let service = try makeService()
    let pairFrEn = LanguagePair(source: fr, target: en)
    let pairEsEn = LanguagePair(source: es, target: en)
    let mockFrEn = MockTranslationSession()
    let mockEsEn = MockTranslationSession()

    async let first = service.translate("bonjour", from: fr, to: en)
    async let second = service.translate("hola", from: es, to: en)
    await settle()

    let loopA = Task { await service.runQueueLoop(pair: pairFrEn, adapter: mockFrEn) }
    let loopB = Task { await service.runQueueLoop(pair: pairEsEn, adapter: mockEsEn) }
    defer { loopA.cancel(); loopB.cancel() }

    _ = try await (first, second)

    #expect(await mockFrEn.callCount == 1)
    #expect(await mockFrEn.batches.first?.count == 1)
    #expect(await mockEsEn.callCount == 1)
    #expect(await mockEsEn.batches.first?.count == 1)
}

// MARK: - Availability mapping

@MainActor
@Test func availabilityMapsInstalledToReady() async throws {
    let service = try makeService(availability: .installed)
    let result = await service.availability(from: fr, to: en)
    #expect(result == .ready)
}

@MainActor
@Test func availabilityMapsSupportedToNeedsDownload() async throws {
    let service = try makeService(availability: .supported)
    let result = await service.availability(from: fr, to: en)
    #expect(result == .needsDownload)
}

@MainActor
@Test func availabilityMapsUnsupportedToUnsupported() async throws {
    let service = try makeService(availability: .unsupported)
    let result = await service.availability(from: fr, to: en)
    #expect(result == .unsupported)
}

// MARK: - Same-language guard

@MainActor
@Test func sameLanguageGuardThrowsBeforeTouchingCacheOrQueue() async throws {
    let service = try makeService()
    let source = Locale.Language(identifier: "fr-FR")
    let target = Locale.Language(identifier: "fr-CA")

    do {
        _ = try await service.translate("bonjour", from: source, to: target)
        Issue.record("expected TranslationError.sameLanguage to be thrown")
    } catch let error as TranslationError {
        #expect(error == .sameLanguage)
    }
}

// MARK: - prepare(from:to:) offline fast-fail

@MainActor
@Test func prepareFailsFastWhenOfflineWithoutTouchingSession() async throws {
    let service = try makeService(availability: .supported, network: false)

    do {
        try await service.prepare(from: fr, to: en)
        Issue.record("expected TranslationError.downloadRequiresNetwork to be thrown")
    } catch let error as TranslationError {
        #expect(error == .downloadRequiresNetwork)
    }
}

@MainActor
@Test func prepareThrowsUnsupportedWithoutNetworkCheck() async throws {
    // Even if the network were satisfied, an unsupported pair must fail
    // with .unsupportedLanguagePair, not attempt a session.
    let service = try makeService(availability: .unsupported, network: true)

    do {
        try await service.prepare(from: fr, to: en)
        Issue.record("expected TranslationError.unsupportedLanguagePair to be thrown")
    } catch let error as TranslationError {
        #expect(error == .unsupportedLanguagePair)
    }
}
