# M0 — Project Scaffolding

Status: spec ready for implementation.
Depends on: nothing (first module).
Consumed by: every other module (M1–M6) builds on the files this module
creates.

## 0. Purpose and non-negotiables

M0 produces a repository that:

1. Generates a valid Xcode project via `xcodegen generate` from a committed
   `project.yml` (no `.xcodeproj` is committed — see architecture §1).
2. Builds and launches on iOS 26.0+ in Xcode, to an empty Library tab and a
   Search tab, with a miniplayer slot present but empty.
3. Contains the **complete, final** `LingoPod/App/Interfaces.swift` — the
   single source of truth for all cross-module protocols (architecture §5).
   Every later module implements against this file verbatim; it must not
   need to change shape later except by the process architecture §5
   describes (update doc + file in the same commit).
4. Contains a working `LingoPodKit` SwiftPM package skeleton that
   `swift test` can build and run (with zero tests initially, or one trivial
   smoke test — see §3).
5. Contains placeholder ("mock") implementations of every §5 service
   protocol so `AppContainer` can be constructed and the app can build and
   run *before* M1–M6 exist. These mocks are temporary scaffolding: later
   modules replace them with real implementations one at a time (see §6.3).

Everything in this spec is prescriptive. Where this spec gives literal file
contents, reproduce them exactly (adjust only where a placeholder like
`<...>` is used). Where architecture.md §4 or §5 already gives Swift code
(the `@Model` classes, the protocols), **copy it verbatim** into the files
named below — do not retype it from memory or paraphrase it, to avoid drift.

Do not implement any real business logic in this module: no networking, no
SwiftData queries beyond container setup, no AVAudioSession activation, no
real transcription/translation/explain code. Every service the app needs at
runtime for M0 to build/launch is a mock. That is the scope boundary between
M0 and M1–M6.

---

## 1. Repository layout produced by M0

After M0 is complete, the repository must look like this (files not listed
here are out of scope for M0 and must not be created):

```
lingopod/
  project.yml
  README.md
  LingoPodKit/
    Package.swift
    Sources/
      LingoPodKit/
        LingoPodKit.swift
    Tests/
      LingoPodKitTests/
        LingoPodKitTests.swift
  LingoPod/
    App/
      LingoPodApp.swift
      AppContainer.swift
      Interfaces.swift
      RootView.swift
    UI/
      Library/
        LibraryView.swift
      Player/
        MiniPlayerView.swift
    Resources/
      Assets.xcassets/
        Contents.json
        AppIcon.appiconset/
          Contents.json
        AccentColor.colorset/
          Contents.json
      Localizable.xcstrings
  LingoPodTests/
    LingoPodTests.swift
```

Notes:
- `LingoPodKit/Sources/LingoPodKit/Models/`, `Feeds/`, `Transcripts/` (from
  architecture §2) are **not** created by M0 — M1/M3 add them. Do not create
  empty placeholder directories for them; XcodeGen/SwiftPM don't need empty
  dirs to exist ahead of time.
- `LingoPod/Playback/`, `LingoPod/Transcription/`, `LingoPod/Intelligence/`,
  `LingoPod/UI/TranscriptOverlay/` are **not** created by M0 — later modules
  add them.
- `LingoPod/UI/Library/LibraryView.swift` and
  `LingoPod/UI/Player/MiniPlayerView.swift` are minimal stub views created by
  M0 only so `RootView.swift` has something to show (§5.5, §5.6). M1 and M2
  will substantially rewrite them; keep the M0 versions tiny.

---

## 2. `lingopod/project.yml`

Create this file at the repo root, exact content below. This is XcodeGen
syntax (XcodeGen ≥ 2.40, which supports iOS 26 SDK settings).

```yaml
name: LingoPod
options:
  bundleIdPrefix: com.lingopod
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
  generateEmptyDirectories: false

configs:
  Debug: debug
  Release: release

settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    SWIFT_APPROACHABLE_CONCURRENCY: YES
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    IPHONEOS_DEPLOYMENT_TARGET: "26.0"
    TARGETED_DEVICE_FAMILY: "1"
    ENABLE_PREVIEWS: YES
    ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS: YES

packages:
  LingoPodKit:
    path: LingoPodKit

targets:
  LingoPod:
    type: application
    platform: iOS
    sources:
      - path: LingoPod
        excludes:
          - "**/*.md"
    dependencies:
      - package: LingoPodKit
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lingopod.app
        PRODUCT_NAME: LingoPod
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        SWIFT_EMIT_LOC_STRINGS: YES
        DEVELOPMENT_ASSET_PATHS: ""
    info:
      path: Generated/LingoPod-Info.plist
      properties:
        CFBundleDisplayName: LingoPod
        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        UIBackgroundModes:
          - audio
        NSSpeechRecognitionUsageDescription: >-
          LingoPod transcribes podcast episodes on-device so you can read
          along and look up words while you listen. Audio never leaves your
          device.
        NSAppTransportSecurity:
          NSAllowsArbitraryLoads: false
        ITSAppUsesNonExemptEncryption: false
      entitlements:
        path: Generated/LingoPod.entitlements
        properties:
          com.apple.security.application-groups: []
    scheme:
      testTargets:
        - LingoPodTests
        - name: LingoPodKitTests
          parallelizable: true
      commandLineArguments:
        "-com.apple.CoreData.ConcurrencyDebug 1": false
      environmentVariables: {}

  LingoPodTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: LingoPodTests
    dependencies:
      - target: LingoPod
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.lingopod.app.tests

schemes:
  LingoPod:
    build:
      targets:
        LingoPod: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - LingoPodTests
        - LingoPodKitTests
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

Rules and rationale the implementer must preserve:

- **Bundle ID is `com.lingopod.app`** exactly (product decision — hardcode
  it; do not derive it only from `bundleIdPrefix` + product name if that
  would produce something different — verify the generated project's
  `PRODUCT_BUNDLE_IDENTIFIER` is literally `com.lingopod.app`).
- **`UIBackgroundModes: [audio]`** is required now even though M2 (playback)
  hasn't landed, because architecture §1/§2 assigns background audio to M2
  and Info.plist keys are M0's job per the module table in architecture §3.
- **`NSSpeechRecognitionUsageDescription`** is required even though on-device
  `SpeechAnalyzer`/`SpeechTranscriber` (M3) technically doesn't route through
  the classic `SFSpeechRecognizer` permission — Apple's documented guidance
  for the Speech framework's on-device transcriber still surfaces this usage
  string in some flows, and the App Store review flags apps that touch
  Speech framework symbols without it present. If in doubt, keep it; a
  present-but-unused usage string is harmless, a missing one can cause a
  runtime crash or rejection if any Speech API path checks for it.
  `// VERIFY(iOS26):` — the implementer of M3 should double check at that
  point whether `SpeechTranscriber` actually triggers the speech-recognition
  TCC prompt on-device; M0 includes the key defensively regardless.
