# M5 — Translation Service

Status: spec ready for implementation
Depends on: M0 (DI container, RootView, project scaffolding)
Consumed by: M4 (transcript overlay UI) via `TranslationServiceProtocol` (architecture §5.3)
Source location: `LingoPod/Intelligence/` (app target) + a small pure-logic slice in `LingoPodKit/Sources/LingoPodKit/Translation/`

This spec is binding together with `docs/00-product-overview.md` and
`docs/01-architecture.md`. It does not contradict `01-architecture.md`; where
it adds a type or file not named there, that is called out explicitly as an
**addition**, not a deviation. Every source file you create starts with a
`// M5` header comment per architecture §10.

---

## 1. What this module is and isn't

**Is:** a translation service for single words / short phrases tapped in the
transcript overlay, backed by Apple's on-device `Translation` framework, with
a SwiftData-backed cache so repeated/offline lookups are instant.

**Isn't:**
- Not a general translation UI. M5 has no views except one invisible plumbing
  view (`TranslationHostView`, §3). All buttons, banners, and copy live in M4.
- Not responsible for the LLM fallback when a language pair is unsupported —
  that's M6's concern per architecture §6.2. M5 only reports `.unsupported`.
- Not responsible for resolving *which* languages to pass in. M4 (or a
  shared helper) resolves `source`/`target` `Locale.Language` values and
  passes them into `TranslationServiceProtocol.translate`. See §4 for the
  recommended resolution order (guidance only — M5 does not read
  `Podcast`/`Episode`/`Transcript` models).

---

## 2. Public interface (unchanged from architecture §5.3)

```swift
// M5
protocol TranslationServiceProtocol: Sendable {
  /// Checks cache first. `source` is the podcast language, `target` the user's.
  func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String
  func availability(from: Locale.Language, to: Locale.Language) async -> TranslationAvailability
}

enum TranslationAvailability: Sendable {
  case ready
  case needsDownload
  case unsupported
}
```

Do not change this protocol's shape. If you find you must, stop and update
`01-architecture.md` §5.3 and `LingoPod/App/Interfaces.swift` in the same
commit, per the architecture doc's own rule (§0 preamble).

### 2.1 Addition: the download seam

`TranslationServiceProtocol` deliberately has no `prepare`/`download` method
— keeping it minimal is what lets M4 build against a trivial mock from day
one (module map, §3: "M4 ... can be built against protocol mocks"). But M4
needs a way to trigger a language-pack download from a button
("Download French ↔ English"). Two options were on the table:

- **(a)** M4 downcasts `AppContainer`'s service to the concrete
  `TranslationService` type to call a `prepare(from:to:)` method that lives
  only on the concrete class.
- **(b)** Add a second, narrow protocol just for this seam, and have the
  concrete service conform to both.

**Decision: (b).** A downcast defeats the "M4 builds against mocks" promise
in the module map — M4's tests would need the concrete Translation-framework
type or a cast-friendly fake, either way leaking framework details into M4's
test surface. A second protocol keeps M4 100% protocol-based and still
trivially mockable, at the cost of one extra type. This is an **addition**
to §5.3, not a change to it — `TranslationServiceProtocol` itself is
untouched.

```swift
// M5 — addition to architecture §5.3, lives in LingoPod/App/Interfaces.swift
// alongside TranslationServiceProtocol.
protocol TranslationDownloadPreparing: Sendable {
  /// Triggers the system language-pack download flow for this pair (or
  /// no-ops if already installed). Throws TranslationError.unsupportedLanguagePair
  /// or TranslationError.downloadRequiresNetwork as appropriate (see §8).
  func prepareDownload(from source: Locale.Language, to target: Locale.Language) async throws
}
```

`AppContainer` (M0) exposes both, backed by the same instance:

```swift
// M0's AppContainer, illustrative — M5 just requires these two properties exist.
let translationService: TranslationService          // concrete instance, created once
var translationServiceProtocol: TranslationServiceProtocol { translationService }
var translationDownloadCoordinator: TranslationDownloadPreparing { translationService }
```

M4's UI code depends on `TranslationServiceProtocol` for the translate path
and `TranslationDownloadPreparing` for the download button — both are
narrow, both are easy to mock, neither exposes `TranslationService` itself.

---

## 3. The core problem: adapting `.translationTask` to an async service

Apple's `TranslationSession` cannot be constructed directly. The only way to
get one is the SwiftUI modifier:

