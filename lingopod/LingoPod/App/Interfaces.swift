// M0
// Single source of truth for cross-module protocols and shared types.
// Mirrors docs/01-architecture.md §5, amended by §11 (binding — see
// per-type notes below for where §11 changed the shape spelled out in
// M0-scaffolding.md §4). If you need to change a signature, update
// architecture.md and this file in the same commit — do not let them
// drift.
//
// Deviation from M0-scaffolding.md §4: that spec's literal Interfaces.swift
// listing predates architecture §11.1 (models land in LingoPodKit as part
// of M0, not M1) and redefines `WordTiming` locally. Since `WordTiming`,
// `DownloadState`, `TranscriptSource`, and `TranscriptState` are now
// canonically defined in `LingoPodKit/Sources/LingoPodKit/Models/` (part
// of the persisted §4 data model, verbatim), this file imports
// `LingoPodKit` and reuses them instead of redefining them a second time
// under the same names — avoiding two nominally-distinct-but-identical
// `WordTiming` types in the same app. Everything else below matches the
// spec's Interfaces.swift listing.
import Foundation
import SwiftData
import Translation
import LingoPodKit

// MARK: - Playback state (architecture §5.1, amended by §11.9)

enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(PlaybackError)
}

/// Concrete, Sendable/Equatable error type carried by `PlaybackState.failed`
/// (architecture §11.9: "`PlaybackState.failed` carries M2's concrete
/// `PlaybackError`, not a bare `Error`"). `Error` itself is not
/// `Equatable`, so `PlaybackState` couldn't be `Equatable` (needed for
/// SwiftUI diffing and tests) without a wrapper; M0 defines the wrapper's
/// shape now under the name §11.9 pins so M2 doesn't have to invent one
/// later. M2 owns constructing meaningful `code`/`message` pairs.
struct PlaybackError: Error, Equatable, Sendable {
    /// Stable machine code, same convention as `failed(reason:)` elsewhere
    /// (architecture §11.4) — UI maps this to localized copy + actions.
    let code: String
    /// Human-readable, for logs only; not shown to users directly.
    let message: String

    init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Wraps an arbitrary `Error` when no stable code is available yet.
    init(_ error: Error) {
        self.code = "unknown"
        self.message = String(describing: error)
    }
}

// MARK: - Translation availability (architecture §5.3)

enum TranslationAvailability: Equatable {
    case ready
    case needsDownload
    case unsupported
}

// MARK: - Explain availability (architecture §5.4)

enum ExplainAvailability: Equatable {
    case ready
    case modelNotReady
    case unavailable(reason: String)
}

// MARK: - Transcript segment snapshot (architecture §5.2, pinned)

/// Sendable, value-type mirror of `TranscriptSegment` for the UI hot path.
/// UI never touches live `@Model` objects for the overlay. `wordTimings`
/// reuses `LingoPodKit.WordTiming` (see file header) rather than a
/// second, locally-defined type.
///
/// Conforms to `Hashable` (which implies `Equatable`) to match
/// architecture.md §5.2's canonical definition; M0-scaffolding.md §4's
/// literal Interfaces.swift listing has `Equatable` only, which would
/// contradict architecture.md — since architecture.md is the binding
/// contract, `Hashable` wins here.
struct TranscriptSegmentSnapshot: Sendable, Identifiable, Hashable {
    let id: PersistentIdentifier
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let wordTimings: [WordTiming]
}

// MARK: - Catalog search result (architecture §5.5)

/// One row from the iTunes Search API, before subscription. Not persisted;
/// `CatalogServiceProtocol.subscribe(feedURL:)` is what creates a `Podcast`.
struct PodcastSearchResult: Sendable, Identifiable, Equatable {
    let id: String              // iTunes collectionId, stringified
    let feedURL: URL
    let title: String
    let author: String?
    let artworkURL: URL?
    let languageCode: String?   // BCP-47 if iTunes provides one, else nil
}

// MARK: - 5.1 Playback (M2 provides)

