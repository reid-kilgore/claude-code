# LingoPod — Technical Architecture

This document is the contract every module spec and every implementation
agent must follow. Module specs live in `docs/specs/` and may add detail but
may not contradict this file. If a spec needs to deviate, the deviation gets
recorded here first.

## 1. Platform & toolchain

- **Minimum deployment target: iOS 26.0.** Non-negotiable: the two pillar
  frameworks (`SpeechAnalyzer`/`SpeechTranscriber` in Speech, and
  `FoundationModels`) are iOS 26+.
- **Swift 6 language mode**, strict concurrency. SwiftUI only (no UIKit view
  controllers except where a framework demands a representable).
- **No third-party dependencies.** Everything needed (RSS via `XMLParser`,
  networking via `URLSession`, persistence via SwiftData) is first-party.
  This keeps the project buildable from a clean checkout with zero fetches.
- **Project generation: XcodeGen** (`project.yml` committed; `.xcodeproj` is
  not). Developers on a Mac run `xcodegen generate`. Rationale: this repo is
  authored in a Linux environment where Xcode can't produce/maintain a
  `.xcodeproj`; a declarative YAML file can be authored and reviewed here.
- Unit-testable logic (feed parsing, transcript normalization, sync engine,
  time math) lives in a local SwiftPM package **`LingoPodKit`** with no UIKit/
  SwiftUI imports, so `swift test` can run it on any Mac without booting a
  simulator. App target depends on it.

## 2. Repository layout

```
lingopod/
  docs/                      # scoping docs (this file, specs/)
  project.yml                # XcodeGen manifest (app target + test targets)
  LingoPodKit/               # SwiftPM package: pure logic, platform-agnostic where possible
    Package.swift
    Sources/LingoPodKit/
      Models/                # SwiftData models + value types (M1)
      Feeds/                 # RSS/iTunes search parsing (M1)
      Transcripts/           # normalization, SRT/VTT/JSON parsers, segment math (M3)
    Tests/LingoPodKitTests/
  LingoPod/                  # app target sources
    App/                     # @main, DI container, root navigation
    Playback/                # PlayerEngine (M2)
    Transcription/           # SpeechAnalyzer pipeline (M3)
    Intelligence/            # Translation + FoundationModels services (M5, M6)
    UI/
      Library/               # subscriptions, search, episode lists (M1 UI)
      Player/                # now-playing screen (M2 UI)
      TranscriptOverlay/     # lyrics overlay + interactions (M4)
    Resources/               # Assets.xcassets, Localizable.xcstrings
```

## 3. Module map and ownership

Each module has one spec in `docs/specs/` and is implemented independently
against the interfaces in §5. Dependency arrows point at what a module needs.

| ID | Module | Spec file | Depends on |
|----|--------|-----------|------------|
| M0 | Project scaffolding (project.yml, app entry, DI, navigation shell, Info.plist keys, background modes) | `specs/M0-scaffolding.md` | — |
| M1 | Catalog: search, RSS ingestion, subscriptions, episode/download management, SwiftData store | `specs/M1-catalog.md` | M0 |
| M2 | Playback: AVPlayer engine, background audio, now-playing info, rate control, seek API, playhead publisher | `specs/M2-playback.md` | M0, M1 (Episode model) |
| M3 | Transcripts: feed-transcript fetch/parse (SRT/VTT/JSON), on-device SpeechAnalyzer pipeline, unified `Transcript` store | `specs/M3-transcripts.md` | M1, M2 (playhead for scheduling) |
| M4 | Transcript overlay UI: lyrics-style view, sync/auto-scroll, tap-to-seek, selection gestures | `specs/M4-overlay-ui.md` | M2, M3, M5, M6 (interfaces only) |
| M5 | Translation service: word/phrase translation, language-pack lifecycle, translation cache | `specs/M5-translation.md` | M0 |
| M6 | Explain service: FoundationModels session mgmt, prompt design, guided generation, availability gating | `specs/M6-explain.md` | M0, M3 (segment context) |