- **`NSAppTransportSecurity.NSAllowsArbitraryLoads: false`** — do NOT set
  this to `true`. Podcast enclosure/feed URLs occasionally redirect through
  plain HTTP or use unusual certs, but ATS's default (HTTPS with modern TLS)
  is correct for the vast majority of feeds, and blanket-disabling ATS is an
  App Store review flag with no justification on file. If a later module
  hits real feeds that fail under default ATS, that module's spec must add
  a narrowly-scoped `NSExceptionDomains` entry for the specific host(s) and
  document why in this file — not flip the global switch. M0 ships the safe
  default only.
- **No `NSAppleMusicUsageDescription`, no `NSMicrophoneUsageDescription`,
  no `NSCameraUsageDescription`, no `NSLocationWhenInUseUsageDescription`** —
  none of these are used anywhere in the product; do not add them
  speculatively.
- **`SWIFT_STRICT_CONCURRENCY: complete`** plus
  `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` — Swift 6 language mode is set
  via `SWIFT_VERSION: "6.0"` which implies strict concurrency by default in
  Xcode's newer toolchains, but set `SWIFT_STRICT_CONCURRENCY` explicitly
  for clarity/robustness across Xcode versions. Do not weaken this to
  `minimal` or `targeted` anywhere in the app target.
- The generated Info.plist path is `Generated/LingoPod-Info.plist` (XcodeGen
  writes it there at generate-time; it is a build artifact — see §7 on
  `.gitignore`). Do not hand-author an `Info.plist` file yourself anywhere
  in the tree; all keys flow through `project.yml`'s `info:` block per
  architecture §1/§3.