```swift
func translationTask(
  _ configuration: TranslationSession.Configuration?,
  action: @escaping (TranslationSession) async -> Void
) -> some View
```

`action` fires (and any previous invocation is cancelled) whenever
`configuration` changes identity/value, and whenever the view (re)appears
with a non-nil configuration. The closure receives a live `TranslationSession`
for as long as the view stays mounted and the configuration doesn't change.
Everything in this module exists to bridge that view-lifecycle-scoped,
callback-shaped API to the plain `async throws -> String` shape M4 needs.

### 3.1 `TranslationHostView` — the adapter view

A single, permanently-mounted, zero-size, invisible view. **M0's `RootView`
mounts exactly one `TranslationHostView()` for the lifetime of the app** —
not inside the transcript overlay. Reason: the overlay can be dismissed and
re-presented at will (product overview: tap-to-seek, tap word, highlight are
all overlay-scoped, but the overlay itself is a modal/full-screen state that
toggles), and if the host view came and went with it, any in-flight
translation request live when the overlay closes would be silently
abandoned. Mounting at the root decouples the translation pipeline's
lifetime from any one screen's presentation state. (If M0's `RootView` has
already been implemented without this hook by the time you read this, add
one line: `RootView(...).background(TranslationHostView())` or an
equivalent always-mounted placement — do not nest it inside conditional
navigation content.)

```swift
// M5 — LingoPod/Intelligence/TranslationHostView.swift
struct TranslationHostView: View {
  @Environment(AppContainer.self) private var container

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .translationTask(container.translationService.pendingConfiguration) { session in
        await container.translationService.run(session: session)
      }
  }
}
```

Notes:
- **Do not use `.hidden()`.** Whether a `.hidden()` view keeps running its
  task modifiers is not something to rely on; a `Color.clear` with a `0×0`
  frame is unambiguously still "in the tree" and still runs `.translationTask`.
- `pendingConfiguration` is a plain `@Observable` property read directly off
  `TranslationService` — **not** a separate `@State` owned by this view.
  SwiftUI re-evaluates `body` when an `@Observable` dependency changes, and
  `.translationTask` restarts its closure when the configuration value it's
  given changes. Piping the value straight from the service avoids a second
  copy of "what language pair is active" that could drift out of sync with
  the queue. (If you find this doesn't trigger re-invocation reliably on the
  SDK you're building against, fall back to local `@State` synced via
  `.onChange(of:)` — but try the direct-read form first; it's simpler and is
  the documented mechanism for value-driven `.translationTask`.)
- `container.translationService.run(session:)` is where all queue-draining
  work in §3.3 happens. When SwiftUI cancels the previous task (because
  `pendingConfiguration` changed or the view left the hierarchy), `run`'s
  `Task` is cancelled cooperatively — see §3.4 for what that means for
  in-flight requests.

### 3.2 `TranslationService` — actor choice and justification

```swift
// M5 — LingoPod/Intelligence/TranslationService.swift
@MainActor
@Observable
final class TranslationService: TranslationServiceProtocol, TranslationDownloadPreparing {
  private(set) var pendingConfiguration: TranslationSession.Configuration?
  // ... queue state, §3.3
}

// TranslationServiceProtocol requires Sendable. Swift does not synthesize
// Sendable for classes (even @MainActor ones) as of the Swift 6 language
// mode this project targets, so conformance must be declared explicitly.
// This is safe because every stored mutable property below is only ever
// touched while isolated to the main actor — there is no unsynchronized
// state. // VERIFY(iOS26): if a future toolchain accepts @MainActor classes
// as implicitly Sendable, drop the @unchecked and this comment.
extension TranslationService: @unchecked Sendable {}
```

**Decision: `@MainActor @Observable` class, not `actor`.** Justification:

1. `TranslationHostView` is a SwiftUI view — inherently `@MainActor`. Its
   `.translationTask` closure runs on the main actor. If `TranslationService`
   were a plain `actor`, every interaction between the closure and the
   service's queue state would require an actor hop, and — worse — the
   service would need some *other* mechanism (an `AsyncStream`, a delegate
   callback) to tell the SwiftUI layer "the desired configuration changed,"
   because a plain `actor`'s properties aren't observable by SwiftUI. That
   indirection buys nothing here.