Build order: M0 → M1 → {M2, M5, M6} in parallel → M3 → M4.
M4 is last and integrates everything, but can be built against protocol
mocks from day one because all cross-module calls go through §5 interfaces.

## 4. Data model (SwiftData, in `LingoPodKit/Models`)

Names below are canonical; specs must use them verbatim.

```swift
@Model final class Podcast {
  @Attribute(.unique) var feedURL: URL
  var title: String
  var author: String?
  var artworkURL: URL?
  var feedDescription: String?
  var languageCode: String?      // BCP-47 from <language>; nil if absent
  var languageOverride: String?  // user-set BCP-47, wins over languageCode
  var subscribedAt: Date
  var lastRefreshedAt: Date?
  @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
  var episodes: [Episode]
}

@Model final class Episode {
  @Attribute(.unique) var guid: String       // RSS guid, falls back to enclosure URL
  var podcast: Podcast?
  var title: String
  var episodeDescription: String?            // HTML-stripped
  var publishedAt: Date?
  var duration: TimeInterval?                // from itunes:duration if present
  var audioURL: URL                          // enclosure
  var feedTranscriptURL: URL?                // <podcast:transcript> href
  var feedTranscriptType: String?            // its MIME type
  var localAudioPath: String?                // relative path under Application Support when downloaded
  var downloadState: DownloadState           // enum: none, inProgress(progress persisted coarse), downloaded, failed
  var playbackPosition: TimeInterval
  var playbackCompleted: Bool
  @Relationship(deleteRule: .cascade, inverse: \Transcript.episode)
  var transcript: Transcript?
}

@Model final class Transcript {
  var episode: Episode?
  var source: TranscriptSource               // enum: feed, onDevice
  var languageCode: String                   // BCP-47 actually used
  var state: TranscriptState                 // enum: pending, partial, complete, failed(reason: String)
  var generatedAt: Date
  @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript)
  var segments: [TranscriptSegment]          // ordered by startTime
}

@Model final class TranscriptSegment {
  var transcript: Transcript?
  var index: Int                             // stable ordering key
  var startTime: TimeInterval                // seconds from episode start
  var endTime: TimeInterval
  var text: String                           // display text, one "line" in the overlay
  var wordTimings: [WordTiming]              // Codable value array; empty for coarse feed transcripts
}

struct WordTiming: Codable, Hashable, Sendable {
  var text: String
  var start: TimeInterval        // absolute, seconds from episode start
  var end: TimeInterval
  var rangeInSegmentText: Range<Int>   // UTF-16 offsets into TranscriptSegment.text
}
```