- `LingoPodKitTests` is **not** a target you define in `project.yml` — it is
  provided by the local Swift package itself (SwiftPM test targets show up
  automatically as schemes when a package is referenced via `packages:` and
  wired into a target's `dependencies`). Listing it under
  `scheme.testTargets` / the `LingoPod` scheme's `test.targets` lets
  `xcodebuild test -scheme LingoPod` run both app-level and package-level
  tests in one invocation. If your XcodeGen version rejects referencing a
  SwiftPM test target this way, it is acceptable to drop
  `LingoPodKitTests` from the `LingoPod` scheme's test list; package tests
  can always be run directly with `swift test` from `LingoPodKit/` (see
  README, §8) — that is the primary supported path and must work
  regardless of Xcode scheme wiring.

---

## 3. `lingopod/LingoPodKit/Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LingoPodKit",
    platforms: [
        .iOS(.v26)
    ],
    products: [
        .library(
            name: "LingoPodKit",
            targets: ["LingoPodKit"]
        )
    ],
    targets: [
        .target(
            name: "LingoPodKit",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "LingoPodKitTests",
            dependencies: ["LingoPodKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
```

Create `LingoPodKit/Sources/LingoPodKit/LingoPodKit.swift`:

```swift
// M0
// Placeholder to give the LingoPodKit target a compiled source file before
// M1 adds Models/, Feeds/, and M3 adds Transcripts/. Safe to delete the
// enum below once real sources exist, or leave it — it is harmless.

public enum LingoPodKit {
    /// Package version marker; bump has no build effect, useful for sanity
    /// checks in tests.
    public static let scaffoldVersion = "0.1.0"
}
```

Create `LingoPodKit/Tests/LingoPodKitTests/LingoPodKitTests.swift`:

```swift
// M0
import Testing
@testable import LingoPodKit

@Test func scaffoldVersionIsSet() {
    #expect(LingoPodKit.scaffoldVersion == "0.1.0")
}
```

Use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest — it is
the modern default for a `swift-tools-version: 6.0` package and requires no
extra dependency (ships with the toolchain).

`swift test` run from inside `LingoPodKit/` must succeed with 1 test
passing after this module is complete. This is the acceptance gate for §3
regardless of Xcode/XcodeGen state — it does not require a Mac's Xcode GUI,
only the Swift toolchain, so it is the one part of M0 that can also be
sanity-checked outside Xcode if a Swift 6 toolchain is available in this
environment. (xcodegen/Xcode-only steps in §9 still require an actual Mac.)

---

## 4. `LingoPod/App/Interfaces.swift`

This file is the **single source of truth** for every cross-module
protocol. Create it by copying, verbatim, from architecture.md:

- §5.1 `PlayerEngineProtocol`
- §5.2 `TranscriptProviderProtocol` and `TranscriptHandle`
- §5.3 `TranslationServiceProtocol`
- §5.4 `ExplainServiceProtocol` and `PassageExplanation`
- §5.5 `CatalogServiceProtocol`

Plus every supporting enum/struct referenced by those protocols or by the
§4 data model that is **not** already spelled out with its exact cases in
architecture.md (architecture.md sketches some of these with a trailing
comment instead of a full definition — you must write the full definition).
The full set of enums/structs required, with exact cases, is given below.
Nothing in this list may be renamed, reordered in a way that changes raw
values, or extended with cases not listed — if a later module needs another
case, it updates architecture.md and this file together per architecture
§5's own rule.

```swift
// M0
// Single source of truth for cross-module protocols and shared types.
// Mirrors docs/01-architecture.md §5. If you need to change a signature,
// update that doc and this file in the same commit — do not let them
// drift.

import Foundation
import SwiftData
import Translation

// MARK: - Playback state (architecture §5.1)

enum PlaybackState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed(EquatableError)
}

/// `Error` is not `Equatable`; wrap it so `PlaybackState` can stay
/// `Equatable` for SwiftUI diffing and tests. Carries a human-readable
/// description; callers needing the underlying error should catch it at
/// the throw site instead of unwrapping this.
struct EquatableError: Error, Equatable {
    let message: String

    init(_ error: Error) {
        self.message = String(describing: error)
    }

    init(message: String) {
        self.message = message
    }

    static func == (lhs: EquatableError, rhs: EquatableError) -> Bool {
        lhs.message == rhs.message
    }
}

// MARK: - Download state (architecture §4, Episode.downloadState)

enum DownloadState: Codable, Equatable {
    case none
    case inProgress(progress: Double)   // 0...1, coarse/persisted periodically
    case downloaded
    case failed(reason: String)
}

// MARK: - Transcript source / state (architecture §4, Transcript)

enum TranscriptSource: String, Codable, Equatable {
    case feed
    case onDevice
}

enum TranscriptState: Codable, Equatable {
    case pending
    case partial
    case complete
    case failed(reason: String)
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

// MARK: - Transcript segment snapshot (architecture §5.2)

/// Sendable, value-type mirror of `TranscriptSegment` for the UI hot path.
/// UI never touches live `@Model` objects for the overlay.
struct TranscriptSegmentSnapshot: Sendable, Identifiable, Equatable {
    let id: PersistentIdentifier
    let index: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let wordTimings: [WordTiming]
}

// MARK: - Word timing (architecture §4)

struct WordTiming: Codable, Hashable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var rangeInSegmentText: Range<Int>
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
    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle
    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle
}

@MainActor @Observable
final class TranscriptHandle {
    private(set) var state: TranscriptState
    private(set) var segments: [TranscriptSegmentSnapshot]
    private(set) var progress: Double

    init(state: TranscriptState = .pending, segments: [TranscriptSegmentSnapshot] = [], progress: Double = 0) {
        self.state = state
        self.segments = segments
        self.progress = progress
    }

    /// M3 is the only module that mutates a `TranscriptHandle` after
    /// creation (streaming in segments as transcription/parsing
    /// progresses). Exposed internally (not `private`) so M3's real
    /// implementation, in a different module directory but the same app
    /// target, can update instances it owns. Do not call from UI code.
    func apply(state: TranscriptState, segments: [TranscriptSegmentSnapshot], progress: Double) {
        self.state = state
        self.segments = segments
        self.progress = progress
    }
}

// MARK: - 5.3 Translation (M5 provides)

protocol TranslationServiceProtocol: Sendable {
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
    func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability
}

// MARK: - 5.4 Explain (M6 provides)

protocol ExplainServiceProtocol: Sendable {
    var availability: ExplainAvailability { get }
    func explain(passage: String, context: String, sourceLanguage: Locale.Language,
                 targetLanguage: Locale.Language) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>
}

// NOTE: `@Generable`/`@Guide`/`.PartiallyGenerated` come from the
// `FoundationModels` framework (iOS 26). M0 declares this struct so
// `Interfaces.swift` compiles standalone and every module can reference
// `PassageExplanation`, but M0 does not import FoundationModels-dependent
// logic anywhere else. If `@Generable`/`@Guide` are unavailable in the
// toolchain used to build M0 (unlikely on iOS 26 SDKs, but possible on an
// older Xcode), mark the gap with `// VERIFY(iOS26):` right above this
// declaration rather than stubbing the macros out — do not silently drop
// `@Generable`.
import FoundationModels

@Generable
struct PassageExplanation {
    @Guide(description: "Natural translation of the passage into the target language")
    var translation: String
    @Guide(description: "2-4 sentence explanation of overall meaning, in the target language")
    var meaning: String
    @Guide(description: "Notable grammar constructions, each ≤2 sentences", .count(0...4))
    var grammarNotes: [String]
    @Guide(description: "Idioms/colloquialisms/register notes", .count(0...3))
    var idiomNotes: [String]
}

// MARK: - 5.5 Catalog (M1 provides)

protocol CatalogServiceProtocol: Sendable {
    func search(term: String) async throws -> [PodcastSearchResult]
    func subscribe(feedURL: URL) async throws -> PersistentIdentifier
    func unsubscribe(podcastID: PersistentIdentifier) async throws
    func refresh(podcastID: PersistentIdentifier) async throws
    func download(episodeID: PersistentIdentifier) async throws
    func removeDownload(episodeID: PersistentIdentifier) async throws
}
```

Implementer notes:

- `Episode`, `Podcast`, `Transcript`, `TranscriptSegment` referenced above
  (e.g. `PlayerEngineProtocol.load(episode: Episode, ...)`) are the
  `@Model` classes from architecture §4. **M0 does not define them** — M1
  owns `LingoPodKit/Sources/LingoPodKit/Models/`. This means
  `Interfaces.swift` as committed by M0 **will not compile stand-alone
  until M1 lands the models**, and that is expected and acceptable: M0's
  own placeholder services (§6) must be written to avoid needing a real
  `Episode` instance (see §6.2). The M0 acceptance criterion is that the
  full app target — `AppContainer`, mocks, `RootView`, `LingoPodApp` —
  builds together, not that `Interfaces.swift` compiles in isolation.
- Put the `import FoundationModels` line where shown (immediately above
  `PassageExplanation`, after the other type declarations) so a reader can
  see at a glance which declaration needs it; do not hoist all imports to
  the top purely for tidiness if it obscures this.
- `TranscriptHandle.apply(...)` is not in architecture.md's snippet, which
  only shows the `private(set)` properties. M0 adds a package/internal
  mutator because *something* has to set those properties and
  architecture.md doesn't specify the mechanism. This is a judgment call
  documented here so M3's implementer knows it exists and doesn't
  reinvent a parallel mechanism (e.g. reflection, a second init). If M3's
  spec later needs a different update mechanism (e.g. per-field setters
  for finer-grained observation), that spec should update this file and
  architecture.md together, per architecture §5's rule — do not silently
  diverge.

---

## 5. App target sources

### 5.1 `LingoPod/App/LingoPodApp.swift`

```swift
// M0
import SwiftUI
import SwiftData

@main
struct LingoPodApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container.modelContainer)
                .environment(container)
        }
    }
}
```

### 5.2 `LingoPod/App/AppContainer.swift`

`AppContainer` is the app's only composition root. It:

1. Builds the SwiftData `ModelContainer` over every `@Model` type listed in
   architecture §4 (`Podcast`, `Episode`, `Transcript`, `TranscriptSegment`,
   `TranslationCacheEntry`, `ExplanationCacheEntry`).
2. Holds one instance of each §5 service protocol, typed as the *protocol*
   (never the concrete type), so later modules can swap the concrete
   implementation without touching `AppContainer`'s public shape.
3. In M0, every service is a mock (§6). Later modules replace exactly one
   `let`/initializer line each — see §6.3 for the swap procedure.

Because `Episode`, `Podcast`, etc. don't exist yet in M0 (M1 adds them),
`AppContainer`'s `ModelContainer` setup needs *something* to hand
`ModelContainer(for:)`. Two acceptable approaches — pick the first if at all
possible:

- **Preferred:** M0 is implemented *after* M1's models exist in the repo
  (i.e., if the build order in architecture §3 is followed strictly, M1
  lands before anyone tries to compile `AppContainer` for real). In that
  case just write the container against the real model list below and
  move on — this is what the code below assumes.
- **Fallback (only if you must produce a standalone-compiling M0 before any
  models exist):** temporarily reference an empty schema
  (`ModelContainer(for: Schema([]))`) with a `// TODO(M1):` comment where
  the real model list goes, so the app still launches. Whoever implements
  M1 must delete the TODO and wire in the real schema as part of M1, not
  leave it for later.