2. Every call site that invokes `translate(_:from:to:)` is itself
   `@MainActor` (M4's tap/selection gesture handlers run on the main actor
   per architecture §7: "UI and PlayerEngine are @MainActor"). So there's no
   real cross-actor traffic to protect against by isolating this type
   separately.
3. The one genuinely CPU/IO-bound piece — SwiftData cache reads/writes — is
   already pulled into its own `ModelActor` (`TranslationCacheStore`, §6),
   matching architecture §7's rule that heavy work happens in `ModelActor`s,
   not that every service must itself be an `actor`.
4. Request volume is inherently low (word/phrase taps, human-paced), so
   there is no contention concern that would justify actor isolation purely
   for throughput.

If a future revision needs `TranslationService` reachable from a
non-main-actor context, revisit this — but nothing in the current module map
requires it.

### 3.3 Request queue and coalescing

`translate(_:from:to:)` never talks to a `TranslationSession` directly. It:

1. Rejects same-language requests (§4).
2. Checks the cache (§6) — on a hit, returns immediately, no session
   involved at all.
3. Checks availability (§5) — throws a typed error fast if not `.ready`
   (§8); never blocks waiting for a download inline.
4. Enqueues a request and awaits its result.

```swift
// M5 — sketch, not literal final code; fill in per notes below.
struct PendingTranslationRequest: Sendable {
  let id: UUID
  let text: String
  let pair: LanguagePair          // struct { source: Locale.Language; target: Locale.Language }, Hashable
}

@MainActor @Observable
final class TranslationService: TranslationServiceProtocol, TranslationDownloadPreparing {
  private(set) var pendingConfiguration: TranslationSession.Configuration?

  private var queue: [PendingTranslationRequest] = []
  private var continuations: [UUID: CheckedContinuation<String, Error>] = [:]
  private var flushScheduled = false
  private var activePair: LanguagePair?
  private var currentSession: TranslationSessionProtocol?
  private var sessionWaiters: [LanguagePair: [CheckedContinuation<TranslationSessionProtocol, Never>]] = [:]

  private let cache: TranslationCacheStore
  private let coalesceWindow: Duration = .milliseconds(100)
  private let maxBatchSize = 20
  private let logger = Logger(subsystem: "com.lingopod.app", category: "Translation")

  func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
    guard !isSameLanguage(source, target) else { throw TranslationError.sameLanguage }

    let key = TranslationCacheKey.make(text: text, source: source.minimalIdentifier, target: target.minimalIdentifier)
    if let cached = await cache.lookup(key: key) { return cached }

    switch await availability(from: source, to: target) {
    case .unsupported: throw TranslationError.unsupportedLanguagePair
    case .needsDownload: throw TranslationError.languagePackNeedsDownload
    case .ready: break
    }

    let pair = LanguagePair(source: source, target: target)
    activateConfigurationIfNeeded(for: pair)

    let text = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
      let id = UUID()
      queue.append(.init(id: id, text: text, pair: pair))
      continuations[id] = cont
      scheduleFlush(for: pair)
    }
    await cache.store(key: key, sourceText: text, translatedText: text,
                       sourceLanguage: source.minimalIdentifier, targetLanguage: target.minimalIdentifier)
    return text
  }
}
```

**Coalescing rule (spelled out precisely):** when the first request for a
given `pair` is enqueued and no flush is already scheduled for that pair,
start a timer for `coalesceWindow` (100ms). Any further requests for the
*same pair* that arrive before the timer fires join the same batch. When the
timer fires, drain up to `maxBatchSize` (20) queued requests for that pair
into a single call to the session adapter's batch method (§3.5); if more
than 20 are queued, immediately schedule another flush for the remainder —
do not grow a single batch unbounded. Requests for a *different* pair get
their own independent timer (in practice this is rare — source is fixed per
podcast, target is fixed to the device locale, so pair changes correspond to
switching to a different-language podcast mid-session).

**Configuration activation:** `activateConfigurationIfNeeded(for:)` sets
`pendingConfiguration = TranslationSession.Configuration(source: pair.source, target: pair.target)`
only if `activePair != pair`. This mutation is what causes
`TranslationHostView`'s `.translationTask` to restart with a fresh session
for the new pair. If `activePair == pair` already, do nothing — the running
`run(session:)` loop for that pair will pick up the newly-queued request on
its next wake (see §3.4).

### 3.4 The host loop: `run(session:)`