@MainActor
protocol PlayerEngineProtocol: AnyObject, Observable {
    var currentEpisodeID: PersistentIdentifier? { get }
    var state: PlaybackState { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval? { get }
    var rate: Float { get set }

    func load(episode: Episode, autoplay: Bool) async
    func play()
    func pause()
    func togglePlayPause()
    func seek(to time: TimeInterval) async
    func skip(by seconds: TimeInterval) async
}

// MARK: - 5.2 Transcripts (M3 provides)

protocol TranscriptProviderProtocol: Sendable {
    /// Returns existing transcript, or orchestrates: feed transcript fetch
    /// → else on-device transcription (requires downloaded audio).
    /// Progressive: the returned `Transcript`'s segments grow while
    /// `state == .partial`.
    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle
    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle
}

/// Observable wrapper: UI watches `segments` + `state` while transcription
/// streams in. Amended by architecture §11 to include `languageCode`
/// (M4 needs it for translate/explain calls) alongside the mutation/preview
/// mechanisms M0-scaffolding.md §4 already specified.
@MainActor @Observable
final class TranscriptHandle {
    /// BCP-47 actually used (M4 needs it for translate/explain).
    private(set) var languageCode: String
    private(set) var state: TranscriptState
    private(set) var segments: [TranscriptSegmentSnapshot]
    /// 0...1 of episode duration transcribed.
    private(set) var progress: Double

    init(
        languageCode: String,
        state: TranscriptState = .pending,
        segments: [TranscriptSegmentSnapshot] = [],
        progress: Double = 0
    ) {
        self.languageCode = languageCode
        self.state = state
        self.segments = segments
        self.progress = progress
    }

    /// Internal preview initializer (canned segments) for M4 previews/
    /// tests — bypasses the real `TranscriptProviderProtocol` pipeline
    /// entirely so SwiftUI Previews can show a populated overlay without a
    /// live episode/transcription run.
    init(
        previewLanguageCode: String,
        previewSegments: [TranscriptSegmentSnapshot],
        previewState: TranscriptState = .complete,
        previewProgress: Double = 1
    ) {
        self.languageCode = previewLanguageCode
        self.segments = previewSegments
        self.state = previewState
        self.progress = previewProgress
    }

    /// M3 is the only module that mutates a `TranscriptHandle` after
    /// creation (streaming in segments as transcription/parsing
    /// progresses). Exposed internally (not `private`) so M3's real
    /// implementation, in a different module directory but the same app
    /// target, can update instances it owns. Do not call from UI code.
    func apply(languageCode: String, state: TranscriptState, segments: [TranscriptSegmentSnapshot], progress: Double) {
        self.languageCode = languageCode
        self.state = state
        self.segments = segments
        self.progress = progress
    }
}

// MARK: - 5.3 Translation (M5 provides)

protocol TranslationServiceProtocol: Sendable {
    /// Checks cache first. `source` is the podcast language, `target` the
    /// user's.
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability
}

/// Additive capability protocol (architecture §11.5): a `TranslationService`
/// implementation that can proactively prepare (download) a language pair
/// conforms to this in addition to `TranslationServiceProtocol`.
/// `AppContainer` exposes it as an optional capability
/// (`translationService as? TranslationDownloadPreparing`) rather than
/// widening the base protocol or downcasting to a concrete type.
protocol TranslationDownloadPreparing {
    func prepare(from source: Locale.Language, to target: Locale.Language) async throws
}

/// Additive capability protocol (architecture §11.5): an `ExplainService`
/// implementation that can translate via the LLM as a fallback when the
/// Translation framework doesn't support a language pair conforms to this.
/// `AppContainer` exposes it as an optional capability
/// (`explainService as? TranslationFallbackProviding`).
protocol TranslationFallbackProviding {
    func translateFallback(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
}

// MARK: - 5.4 Explain (M6 provides)

protocol ExplainServiceProtocol: Sendable {
    var availability: ExplainAvailability { get }
    /// Streams a structured explanation of `passage` (user's highlight),
    /// with `context` = surrounding segment text, in `targetLanguage`.
    func explain(passage: String, context: String, sourceLanguage: Locale.Language,
                 targetLanguage: Locale.Language) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>
}

// NOTE: `PassageExplanation` (the `@Generable` struct architecture §5.4
// defines) lives in its own file, `PassageExplanation.swift`, in this same
// directory — not in this file. Rationale (per M0's brief): Interfaces.swift
// is read/imported-by-reference by every module implementer, so the
// FoundationModels import it would otherwise require is kept isolated to
// the one file that actually needs it. Referencing
// `PassageExplanation.PartiallyGenerated` here does not require importing
// FoundationModels in this file — it's a same-module type reference, and
// the macro expansion happens where the type is declared.

// MARK: - 5.5 Catalog (M1 provides)

protocol CatalogServiceProtocol: Sendable {
    func search(term: String) async throws -> [PodcastSearchResult]   // iTunes Search API
    func subscribe(feedURL: URL) async throws -> PersistentIdentifier // parses feed, inserts models
    func unsubscribe(podcastID: PersistentIdentifier) async throws
    func refresh(podcastID: PersistentIdentifier) async throws
    func download(episodeID: PersistentIdentifier) async throws       // background URLSession
    func removeDownload(episodeID: PersistentIdentifier) async throws
}