Default to the **preferred** path — this spec is written assuming the real
model types are available by the time `AppContainer` is compiled, since
architecture §3's build order is M0 → M1 first.

```swift
// M0
import Foundation
import SwiftData
import Observation
import LingoPodKit

@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer

    var catalogService: any CatalogServiceProtocol
    var translationService: any TranslationServiceProtocol
    var explainService: any ExplainServiceProtocol
    var transcriptProvider: any TranscriptProviderProtocol

    /// `PlayerEngine` is `@MainActor @Observable` and owned as a concrete
    /// reference type (not `any PlayerEngineProtocol`) because SwiftUI's
    /// `@Observable` protocol conformance can't be stored as an
    /// existential and still participate in view invalidation the way a
    /// concrete `@Observable` class can. Views that need protocol-only
    /// access can still type a parameter as `any PlayerEngineProtocol`;
    /// `AppContainer` itself keeps the concrete type for observation to
    /// work. M2 replaces `MockPlayerEngine` with the real `PlayerEngine`
    /// class here without changing this property's declared type only if
    /// the real type also conforms; if not, adjust then and note why in
    /// this file.
    var playerEngine: MockPlayerEngine

    init() {
        do {
            let schema = Schema([
                Podcast.self,
                Episode.self,
                Transcript.self,
                TranscriptSegment.self,
                TranslationCacheEntry.self,
                ExplanationCacheEntry.self,
            ])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            self.modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        self.catalogService = MockCatalogService()
        self.translationService = MockTranslationService()
        self.explainService = MockExplainService()
        self.transcriptProvider = MockTranscriptProvider()
        self.playerEngine = MockPlayerEngine()
    }
}
```

Notes:
- `Podcast`, `Episode`, `Transcript`, `TranscriptSegment`,
  `TranslationCacheEntry`, `ExplanationCacheEntry` are the `LingoPodKit`
  model types from architecture §4 — `import LingoPodKit` brings them in.
  M0 does not redefine them.