```swift
// M5
func run(session: TranslationSession) async {
  let adapter = LiveTranslationSession(session: session)
  let pair = LanguagePair(source: session.sourceLanguage, target: session.targetLanguage) // VERIFY(iOS26): confirm TranslationSession exposes its resolved source/target languages this way; if not, thread `pair` through from activateConfigurationIfNeeded via a side table keyed by the Configuration you set, since Configuration itself carries the languages you originally requested.
  activePair = pair
  currentSession = adapter
  resumeWaiters(for: pair, with: adapter)

  await withTaskCancellationHandler {
    while !Task.isCancelled {
      await waitForWork(on: pair)
      guard !Task.isCancelled else { break }
      try? await Task.sleep(for: coalesceWindow)   // coalescing window
      guard !Task.isCancelled else { break }
      await flush(pair: pair, using: adapter)
    }
  } onCancel: {
    // Requests still queued for this pair when cancelled are left in
    // `queue` — if the same pair becomes active again later they'll be
    // served then. Do NOT fail them here; only fail them if the service
    // itself is torn down (not expected during normal app lifetime).
  }

  if activePair == pair { activePair = nil; currentSession = nil }
}
```

`waitForWork(on:)` suspends until `scheduleFlush(for: pair)` signals there's
something to do (a private `AsyncStream<Void>` or a stored
`CheckedContinuation<Void, Never>` resumed by `scheduleFlush` is fine — pick
one, keep it internal). `flush(pair:using:)` drains up to `maxBatchSize`
queued requests matching `pair`, calls
`adapter.performBatch(_:)` (§3.5), and resumes the corresponding
continuations with the result or the error. On success for each item, the
caller side (`translate`, §3.3) is the one that writes through to the cache
— `flush` only resumes continuations, it does not touch SwiftData.

### 3.5 `TranslationSessionProtocol` — the framework seam for testability

