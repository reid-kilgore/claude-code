// M0
// Temporary stand-in implementations of every §5 service protocol so
// `AppContainer` can be constructed and the app can build/run before
// M1–M6 land real ones (docs/specs/M0-scaffolding.md §6). These are not
// bare `fatalError()` stubs: `RootView`/`LibraryView`, and later ad hoc
// SwiftUI Previews other modules write, construct and read from them
// before real implementations exist, so predictable no-op/empty behavior
// matters. Each later module deletes or keeps (e.g. under `#if DEBUG` for
// previews) its corresponding mock as it lands the real service — see
// M0-scaffolding.md §6.6 for the swap procedure.
import Foundation
import Observation
import SwiftData
import LingoPodKit

enum MockServiceError: Error, LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "This feature is not implemented yet (M0 scaffolding placeholder)."
    }
}

// MARK: - Catalog (M1)

/// Returns empty/no-op results so the Library/Search tabs render an empty
/// state instead of crashing.
final class MockCatalogService: CatalogServiceProtocol {
    func search(term: String) async throws -> [PodcastSearchResult] {
        []
    }

    func subscribe(feedURL: URL) async throws -> PersistentIdentifier {
        throw MockServiceError.notImplemented
    }

    func unsubscribe(podcastID: PersistentIdentifier) async throws {
        throw MockServiceError.notImplemented
    }

    func refresh(podcastID: PersistentIdentifier) async throws {
        throw MockServiceError.notImplemented
    }

    func download(episodeID: PersistentIdentifier) async throws {
        throw MockServiceError.notImplemented
    }

    func removeDownload(episodeID: PersistentIdentifier) async throws {
        throw MockServiceError.notImplemented
    }
}

// MARK: - Playback (M2)

/// `PlayerEngineProtocol.load(episode:autoplay:)` takes a real `Episode`
/// (`@Model`), which this mock accepts without crashing even though no
/// real episode will ever be passed to it in M0 (`RootView`/`LibraryView`
/// never call `load` — there is nothing to play from an empty Library).
@MainActor
@Observable
final class MockPlayerEngine: PlayerEngineProtocol {
    private(set) var currentEpisodeID: PersistentIdentifier?
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval?
    var rate: Float = 1.0

    func load(episode: Episode, autoplay: Bool) async {
        // No-op in M0. M2 replaces this class entirely.
    }

    func play() {}
    func pause() {}
    func togglePlayPause() {}

    func seek(to time: TimeInterval) async {}

    func skip(by seconds: TimeInterval) async {}
}

// MARK: - Translation (M5)

/// Also conforms to `TranslationDownloadPreparing` (architecture §11.5) as
/// a no-op, so `AppContainer.translationDownloadPreparing` demonstrates
/// the optional-capability pattern from day one instead of always being
/// `nil` until M5 lands.
final class MockTranslationService: TranslationServiceProtocol, TranslationDownloadPreparing {
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        throw MockServiceError.notImplemented
    }

    func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability {
        .unsupported
    }

    func prepare(from source: Locale.Language, to target: Locale.Language) async throws {
        throw MockServiceError.notImplemented
    }
}

// MARK: - Explain (M6)
// M0's placeholder was removed when M6 landed: the real preview/test mock
// with canned streaming lives at LingoPod/Intelligence/MockExplainService.swift.

// MARK: - Transcripts (M3)

final class MockTranscriptProvider: TranscriptProviderProtocol {
    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        throw MockServiceError.notImplemented
    }

    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        throw MockServiceError.notImplemented
    }
}