- If `swift test`/build order genuinely blocks you from having real models
  at M0 build time, apply the documented fallback above and leave the
  `// TODO(M1):` marker — don't invent a different schema mechanism.
- Do **not** add `@MainActor` isolation assumptions beyond what's shown; do
  not make `AppContainer` a singleton/global — it is created once in
  `LingoPodApp.body` and threaded through `.environment(container)`.

### 5.3 Placeholder/mock service implementations

Create these in `LingoPod/App/AppContainer.swift` (same file, below
`AppContainer`, or split into a private `MockServices.swift` in the same
`App/` directory — either is fine; if split, name the file
`LingoPod/App/MockServices.swift`). They exist purely so the app compiles
and runs end-to-end before M1–M6 land. See §6 below for full detail and
exact required behavior — do not just stub every method with `fatalError`;
the acceptance criteria in §9 require the app to actually launch and show
tabs, and some mocks are exercised by `RootView`/`LibraryView` at launch.

(Full mock bodies are specified in §6, not duplicated here.)

### 5.4 `LingoPod/App/RootView.swift`

```swift
// M0
import SwiftUI

struct RootView: View {
    @Environment(AppContainer.self) private var container
    @State private var selectedTab: RootTab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                Tab(RootTab.library.title, systemImage: RootTab.library.systemImage, value: .library) {
                    LibraryView()
                }
                Tab(RootTab.search.title, systemImage: RootTab.search.systemImage, value: .search) {
                    SearchPlaceholderView()
                }
            }

            // Miniplayer overlay slot. M2 replaces `MiniPlayerView`'s body
            // with the real now-playing bar; M0 only reserves the slot and
            // hides it when nothing is loaded so empty state doesn't show
            // a blank bar.
            MiniPlayerView()
                .padding(.bottom, 49) // approx. tab bar height; M2 may
                                      // replace with a GeometryReader-based
                                      // measurement instead of a constant.
        }
    }
}

private enum RootTab: Hashable {
    case library
    case search

    var title: String {
        switch self {
        case .library: "Library"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "books.vertical"
        case .search: "magnifyingglass"
        }
    }
}

/// M0 stub. M1 replaces this with the real search UI (part of M1 UI per
/// architecture §2's `UI/Library/` — search lives alongside subscriptions
/// in that directory per the repo layout table).
private struct SearchPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Search",
            systemImage: "magnifyingglass",
            description: Text("Podcast search will appear here.")
        )
    }
}
```

### 5.5 `LingoPod/UI/Library/LibraryView.swift`

M0's version is a thin stub: an empty-state screen wired to `AppContainer`
so the environment-injection path is proven end to end, but with no real
querying logic (M1 replaces this).

```swift
// M0
import SwiftUI

struct LibraryView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No Podcasts Yet",
                systemImage: "books.vertical",
                description: Text("Search for a podcast or paste an RSS URL to subscribe.")
            )
            .navigationTitle("Library")
        }
    }
}
```

This is the "empty Library" screen referenced in the acceptance criteria
(§9) — it must render with zero crashes with only the mock services wired
up, since no real SwiftData query exists yet in M0.

### 5.6 `LingoPod/UI/Player/MiniPlayerView.swift`

```swift
// M0
import SwiftUI

/// M0 stub: renders nothing when no episode is loaded (which is always
/// true in M0, since there is no real playback yet). M2 replaces the body
/// with the real miniplayer bar driven by `container.playerEngine.state`.
struct MiniPlayerView: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        EmptyView()
    }
}
```

### 5.7 `LingoPodTests/LingoPodTests.swift`

A minimal smoke test proving `AppContainer` constructs without throwing.
Use Swift Testing to match `LingoPodKit`'s convention.

```swift
// M0
import Testing
import SwiftData
@testable import LingoPod

@MainActor
@Test func appContainerInitializes() {
    let container = AppContainer()
    #expect(container.modelContainer != nil)
}
```

(`ModelContainer` is non-optional in `AppContainer`, so `!= nil` is
trivially true — this test's real value is that construction doesn't
throw/crash; keep it simple. If Swift's type checker rejects comparing a
non-optional to `nil`, replace the assertion with
`#expect(container.playerEngine.state == .idle)` instead, which exercises
`PlaybackState`'s `Equatable` conformance too.)

---

## 6. Mock service implementations — exact behavior required

Every mock below must actually compile against `Interfaces.swift` (§4) and
behave predictably — these are not just `fatalError()` stubs, because
`RootView`/`LibraryView` (and later, ad hoc SwiftUI Previews other modules
write) will construct and read from them before real implementations
exist. Put them in `LingoPod/App/MockServices.swift`.

### 6.1 `MockCatalogService`

```swift
// M0
import Foundation
import SwiftData

/// Temporary stand-in for M1's real catalog service. Returns empty/no-op
/// results so the app builds and the Library/Search tabs render an empty
/// state instead of crashing. M1 deletes this type (or keeps it under
/// `#if DEBUG` for SwiftUI Previews — implementer's call) and wires the
/// real `CatalogService` into `AppContainer`.
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

enum MockServiceError: Error, LocalizedError {
    case notImplemented

    var errorDescription: String? {
        "This feature is not implemented yet (M0 scaffolding placeholder)."
    }
}
```

### 6.2 `MockPlayerEngine`

`PlayerEngineProtocol.load(episode:autoplay:)` takes a real `Episode`
(`@Model`), which M0's mock must accept without crashing even though no
real episode will ever be passed to it in M0 (`RootView`/`LibraryView`
never call `load` — there is nothing to play from an empty Library). Do not
special-case around the parameter type; just accept it and ignore it.

```swift
// M0
import Foundation
import Observation
import LingoPodKit

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
```

### 6.3 `MockTranslationService`

```swift
// M0
final class MockTranslationService: TranslationServiceProtocol {
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        throw MockServiceError.notImplemented
    }

    func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability {
        .unsupported
    }
}
```

### 6.4 `MockExplainService`

```swift
// M0
final class MockExplainService: ExplainServiceProtocol {
    var availability: ExplainAvailability {
        .unavailable(reason: "Not implemented yet.")
    }