Wrapping every real `TranslationSession` call behind a protocol is what
makes the coalescing/queue logic unit-testable without booting the
Translation framework (architecture §9: "framework-touching seams ... are
wrapped in thin protocols").

```swift
// M5 — LingoPod/Intelligence/TranslationSessionProtocol.swift
protocol TranslationSessionProtocol: Sendable {
  /// Returns translated text keyed by request id (as a string). Any id
  /// missing from the result is treated as a per-item failure by the caller.
  func performBatch(_ requests: [PendingTranslationRequest]) async throws -> [String: String]
}

struct LiveTranslationSession: TranslationSessionProtocol {
  let session: TranslationSession

  func performBatch(_ requests: [PendingTranslationRequest]) async throws -> [String: String] {
    // VERIFY(iOS26): confirm exact batch API name/shape. Documented shape
    // as of this writing: TranslationSession.Request(sourceText:clientIdentifier:)
    // and `session.translations(from: [TranslationSession.Request]) async throws
    // -> [TranslationSession.Response]`, where Response exposes `.targetText`
    // and `.clientIdentifier`. If the real signature differs, this is the
    // only function that needs to change.
    let reqs = requests.map {
      TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id.uuidString)
    }
    let responses = try await session.translations(from: reqs)
    var out: [String: String] = [:]
    for r in responses {
      if let cid = r.clientIdentifier { out[cid] = r.targetText }
    }
    return out
  }
}
```

For a single queued item (batch of one), the same call path is fine — don't
special-case single-item translation with `session.translate(_:)`; one code
path is easier to reason about and to test.

`MockTranslationSession` (test-only, lives in the app-target test target)
implements `TranslationSessionProtocol` with a script of canned
responses/errors and a call-count/call-args recorder, used to assert
coalescing behavior (§9).

---

## 4. Language resolution and the same-language guard

M5 receives already-resolved `Locale.Language` values; it does not read
`Podcast`, `Episode`, or `Transcript` models. (§4 note below flags that the
resolution order isn't specified anywhere in the architecture doc — this is
guidance for whoever implements the M4 call site, not a requirement M5
enforces.)

**Recommended resolution order for the caller (M4):**
1. `Transcript.languageCode` (architecture §4: non-optional, "BCP-47
   actually used") if a transcript exists for the current episode — this is
   authoritative because it reflects what was actually transcribed/matched.
2. Else `Podcast.languageOverride ?? Podcast.languageCode` (both optional).
3. If both are `nil`, M4 should not offer the tap-to-translate affordance at
   all — there is no source language to translate from.

Convert the BCP-47 string to `Locale.Language(identifier:)`. Target is
always `Locale.current.language` (product overview: "device/UI language is
their native language").

**Same-language guard:** compare `source.languageCode?.identifier ==
target.languageCode?.identifier` — deliberately ignoring script/region, so
e.g. `fr-FR` vs `fr-CA` still counts as "same language" for this purpose
(translating within the same language is never useful here). If equal,
`translate(_:from:to:)` throws `TranslationError.sameLanguage` immediately,
before touching the cache or the queue. M4's job is to check this
*proactively* (compare the two identifiers itself) and hide the
tap-to-translate affordance entirely when source == target, so this error
path should rarely if ever fire in practice — it exists as a defensive
guard, not a primary UX signal.

---

## 5. Availability and the download UX seam

```swift
// M5
func availability(from source: Locale.Language, to target: Locale.Language) async -> TranslationAvailability {
  // VERIFY(iOS26): confirm exact type/method name. Documented shape:
  // LanguageAvailability().status(from:to:) async -> LanguageAvailability.Status
  // with cases .installed, .supported, .unsupported.
  let status = await LanguageAvailability().status(from: source, to: target)
  switch status {
  case .installed:   return .ready
  case .supported:   return .needsDownload
  case .unsupported: return .unsupported
  @unknown default:  return .unsupported
  }
}
```

This call does **not** require a `TranslationSession` — it's a standalone
availability check, so M4 can show/hide the translate affordance and the
"download language" banner without triggering the host-view machinery at
all.

**`prepareDownload(from:to:)`** (the seam from §2.1) is what M4's "Download
French ↔ English" button calls:

```swift
// M5
func prepareDownload(from source: Locale.Language, to target: Locale.Language) async throws {
  guard await availability(from: source, to: target) != .unsupported else {
    throw TranslationError.unsupportedLanguagePair
  }
  guard NWPathMonitor.currentPathIsSatisfied() else {   // see note below
    throw TranslationError.downloadRequiresNetwork
  }
  let pair = LanguagePair(source: source, target: target)
  activateConfigurationIfNeeded(for: pair)
  let adapter = await waitForSession(matching: pair)
  // VERIFY(iOS26): confirm TranslationSession exposes prepareTranslation();
  // documented shape: `try await session.prepareTranslation()` triggers the
  // system's pack-download prompt/sheet for the session's configured pair.
  try await adapter.prepareTranslation()
}
```

`NWPathMonitor.currentPathIsSatisfied()` is shorthand for: hold a single
`NWPathMonitor` (Network framework, first-party, no third-party dependency
introduced) started at service init, and read its last-known
`currentPath.status == .satisfied`. This lets `prepareDownload` fail fast
with `.downloadRequiresNetwork` without ever touching the Translation
framework when the device is known offline, rather than waiting for an
ambiguous framework-level error. If the device *appears* online but the
download still fails (captive portal, mid-download drop), surface that as
`TranslationError.sessionUnavailable` from the `catch` around
`prepareTranslation()` — don't try to distinguish further; the manual
verification script (§10) covers the offline case explicitly with airplane
mode, which `NWPathMonitor` will catch reliably.

`waitForSession(matching:)` returns immediately if `currentSession` already
matches `pair`; otherwise it registers a continuation in `sessionWaiters[pair]`
that `run(session:)` resumes once it activates for that pair (§3.4,
`resumeWaiters`).

---

## 6. Cache

### 6.1 Model (unchanged, architecture §4)

```swift
@Model final class TranslationCacheEntry {
  @Attribute(.unique) var key: String  // "\(sourceLang)|\(targetLang)|\(normalizedText)"
  var sourceText: String
  var translatedText: String
  var sourceLanguage: String; var targetLanguage: String
  var createdAt: Date
}
```

This model already lives in `LingoPodKit/Sources/LingoPodKit/Models/` per
architecture §2/§4 — M5 does not redefine it, only reads/writes it.

### 6.2 Key normalization (pure logic — **addition**: new file under
`LingoPodKit/Sources/LingoPodKit/Translation/`, mirroring the existing
`Feeds/`/`Transcripts/` pattern for pure, `swift test`-runnable logic)

```swift
// M5 — LingoPodKit/Sources/LingoPodKit/Translation/TranslationCacheKey.swift
import Foundation