Cached AI artifacts (so airplane mode keeps working and we don't re-run models):

```swift
@Model final class TranslationCacheEntry {
  @Attribute(.unique) var key: String  // "\(sourceLang)|\(targetLang)|\(normalizedText)"
  var sourceText: String
  var translatedText: String
  var sourceLanguage: String; var targetLanguage: String
  var createdAt: Date
}

@Model final class ExplanationCacheEntry {
  @Attribute(.unique) var key: String  // episodeGUID + segment index range + UTF-16 range + targetLang
  var passage: String
  var explanationJSON: Data            // encoded PassageExplanation (see §5.4)
  var createdAt: Date
}
```

Segmentation rule (all transcript sources normalize to this): a segment is a
display line of **max ~90 characters / one sentence-ish unit**, target
duration 2–8s. M3's spec owns the exact algorithm; everyone else just
consumes segments.

## 5. Cross-module interfaces

These protocols live in the app target (`LingoPod/App/Interfaces.swift`)
except where noted, and are injected via a lightweight `AppContainer`
(an `@Observable` object created in `@main`, passed through the environment).
No third-party DI. Implementation agents: **code against these exactly**;
if a signature must change, update this doc and `Interfaces.swift` in the
same commit.

### 5.1 Playback (M2 provides)

```swift
@MainActor
protocol PlayerEngineProtocol: AnyObject, Observable {
  var currentEpisodeID: PersistentIdentifier? { get }
  var state: PlaybackState { get }          // idle, loading, playing, paused, failed(Error)
  var currentTime: TimeInterval { get }     // observable, updated ~4 Hz via periodic time observer
  var duration: TimeInterval? { get }
  var rate: Float { get set }               // 0.5...2.0

  func load(episode: Episode, autoplay: Bool) async
  func play(); func pause(); func togglePlayPause()
  func seek(to time: TimeInterval) async    // completes when AVPlayer seek lands
  func skip(by seconds: TimeInterval) async
}
```

`currentTime` at ~4 Hz is the single sync source for the overlay. No other
module talks to `AVPlayer` directly.

### 5.2 Transcripts (M3 provides)

```swift
protocol TranscriptProviderProtocol: Sendable {
  /// Returns existing transcript, or orchestrates: feed transcript fetch →
  /// else on-device transcription (requires downloaded audio). Progressive:
  /// the returned Transcript's segments grow while state == .partial.
  func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle
  func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle
}

/// Observable wrapper: UI watches `segments` + `state` while transcription streams in.
@MainActor @Observable final class TranscriptHandle {
  private(set) var state: TranscriptState
  private(set) var segments: [TranscriptSegmentSnapshot]  // value-type snapshots, sorted
  private(set) var progress: Double                        // 0...1 of episode duration transcribed
}
```

`TranscriptSegmentSnapshot` is a `Sendable` struct mirror of
`TranscriptSegment` (id, index, times, text, wordTimings) — UI never touches
SwiftData objects directly for the overlay hot path.

### 5.3 Translation (M5 provides)

```swift
protocol TranslationServiceProtocol: Sendable {
  /// Checks cache first. `source` is the podcast language, `target` the user's.
  func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
  func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability
  // enum TranslationAvailability { case ready, needsDownload, unsupported }
}
```

Note: Apple's `TranslationSession` must be obtained via the SwiftUI
`.translationTask` modifier — M5's spec defines a host-view pattern that
adapts this to the async protocol above; M4 just calls the protocol.

### 5.4 Explain (M6 provides)

```swift
protocol ExplainServiceProtocol: Sendable {
  var availability: ExplainAvailability { get }  // ready / modelNotReady / unavailable(reason)
  /// Streams a structured explanation of `passage` (user's highlight),
  /// with `context` = surrounding segment text, in `targetLanguage`.
  func explain(passage: String, context: String, sourceLanguage: Locale.Language,
               targetLanguage: Locale.Language) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>
}

@Generable struct PassageExplanation {
  @Guide(description: "Natural translation of the passage into the target language")
  var translation: String
  @Guide(description: "2-4 sentence explanation of overall meaning, in the target language")
  var meaning: String
  @Guide(description: "Notable grammar constructions, each ≤2 sentences", .count(0...4))
  var grammarNotes: [String]
  @Guide(description: "Idioms/colloquialisms/register notes", .count(0...3))
  var idiomNotes: [String]
}
```

### 5.5 Catalog (M1 provides)

```swift
protocol CatalogServiceProtocol: Sendable {
  func search(term: String) async throws -> [PodcastSearchResult]   // iTunes Search API
  func subscribe(feedURL: URL) async throws -> PersistentIdentifier // parses feed, inserts models
  func unsubscribe(podcastID: PersistentIdentifier) async throws
  func refresh(podcastID: PersistentIdentifier) async throws
  func download(episodeID: PersistentIdentifier) async throws       // background URLSession
  func removeDownload(episodeID: PersistentIdentifier) async throws
}
```

## 6. Key framework decisions (the "why", pinned)

1. **Transcription — `SpeechAnalyzer` + `SpeechTranscriber` (Speech, iOS 26).**
   Not `SFSpeechRecognizer` (legacy, 1-min-ish limits, server option),
   not raw Foundation Models (no audio input). `SpeechTranscriber` is built
   for long-form audio, runs fully on-device, supports asset
   download per-locale through `AssetInventory`, and emits
   `AttributedString` results whose runs carry `audioTimeRange`
   (`CMTimeRange`) — exactly what tap-to-seek needs. Transcription reads the
   **downloaded** audio file (`AVAudioFile`) rather than tapping the live
   stream: simpler, seek-independent, can run faster than real-time and
   ahead of the playhead. Consequence: on-device transcription requires the
   episode to be downloaded first (auto-download-on-play is M1 behavior).
2. **Word/phrase translation — Translation framework (`TranslationSession`),
   not the LLM.** Purpose-built, faster, offline language packs, and keeps
   the LLM free for the Explain feature. LLM is a fallback *only* if the
   language pair is unsupported (M6 spec covers this).
3. **Explain — FoundationModels `LanguageModelSession` with `@Generable`
   guided generation + `streamResponse`.** Structured output renders as a
   tidy card (translation / meaning / grammar / idioms) instead of a wall of
   text, and partial generation lets the card fill in live.
4. **Sync highlighting — poll `currentTime` (4 Hz) + binary search over
   segment start times.** No per-word karaoke in v1 (feed transcripts often
   lack word timings); highlight granularity is the segment. Word timings
   are stored when available to enable karaoke mode later.
5. **SwiftData over Core Data/GRDB** — first-party, good SwiftUI integration,
   our write volume (segments in batches) is fine with batched inserts in a
   `ModelActor`.

## 7. Concurrency rules

- UI and `PlayerEngine` are `@MainActor`. Heavy work (parsing, transcription,
  SwiftData batch writes) happens in `ModelActor`s / detached tasks.
- Transcription pipeline is an `actor` owning the `SpeechAnalyzer`; it writes
  segment batches through a `ModelActor` and posts snapshots to the
  `TranscriptHandle` on the main actor.
- Everything crossing module boundaries is `Sendable` (snapshots, value
  types, `PersistentIdentifier`s — never live `@Model` objects).
- All long operations support cancellation (`Task` cancellation checked in
  loops); switching episodes cancels the previous episode's transcription.

## 8. Error handling & degraded states (uniform pattern)

Every service surfaces a typed availability/state enum (see §5) rather than
throwing for predictable conditions. UI renders these as inline banners in
the overlay, never alerts, with one actionable button where possible
("Download language", "Download episode to transcribe", "Explain requires
Apple Intelligence"). Unexpected errors log via `os.Logger` subsystem
`com.lingopod.app`, category per module.

## 9. Testing expectations

- `LingoPodKit` (parsers, normalizers, segmentation, cache keys, time math):
  real unit tests, `swift test`-runnable, fixtures under `Tests/…/Fixtures`
  (sample RSS with and without `podcast:transcript`, SRT, VTT, Podcasting
  2.0 JSON).
- App-target services: constructor-injected dependencies so logic is
  testable; framework-touching seams (`SpeechAnalyzer`, `TranslationSession`,
  `LanguageModelSession`, `AVPlayer`) are wrapped in thin protocols and left
  for on-device verification. Each spec lists a **manual verification
  script** (steps a human runs on a device) since CI can't exercise these.

## 10. Conventions for implementation agents

- Swift API Design Guidelines naming; 4-space indent; one type per file.
- No `try!`/`force unwrap` outside tests. No `print` — use `os.Logger`.
- Every file starts with a `//` header naming its module ID (e.g. `// M3`).
- Do not invent public API across module boundaries: only §5 protocols.
- If a needed iOS 26 API detail is uncertain, write the code to the
  documented shape, mark it with `// VERIFY(iOS26):` and a one-line note,
  and keep the call site isolated in the thin wrapper — do not restructure
  around guesses.
- Commit per module, message format: `M<n>: <what>`.