    func explain(passage: String, context: String, sourceLanguage: Locale.Language,
                 targetLanguage: Locale.Language) -> AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: MockServiceError.notImplemented)
        }
    }
}
```

### 6.5 `MockTranscriptProvider`

```swift
// M0
import SwiftData

final class MockTranscriptProvider: TranscriptProviderProtocol {
    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        throw MockServiceError.notImplemented
    }

    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle {
        throw MockServiceError.notImplemented
    }
}
```

### 6.6 How later modules replace a mock (swap procedure)

Each of M1/M2/M5/M6 spec, when it lands, must:

1. Add its real service type in its own module directory (e.g. M5 adds
   `LingoPod/Intelligence/TranslationService.swift` implementing
   `TranslationServiceProtocol`).
2. Change exactly one line in `AppContainer.init()` — the assignment for
   that one property — to construct the real type instead of the mock
   (e.g. `self.translationService = TranslationService()`).
3. Leave every other mock and every other line of `AppContainer` untouched.
4. Not delete the `Mock*` type outright unless nothing else references it
   (some mocks are convenient for SwiftUI Previews in other modules — if a
   later module wants to keep using a mock for previews, it may move the
   mock type into a `#if DEBUG` block, but that is that module's call, not
   M0's).

M0's implementer does not need to do anything to enable this beyond
following §6.1–§6.5 exactly — this subsection is here so M0's implementer
understands *why* `AppContainer` is structured as one property per service
rather than, say, a single factory function.

---

## 7. AVAudioSession setup location

M0 does **not** configure or activate an `AVAudioSession`. This subsection
exists only to pin *where* that code will live so M2 doesn't have to
invent a location and so nothing in M0 conflicts with it later.

- File: `LingoPod/Playback/AudioSessionManager.swift` (new file, created by
  M2 — do not create it in M0).
- Category: `.playback` (not `.playAndRecord` — the app never records
  audio; on-device transcription in M3 reads a downloaded file via
  `AVAudioFile`, it does not tap a live microphone or the audio session).
- Activation timing: lazily, the first time `PlayerEngine.load(...)` is
  called — not at app launch — so cold launch to an empty Library never
  requests audio focus or interrupts other apps' audio.
- `UIBackgroundModes: [audio]` (already declared in M0's `project.yml`,
  §2) is what permits background playback once the session is active and
  playing; M2's spec must reference this Info.plist key rather than
  re-declaring it.

M0's acceptance criteria do **not** include any audio session behavior —
this is purely a placeholder note for module boundary clarity.

---

## 8. Directory conventions for downloaded audio

M0 does not download anything, but this convention must be pinned now
because `Episode.localAudioPath` (architecture §4) is a *relative* path and
every module that reads/writes it (M1 for downloads, M3 for reading the
file to transcribe) must agree on the base directory without re-deriving
it independently.

- Base directory: `Application Support/Episodes/` inside the app's
  container, i.e.
  `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("Episodes", isDirectory: true)`.
- Filename: `<sha256 of Episode.guid, hex-encoded>.mp3` — e.g.
  `3a7bd3e2360a3d...ff.mp3`. Using a hash of `guid` (not the raw guid)
  sidesteps filesystem-illegal characters that can appear in RSS guids
  (slashes, colons, unicode) and keeps filenames a fixed, predictable
  length.
  - Extension is always literally `.mp3` in v1 regardless of the source
    enclosure's actual container format. Rationale: podcast enclosures are
    overwhelmingly MP3 in practice, and normalizing the extension avoids
    plumbing MIME-type-to-extension mapping through the download path for
    v1. `// VERIFY`: if a later module (M1) actually encounters a
    non-MP3 enclosure in testing (e.g. AAC/M4A) that fails to play or
    transcribe under a `.mp3` extension, M1's spec must amend this
    convention (e.g. preserve source extension) and update this section
    accordingly — do not silently work around it per-file.
- `Episode.localAudioPath` stores the path **relative to** that base
  directory (i.e. just the filename, since files are not further
  nested) — never an absolute path, because the app container path
  changes between installs/OS upgrades on-device.