public enum TranslationCacheKey {
  /// NFC-normalize, lowercase, collapse internal whitespace runs to a
  /// single space, then trim leading/trailing whitespace and punctuation.
  /// Trimming only affects the ends of the string — "geht's" keeps its
  /// internal apostrophe; "¿Cómo estás?" becomes "cómo estás".
  public static func normalize(_ text: String) -> String {
    let nfc = text.precomposedStringWithCanonicalMapping
    let lowered = nfc.lowercased()
    let collapsed = lowered.replacingOccurrences(
      of: "\\s+", with: " ", options: .regularExpression)
    let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
    return collapsed.trimmingCharacters(in: trimSet)
  }

  /// Matches the `TranslationCacheEntry.key` format in architecture §4
  /// exactly: "\(sourceLang)|\(targetLang)|\(normalizedText)". `source`/
  /// `target` are caller-supplied identifiers (use `Locale.Language.minimalIdentifier`
  /// at the call site — kept as plain Strings here so this file stays
  /// Foundation-only and platform-agnostic per architecture §1).
  public static func make(text: String, source: String, target: String) -> String {
    "\(source)|\(target)|\(normalize(text))"
  }
}
```

### 6.3 LRU-ish pruning (also pure logic, same file or a sibling)

```swift
// M5 — LingoPodKit/Sources/LingoPodKit/Translation/TranslationCachePruning.swift
import Foundation