- Exclusion from iCloud backup: every file written under
  `Episodes/` must have its `URLResourceValues.isExcludedFromBackup` (aka
  `NSURLIsExcludedFromBackupKey`) set to `true` immediately after it's
  written. Rationale: downloaded audio is large, re-fetchable from the
  source feed, and Apple explicitly discourages backing up
  easily-re-downloadable bulk content. This is M1's responsibility to
  implement (the download code doesn't exist until M1); M0 only pins the
  convention and the flag name so M1 doesn't have to decide it.
- The `Episodes/` directory itself does not need to be created by M0 — M1
  creates it on first download (`createDirectory(at:withIntermediateDirectories: true)`).

---

## 9. `lingopod/README.md`

Create at repo root with this content:

```markdown
# LingoPod

A podcast player for language learners: on-device transcription,
lyrics-style synced transcript overlay, tap-to-translate, and
highlight-to-explain — all offline-capable, no accounts, no servers.

See `docs/00-product-overview.md` and `docs/01-architecture.md` for the
product and technical contract. Module specs live in `docs/specs/`.

## Prerequisites

- A Mac running **Xcode 26** or later (iOS 26 SDK; Swift 6).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), installed via
  Homebrew:

  ```sh
  brew install xcodegen
  ```

- No other third-party tooling or dependencies are required — this project
  intentionally has zero third-party Swift packages (see
  `docs/01-architecture.md` §1).

## Building and running the app

This repository does **not** commit an `.xcodeproj` — it's generated from
`project.yml`. Every time you pull changes that touch `project.yml`, or
before your first build, regenerate the project:

```sh
cd lingopod
xcodegen generate
```

This produces `LingoPod.xcodeproj`. Open it:

```sh
open LingoPod.xcodeproj
```

Select the `LingoPod` scheme and an iOS 26+ simulator (or a device), then
Run (⌘R). On first launch you should land on an empty Library tab with a
Search tab alongside it.

`LingoPod.xcodeproj` and the `Generated/` directory (which holds the
XcodeGen-produced Info.plist and entitlements) are build artifacts and are
git-ignored — see `.gitignore`. Never hand-edit generated files; edit
`project.yml` and re-run `xcodegen generate`.

## Running app-target tests

With the project open in Xcode: ⌘U on the `LingoPod` scheme runs both the
app's `LingoPodTests` and (if your XcodeGen version wires it up — see
`docs/specs/M0-scaffolding.md` §2) `LingoPodKitTests`.

## Running LingoPodKit tests (no Xcode project needed)

`LingoPodKit` is a self-contained SwiftPM package with no UIKit/SwiftUI
imports, so its tests run without generating or opening the Xcode project,
and without booting a simulator:

```sh
cd lingopod/LingoPodKit
swift test
```

This is the fastest inner loop for logic covered by `LingoPodKit`
(feed/transcript parsing, segmentation, cache-key math, etc. — see
`docs/01-architecture.md` §9) and is also runnable in CI or any Linux/Mac
box with a Swift 6 toolchain, independent of Xcode.

## Repository layout

See `docs/01-architecture.md` §2 for the full annotated tree.
```

Also create `lingopod/.gitignore` at the repo root with at least:

```
# XcodeGen output
*.xcodeproj/
Generated/

# Xcode
xcuserdata/
*.xcuserstate
DerivedData/

# SwiftPM
.build/
.swiftpm/
```

(This file wasn't explicitly requested in the module scope list but is
required for the "generated files aren't committed" rule in architecture
§1 to actually hold — create it as part of M0.)

---

## 10. `LingoPod/Resources/Assets.xcassets` and Localizable notes

### 10.1 Assets.xcassets

Create the folder-based asset catalog structure XcodeGen/Xcode expects:

`LingoPod/Resources/Assets.xcassets/Contents.json`:
```json
{
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

`LingoPod/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images": [
    {
      "idiom": "universal",
      "platform": "ios",
      "size": "1024x1024"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

Leave the actual 1024×1024 icon PNG unfilled in M0 (no `filename` key, no
image file committed) — Xcode will show a warning about a missing app icon
image, which is expected and acceptable for scaffolding; a real icon is a
product/design asset to be supplied later, out of scope for any module
spec. Do not block M0 on it.

`LingoPod/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`:
```json
{
  "colors": [
    {
      "idiom": "universal"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  }
}
```

Leave the accent color at system default (no explicit color values) — this
is a placeholder single-color asset so `ASSETCATALOG_COMPILER_APPICON_NAME`
and accent-color references in project settings resolve without warnings;
product/design picks the real brand color later.

### 10.2 Localizable notes

Create an empty `LingoPod/Resources/Localizable.xcstrings` string catalog
so the file exists and is wired into the target (String Catalogs are the
modern, Xcode-15+/26 default for localization — do not create a legacy
`Localizable.strings` file instead):

```json
{
  "sourceLanguage" : "en",
  "strings" : {

  },
  "version" : "1.0"
}
```

Notes for future modules (not implemented in M0):
- The product overview specifies the **device/UI language is the user's
  native language**; the podcast content language is separate and tracked
  per-`Podcast`/`Episode` (architecture §4 `languageCode`/
  `languageOverride`). Do not conflate the two: `Localizable.xcstrings`
  covers UI chrome strings (button labels, empty states, etc.) in
  whatever languages the app is localized into eventually — it has
  nothing to do with target-language transcript/translation content.
  M0 ships zero localized strings; all UI strings introduced by M0 (e.g.
  "Library", "Search", "No Podcasts Yet") are plain Swift string literals,
  not yet extracted into the catalog. Extracting them is future
  polish, not blocking for any module through M6.
- If a later module wants compiler-checked localized strings, it should
  add entries to this same `Localizable.xcstrings` file rather than
  creating additional catalogs — one catalog for the whole app target.

---

## 11. Acceptance criteria checklist

M0 is complete when all of the following are true:

**Files exist exactly as specified:**
- [ ] `lingopod/project.yml` present, matches §2 (bundle id
      `com.lingopod.app`, deployment target `26.0`, Swift 6 strict
      concurrency settings, `LingoPodKit` package dependency, app +
      `LingoPodTests` targets, Info.plist keys including
      `UIBackgroundModes: [audio]` and
      `NSSpeechRecognitionUsageDescription`, `NSAllowsArbitraryLoads` is
      `false` or absent).
- [ ] `lingopod/.gitignore` excludes `*.xcodeproj/`, `Generated/`,
      `DerivedData/`, `.build/`, `.swiftpm/`.
- [ ] `lingopod/README.md` present, matches §9 content/structure.
- [ ] `lingopod/LingoPodKit/Package.swift` present, `swift-tools-version:
      6.0`, `.iOS(.v26)` platform, one library target, one test target.
- [ ] `LingoPodKit/Sources/LingoPodKit/LingoPodKit.swift` and
      `LingoPodKit/Tests/LingoPodKitTests/LingoPodKitTests.swift` present.
- [ ] `LingoPod/App/Interfaces.swift` present and contains, verbatim, all
      six protocols from architecture §5 plus every supporting
      enum/struct listed in §4 of this spec (`PlaybackState`,
      `EquatableError`, `DownloadState`, `TranscriptSource`,
      `TranscriptState`, `TranslationAvailability`, `ExplainAvailability`,
      `TranscriptSegmentSnapshot`, `WordTiming`, `PodcastSearchResult`).
- [ ] `LingoPod/App/LingoPodApp.swift`, `AppContainer.swift`,
      `RootView.swift` present per §5.
- [ ] `LingoPod/App/MockServices.swift` (or mocks inlined in
      `AppContainer.swift`) present per §6, implementing all five service
      protocols (`CatalogServiceProtocol`, `PlayerEngineProtocol`,
      `TranslationServiceProtocol`, `ExplainServiceProtocol`,
      `TranscriptProviderProtocol`).
- [ ] `LingoPod/UI/Library/LibraryView.swift`,
      `LingoPod/UI/Player/MiniPlayerView.swift` present per §5.5/§5.6.
- [ ] `LingoPod/Resources/Assets.xcassets` present with `AppIcon` and
      `AccentColor` placeholder entries; `Localizable.xcstrings` present
      and empty per §10.
- [ ] `LingoPodTests/LingoPodTests.swift` present per §5.7.

**Behavioral (manual verification script, run on a Mac — §12):**
- [ ] `xcodegen generate` succeeds with zero errors from repo root
      (`lingopod/`).
- [ ] The generated project opens in Xcode without "recovered project"
      warnings.
- [ ] The `LingoPod` scheme builds for an iOS 26 simulator with zero
      errors. Warnings about the missing app-icon image (§10.1) are
      expected and acceptable; no other warnings should reference missing
      files.
- [ ] The app launches in the simulator to the Library tab showing the
      "No Podcasts Yet" empty state, with no crash.
- [ ] Tapping the Search tab switches to it and shows the "Search" empty
      state, with no crash.
- [ ] No miniplayer bar is visible in the empty state (since
      `MiniPlayerView` renders `EmptyView()` and no episode is loaded).
- [ ] `swift test` inside `lingopod/LingoPodKit/` passes (1 test).
- [ ] ⌘U on the `LingoPod` scheme runs `LingoPodTests` and it passes
      (`appContainerInitializes`).

**Code quality / conventions (architecture §10):**
- [ ] Every new Swift file begins with a `//` header naming its module ID
      (`// M0`).
- [ ] No `try!`, no force unwraps outside of the one documented
      `fatalError` in `AppContainer.init()`'s `ModelContainer` construction
      (a `fatalError` there is acceptable and intentional — an
      unconstructible model container is unrecoverable at launch — but it
      must be the only one, and it must not be a bare force-unwrap).
      `// VERIFY`: if reviewers prefer no `fatalError` at all, replace with
      a launch-time `PreconditionFailure`-style crash with a clearer
      message; either is acceptable, silent failure is not.
  - [ ] No `print(...)` anywhere; not applicable in M0 since nothing logs
      yet, but confirm none was added incidentally.
- [ ] `Interfaces.swift` types are not redefined anywhere else in the
      codebase (single source of truth).

## 12. Manual verification script

Run on a Mac with Xcode 26+ and XcodeGen installed.

1. `cd lingopod && xcodegen generate` — expect a success message and a new
   `LingoPod.xcodeproj` directory. No errors.
2. `open LingoPod.xcodeproj`.
3. In Xcode, select scheme `LingoPod`, destination: any iOS 26.x
   simulator (e.g. iPhone 17).
4. Product → Build (⌘B). Expect build succeeded, 0 errors. Note any
   warnings; only the AppIcon-missing-image warning is expected.
5. Product → Run (⌘R). Expect the simulator to launch the app and show a
   two-tab UI: "Library" (books icon) selected by default, showing
   "No Podcasts Yet" / "Search for a podcast or paste an RSS URL to
   subscribe."; "Search" (magnifying-glass icon) alongside it.
6. Tap the Search tab. Expect "Search" / "Podcast search will appear
   here." with no crash, no console errors.
7. Tap back to Library. Expect the empty state again, unchanged.
8. Confirm no bar/overlay is visible at the bottom of the screen beyond
   the system tab bar (miniplayer slot is empty).
9. Product → Test (⌘U). Expect `LingoPodTests.appContainerInitializes` to
   pass. If `LingoPodKitTests` is wired into the scheme (§2), expect
   `scaffoldVersionIsSet` to pass too.
10. In Terminal: `cd lingopod/LingoPodKit && swift test`. Expect
    `Test Suite 'All tests' passed` with 1 test.
11. Open Console.app or Xcode's console pane during step 5–7; confirm no
    crash logs, no unhandled exceptions, no SwiftData migration errors.

If any step fails, M0 is not complete — fix and re-run the whole script
before handing off to M1.