public enum TranslationCachePruning {
  /// Given all entries' (key, createdAt), returns the keys to delete so the
  /// store drops from `cap` back down to `target`, oldest-createdAt-first.
  /// Returns [] if `entries.count <= cap`.
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
```

Pruning happens in batches (evict down to 4500 whenever the count exceeds
5000), not on every single insert — amortizes the cost of the delete pass.

### 6.4 `TranslationCacheStore` — the `ModelActor` (app target)

```swift
// M5 — LingoPod/Intelligence/TranslationCacheStore.swift
@ModelActor
actor TranslationCacheStore {
  func lookup(key: String) async -> String? {
    // fetch TranslationCacheEntry where key == key; return translatedText
  }

  func store(key: String, sourceText: String, translatedText: String,
             sourceLanguage: String, targetLanguage: String) async {
    // insert (or overwrite, since key is @Attribute(.unique)); save
    await pruneIfNeeded()
  }

  private func pruneIfNeeded() async {
    // fetch [(key, createdAt)] for all entries (lightweight projection if
    // SwiftData's fetch API allows it, else fetch full objects), call
    // TranslationCachePruning.keysToEvict, delete matches, save.
  }
}
```

All cache I/O happens off the main actor via this `ModelActor`, per
architecture §7. `TranslationService.translate` awaits it — this is the one
legitimate actor hop in the whole module, and it's already how architecture
§7 says heavy SwiftData work should be isolated.

---

## 7. File layout summary

```
LingoPodKit/Sources/LingoPodKit/Translation/     # addition, mirrors Feeds/, Transcripts/
  TranslationCacheKey.swift
  TranslationCachePruning.swift
LingoPodKit/Tests/LingoPodKitTests/
  TranslationCacheKeyTests.swift
  TranslationCachePruningTests.swift

LingoPod/Intelligence/
  TranslationHostView.swift
  TranslationService.swift
  TranslationSessionProtocol.swift        # protocol + LiveTranslationSession
  TranslationError.swift
  TranslationCacheStore.swift

LingoPod/App/Interfaces.swift              # add TranslationDownloadPreparing here (§2.1)

<app test target>/Intelligence/            # exact target name set by M0's project.yml
  TranslationQueueTests.swift              # uses MockTranslationSession
```

---

## 8. Failure taxonomy and user-facing copy

Per architecture §8: typed states, not alerts; one actionable button where
possible; M5 defines the enum and recommended copy, M4 renders it as an
inline banner in the overlay.

```swift
// M5 — LingoPod/Intelligence/TranslationError.swift
enum TranslationError: Error, Sendable, Equatable {
  case sameLanguage
  case unsupportedLanguagePair
  case languagePackNeedsDownload
  case downloadRequiresNetwork
  case sessionUnavailable(reason: String)   // wraps unexpected framework errors; String only, stays Sendable
  case cancelled
}
```

| Case | When | Suggested copy (M4 renders) | Action button |
|---|---|---|---|
| `.sameLanguage` | Defensive guard fired (M4 should have hidden the affordance already) | (no banner — silently no-op / log at debug level) | — |
| `.unsupportedLanguagePair` | `LanguageAvailability` reports `.unsupported` | "Translation isn't available for {source} → {target}." | none (M6's LLM Explain fallback is a separate affordance, not M5's job to surface here) |
| `.languagePackNeedsDownload` | `LanguageAvailability` reports `.supported` (not yet installed) | "Download {source} ↔ {target} to translate" | "Download" → calls `prepareDownload(from:to:)` |
| `.downloadRequiresNetwork` | `prepareDownload` called while offline | "Connect to the internet to download the {source} ↔ {target} language pack." | "Retry" (re-invokes `prepareDownload`) |
| `.sessionUnavailable` | Any unexpected framework error, batch failure with no matching response id, etc. | "Translation failed. Try again." | "Retry" |
| `.cancelled` | Request's `Task` was cancelled (e.g. user dismissed overlay mid-lookup) | (no banner — this is expected, not a failure) | — |

Unexpected/unmapped errors log via `os.Logger(subsystem: "com.lingopod.app",
category: "Translation")` per architecture §8/§10 — never `print`.

---

## 9. Unit tests

All of the following are deterministic, framework-free, and belong to the
categories architecture §9 calls out ("real unit tests" for `LingoPodKit`
logic; "constructor-injected dependencies" + mock framework seams for
app-target services).

**`LingoPodKitTests` (pure logic, `swift test`):**
- `TranslationCacheKeyTests`:
  - `normalize` lowercases and NFC-normalizes (e.g. combining-character vs.
    precomposed accented input produce the same output).
  - `normalize` trims leading/trailing punctuation and whitespace but
    preserves internal punctuation (`"Wie geht's?"` → `"wie geht's"`).
  - `normalize` collapses internal multi-space/newline runs to one space.
  - `make` produces exactly `"\(source)|\(target)|\(normalizedText)"`.
- `TranslationCachePruningTests`:
  - Under cap → `keysToEvict` returns `[]`.
  - Over cap → returns exactly `entries.count - target` keys, oldest
    `createdAt` first, and the returned set is disjoint from the newest
    `target` entries.
  - Ties in `createdAt` don't crash / produce a stable-enough ordering
    (don't over-specify tie-breaking, just assert count and "oldest N").

**App-target tests (`MockTranslationSession: TranslationSessionProtocol`,
injected in place of `LiveTranslationSession`):**
- `TranslationQueueTests`:
  - Two `translate` calls for the same pair issued back-to-back (no `await`
    between them, or within a few ms) result in exactly **one**
    `performBatch` call containing both requests. Inject a no-op/instant
    `sleeper` (see below) so the test doesn't need to wait a real 100ms.
  - Two `translate` calls for the same pair issued >100ms apart (simulate by
    manually advancing/triggering two separate flush cycles) result in
    **two** `performBatch` calls.
  - A batch larger than `maxBatchSize` (21 simultaneous requests) is split
    into two `performBatch` calls (20 + 1).
  - `performBatch` throwing an error fails every continuation in that batch
    with that error (not just the first).
  - A response missing a given request's `clientIdentifier` resolves that
    one continuation with `.sessionUnavailable`, without affecting siblings
    in the same batch.
  - `translate` for two *different* pairs does not coalesce into one batch
    even if issued simultaneously.

  To make the 100ms coalescing window testable without slow/flaky real
  sleeps, `TranslationService`'s flush-scheduling should take an injectable
  `sleeper: (Duration) async -> Void` (defaulting to `Task.sleep`), so tests
  can substitute a no-op or a manually-triggered version and assert on call
  counts rather than wall-clock timing.

- `TranslationErrorMappingTests`: `availability(from:to:)` maps `.installed`
  → `.ready`, `.supported` → `.needsDownload`, `.unsupported` →
  `.unsupported` (via a thin seam/fake around whatever `LanguageAvailability`
  wrapper you introduce — don't call the real framework API from a unit
  test).
- `sameLanguage` guard test: `translate` with `source.languageCode ==
  target.languageCode` (different region) throws `.sameLanguage` without
  ever touching the mock session or the cache.

---

## 10. Manual on-device verification script

CI can't exercise the real Translation framework (architecture §9). Run
this on a physical device (simulator translation-pack downloads are
unreliable) before considering M5 done:

1. **Cold tap, pack already installed** (Settings → General → Language &
   Region → Translation Languages, pre-install e.g. French): open an
   episode overlay in a French-language podcast, tap a word. Confirm the
   translation appears in under ~1s (success criteria, product overview),
   and confirm a second tap on the same word is effectively instant (cache
   hit).
2. **Pack not installed:** pick a language pair with no pack installed.
   Tapping a word should surface the "Download X ↔ Y to translate" banner,
   not a raw error. Tap "Download," confirm the system's download UI
   appears, let it finish, then tap the word again and confirm translation
   now succeeds without re-showing the banner.
3. **Download attempted offline:** enable Airplane Mode, tap "Download" for
   an uninstalled pair. Confirm the "connect to the internet" banner appears
   (not a generic failure) and no system download sheet is shown.
4. **Installed pack + airplane mode:** with a pack already installed from
   step 1, enable Airplane Mode, tap a *new* word (not previously cached) in
   that language pair. Confirm it still translates successfully (on-device
   packs work fully offline) — this is the airplane-mode demo product
   overview §2 calls out as first-class.
5. **Rapid multi-word tapping:** tap several different words in quick
   succession (within ~1s of each other). Confirm all resolve correctly and
   the app doesn't stutter/drop frames — this exercises the batching path
   under real timing, not just the unit-test mock.
6. **Overlay dismiss mid-lookup:** tap a word, then immediately dismiss the
   transcript overlay before the translation returns. Confirm no crash and
   no leaked spinner state if/when the overlay reopens (validates §3.4's
   "leave queued items, don't fail on cancellation" behavior combined with
   the root-mounted host view).
7. **Unsupported pair:** pick a source/target combination the Translation
   framework doesn't support at all (check current supported-languages list
   in Settings). Confirm the "isn't available" banner appears with no
   download button offered.

---

## 11. Acceptance criteria

- [ ] `TranslationServiceProtocol` and `TranslationAvailability` match
      architecture §5.3 verbatim; no signature changes.
- [ ] `TranslationDownloadPreparing` added to `Interfaces.swift` alongside
      it; `AppContainer` exposes both protocol views over one concrete
      `TranslationService` instance (§2.1).
- [ ] `TranslationHostView` is zero-size, hit-testing-disabled,
      accessibility-hidden, and mounted exactly once at the app root by M0
      (not inside the overlay).
- [ ] `TranslationService` is `@MainActor @Observable`, with the `Sendable`
      conformance and its justification documented inline (§3.2).
- [ ] Cache lookups happen before any session/queue involvement; cache
      writes happen only after a successful framework translation
      (write-through, never write-before-confirm).
- [ ] Cache key format is exactly `"\(sourceLang)|\(targetLang)|\(normalizedText)"`
      matching architecture §4's `TranslationCacheEntry.key` comment.
- [ ] Requests for the same language pair arriving within ~100ms are
      coalesced into one batch call; batches are capped at 20 items.
- [ ] Same-language requests throw `TranslationError.sameLanguage` before
      touching cache or queue.
- [ ] `availability(from:to:)` correctly maps all three
      `LanguageAvailability.Status` cases (plus `@unknown default` →
      `.unsupported`).
- [ ] `prepareDownload(from:to:)` fails fast with `.downloadRequiresNetwork`
      when offline, without invoking the Translation framework.
- [ ] Cache prunes from 5000 down to 4500 entries, oldest-`createdAt`-first,
      when the cap is exceeded — verified by a pure unit test independent of
      SwiftData.
- [ ] All Translation-framework calls are isolated behind
      `TranslationSessionProtocol` / `LiveTranslationSession`; no other file
      references `TranslationSession` directly.
- [ ] Every uncertain iOS 26 API shape (`LanguageAvailability.status`,
      `session.translations(from:)`, `session.prepareTranslation()`,
      `TranslationSession.Request`/`.Response` shape, whether a session
      exposes its resolved source/target languages) is marked
      `// VERIFY(iOS26):` at its single call site per architecture §10, not
      guessed silently.
- [ ] Unit tests in §9 pass; no test depends on real wall-clock sleeps ≥
      the coalescing window.
- [ ] Manual verification script (§10) completed on a physical device with
      Apple Intelligence support; all 7 steps pass.
- [ ] No `print`, no force unwraps outside tests, `// M5` header on every
      new file, one type per file, `os.Logger` category `"Translation"`
      under subsystem `com.lingopod.app`.
