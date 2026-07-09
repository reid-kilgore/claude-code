# M4 — Transcript Overlay UI

Spec for the lyrics-style transcript overlay: the hero surface of LingoPod.
This document is binding alongside `docs/00-product-overview.md` and
`docs/01-architecture.md`. Where this spec is silent, those two win. Where
this spec must assume something the architecture doc leaves unstated, the
assumption is marked **ASSUMPTION** — implement to the assumption, don't
block on it, and don't invent something else.

## 0. Purpose & non-goals

Purpose: a full-screen view, presented from the Now Playing screen, that
shows the episode transcript scrolling in sync with playback (Apple Music
lyrics aesthetic) and supports three interactions: tap-to-seek, tap/select
word-or-phrase-to-translate, and highlight-to-explain.

Non-goals for v1 (do not build):
- Per-word karaoke highlighting (architecture §6.4 — segment-granularity
  only, even when `WordTiming` data exists). M4 does not read
  `WordTiming` for rendering purposes.
- Vocabulary/SRS decks, saved-words list, progress tracking (product
  overview "explicitly out of scope").
- iPad-specific layout. Design for iPhone; avoid hard-coded assumptions
  that would make a future iPad layout impossible (e.g. don't hand-code
  screen-width constants where `GeometryReader`/dynamic layout would do).
- A custom seek scrubber with drag-to-scrub. A static progress track +
  discrete skip buttons is sufficient (see §2.4).

## 1. File manifest

All new files under `LingoPod/UI/TranscriptOverlay/` unless noted. Every
file starts with `// M4` per architecture §10.

```
LingoPod/UI/TranscriptOverlay/
  TranscriptOverlayView.swift        // root screen, composes everything below
  TranscriptOverlayViewModel.swift   // @Observable, MainActor: state machine, selection, service calls
  TranscriptSyncDriver.swift         // MainActor: currentTime -> currentIndex bridge (binary search)
  TranscriptRowView.swift            // one transcript line, Equatable
  WordTokenFlowLayout.swift          // custom Layout wrapping word tokens + WordTokenView
  WordTranslationPopover.swift       // popover content for word/phrase translation
  SelectionActionBar.swift           // floating "Translate | Explain" bar shown after phrase selection
  ExplainSheetView.swift             // bottom sheet: streaming PassageExplanation card
  TranscriptLifecycleBanner.swift    // pending / downloading / partial-frontier / failed states
  PlaybackBarView.swift              // compact bottom playback controls
  BlurredArtworkBackground.swift     // blurred artwork + contrast gradient background layer
  ResumeSyncPill.swift               // small pill shown during userScrolling
  Previews/PreviewMocks.swift        // FakePlayerEngine, canned transcript + services (#if DEBUG)
```

LingoPodKit additions (new files in the existing `Transcripts/` folder —
this folder is M3-owned but pure logic utilities from any module belong in
`LingoPodKit`; coordinate file-level conflicts if M3 lands first):

```
LingoPodKit/Sources/LingoPodKit/Transcripts/
  SegmentSync.swift       // binary search: currentTime -> current segment index
  WordTokenizer.swift     // NLTokenizer-based word/phrase tokenization for tap targets
LingoPodKit/Tests/LingoPodKitTests/
  SegmentSyncTests.swift
  WordTokenizerTests.swift
```

## 2. Dependencies & interfaces consumed

M4 depends on M2 (`PlayerEngineProtocol`), M3 (`TranscriptProviderProtocol`,
`TranscriptHandle`), M5 (`TranslationServiceProtocol`), M6
(`ExplainServiceProtocol`) — all via `AppContainer` in the environment, per
architecture §5. M4 does not talk to SwiftData directly; it only ever holds
`PersistentIdentifier`s and the `Sendable` snapshot/handle types those
protocols already return.

**ASSUMPTION — `TranscriptSegmentSnapshot` shape.** Architecture §5.2 only
describes this type in prose ("mirror of `TranscriptSegment` — id, index,
times, text, wordTimings"). M4 codes against this concrete shape; if M3
ships something different, M3 must reconcile:

```swift
struct TranscriptSegmentSnapshot: Identifiable, Sendable, Hashable {
  let id: PersistentIdentifier
  let index: Int
  let startTime: TimeInterval
  let endTime: TimeInterval
  let text: String
  let wordTimings: [WordTiming]   // present but unused by M4, see §0
}
```

**ASSUMPTION — source language.** M4 needs a `Locale.Language` for the
transcript's spoken language to call `TranslationServiceProtocol.translate`
and `ExplainServiceProtocol.explain`. `TranscriptHandle` as specified in
architecture §5.2 exposes only `state`, `segments`, `progress` — no
language. M4 assumes `TranscriptHandle` also exposes:

```swift
let languageCode: String   // BCP-47, mirrors Transcript.languageCode
```

and converts via `Locale.Language(identifier: languageCode)`. If M3 does
not add this field, M4 cannot function — flag immediately rather than
guessing at a workaround (e.g. do **not** infer language from `Podcast`,
since M4 has no direct handle to the `Podcast` model).

**ASSUMPTION — target (native) language.** No module exposes a "user's
native language" setting. Product overview: "Their device/UI language is
their native language." M4 uses:

```swift
Locale.current.language   // target for translate() and explain()
```

everywhere a target language is needed. If a future settings screen adds an
explicit override, it should be threaded through `AppContainer`, not
re-derived per call site — but that's out of scope for M4 itself.

**ASSUMPTION — `TranscriptHandle` construction for previews.**
`TranscriptHandle` is a concrete `@MainActor @Observable final class` (not
a protocol), so it can't be protocol-mocked. Since it lives in the app
target (architecture §5, "these protocols live in the app target... except
where noted") and Xcode Previews compile in the same target, M4's preview
code can use an `internal` convenience initializer:

```swift
init(state: TranscriptState, segments: [TranscriptSegmentSnapshot], progress: Double)
```

If M3's implementation of `TranscriptHandle` doesn't already have an
initializer usable this way, add one in `TranscriptHandle.swift` (M3's
file) as a small, clearly-commented `// M4: preview support` addition —
don't fork the type.

## 3. Screen layout — `TranscriptOverlayView`

Presented via `.fullScreenCover` from `PlayerView` (M2 UI). **M4 owns the
destination view, not the trigger** — M2's spec is responsible for the
`.fullScreenCover(isPresented:)` call site and passing in the current
`Episode`'s `PersistentIdentifier`. `TranscriptOverlayView` takes an
`episodeID: PersistentIdentifier` and resolves everything else (engine,
transcript handle, services) from the environment `AppContainer`.

Root ZStack, back to front:

1. **`BlurredArtworkBackground`** — the episode/podcast artwork
   (`Podcast.artworkURL`, loaded via `AsyncImage`), `.scaledToFill()`,
   `.blur(radius: 50)`, clipped to screen bounds. On top of it, a
   `LinearGradient` from `.black.opacity(0.35)` (top) to `.black.opacity(0.75)`
   (bottom) to guarantee text contrast regardless of artwork colors. If
   artwork fails to load, fall back to a flat `Color(.systemGray6)`
   dark-mode-appropriate background with the same gradient.
2. **Content VStack**, top to bottom:
   - **Top bar**: leading circular translucent button (`Circle().fill(.ultraThinMaterial)` background, SF Symbol `chevron.down`, 34×34pt) that calls the `\.dismiss` environment action. No other chrome in the top bar (no title — the transcript is the title).
   - **Transcript area** (see §3.1) — takes all remaining vertical space, `.frame(maxHeight: .infinity)`.
   - **`PlaybackBarView`** pinned at the bottom (see §2.4), safe-area padded.

Colors: all overlay text is white/near-white (`.white`, `.white.opacity(0.35)` for dimmed) since the background is always dark via the gradient — don't use semantic `.primary`/`.secondary` here, they'd flip in light mode against a still-dark background.

### 3.1 Transcript area

`ScrollView` wrapping a `LazyVStack(alignment: .leading, spacing: 28)` of
`TranscriptRowView`s, horizontal padding 24pt, top/bottom padding equal to
roughly 40% of the scroll viewport height (so the first and last lines can
be scrolled to vertical center — same trick Apple Music uses). Wrap the
`ScrollView` in a `ScrollViewReader` to drive programmatic scrolling.

Each row (current segment vs. not) — see §8 for the render/perf contract,
§9 for word-token rendering:

- Text: `Font.system(size: 28, weight: .bold, design: .rounded)`, scaled
  via `@ScaledMetric` (see §12).
- Line spacing: `.lineSpacing(6)`.
- Opacity: current segment `1.0`; all others `0.35`.
- Optional blur on non-current rows: `.blur(radius: 1.2)` — apply **only**
  when `!reduceMotion && !reduceTransparency`; skip entirely otherwise (§12).
- Alignment: leading (`multilineTextAlignment(.leading)`), full width.
- Animate opacity/blur changes with `.animation(.easeInOut(duration: 0.25), value: isCurrent)` on the row (a plain per-row animation, independent of the scroll-position spring in §4.3).

Above the last real row, when `TranscriptHandle.state == .partial`, append
one extra "frontier" row (§7) — not a real segment, not tappable, not
selectable.

### 3.2 `ResumeSyncPill`

A small capsule (`"Resume sync"`, chevron.down.circle icon, `.ultraThinMaterial`
background) that fades in bottom-center of the transcript area (not
overlapping `PlaybackBarView`) whenever overlay mode is `userScrolling`.
Tapping it transitions immediately back to `syncing` (§10) and scrolls to
center the current segment with the standard spring (§4.3).

### 3.3 `PlaybackBarView`

Compact, fixed-height (~96pt) bar:

- Row 1: thin progress track (`Capsule`, non-interactive — no drag-to-seek
  in v1, see §0 non-goals) showing `currentTime / duration`, with elapsed
  time label leading (`0:42`) and remaining time label trailing (`-12:18`),
  both `.monospacedDigit()`.
- Row 2, horizontally centered `HStack(spacing: 32)`:
  - Skip back 15s: SF Symbol `gobackward.15`, calls `Task { await engine.skip(by: -15) }`.
  - Play/pause: SF Symbol `play.fill` / `pause.fill` depending on `engine.state == .playing`, larger (44pt tap target), calls `engine.togglePlayPause()`.
  - Skip forward 30s: SF Symbol `goforward.30`, calls `Task { await engine.skip(by: 30) }`.
  - Rate control: text button showing `"\(engine.rate, specifier: "%.2g")×"`, opens a `Menu` with fixed steps `[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]`; selecting one sets `engine.rate = value`.

Time formatting utility (`m:ss` / `-m:ss`) can live as a small private
helper in `PlaybackBarView.swift` — no need to add it to LingoPodKit, it's
trivial and view-local.

## 4. Sync engine

### 4.1 `SegmentSync` (LingoPodKit)

```swift
// LingoPodKit/Sources/LingoPodKit/Transcripts/SegmentSync.swift
public enum SegmentSync {
  /// Binary search over ascending segment start times to find the segment
  /// that should be highlighted as "current" at a given playhead time.
  ///
  /// Semantics:
  /// - `startTimes` must be sorted ascending (segments are always ordered
  ///   by startTime in the data model — caller's responsibility).
  /// - Returns the index of the **last** segment whose `startTime <= time`.
  /// - Before the first segment (`time < startTimes[0]`), or if
  ///   `startTimes` is empty: returns `nil` (no current segment yet).
  /// - In a gap between segment i's endTime and segment i+1's startTime
  ///   (feed transcripts can have gaps): still returns `i` — the previous
  ///   segment stays highlighted until the next one actually starts. This
  ///   falls out naturally from "last startTime <= time"; do not special-case
  ///   `endTime` at all, `endTime` is not consulted by this function.
  /// - At or after the last segment's startTime (including past its
  ///   endTime, i.e. past the end of the transcript): returns
  ///   `startTimes.count - 1`. The last line stays highlighted; it never
  ///   reverts to `nil`.
  public static func currentIndex(in startTimes: [TimeInterval], at time: TimeInterval) -> Int?
}
```

Implementation approach (for the agent writing the body): standard
"rightmost insertion point minus one" binary search, O(log n). `time` is
monotonically non-decreasing during normal playback but **can jump
backward** on seek — the function must not assume monotonicity; it's a
pure stateless query every call.

Unit tests (`SegmentSyncTests.swift`) must cover: empty array → nil; time
before first start → nil; time exactly equal to a startTime → that index;
time in a gap → previous index; time past the last segment → last index;
single-segment array at various times.

### 4.2 `TranscriptSyncDriver`

```swift
// LingoPod/UI/TranscriptOverlay/TranscriptSyncDriver.swift
@MainActor @Observable
final class TranscriptSyncDriver {
  private(set) var currentIndex: Int? = nil   // only property other code should read

  func update(time: TimeInterval, startTimes: [TimeInterval]) {
    let newIndex = SegmentSync.currentIndex(in: startTimes, at: time)
    if newIndex != currentIndex { currentIndex = newIndex }
  }
}
```

Purpose: isolate the 4 Hz churn. `currentTime` changes every tick;
`currentIndex` (an `@Observable` property) changes only when the computed
index actually differs, so anything reading `currentIndex` re-renders far
less often than 4 Hz. See §8 for how row views consume this without
themselves observing `currentTime`.

Driving it: in `TranscriptOverlayViewModel`, use
`.onChange(of: engine.currentTime)` on a lightweight bridging modifier
attached near the root of `TranscriptOverlayView` (or an `.task` loop that
awaits changes via `withObservationTracking` if `.onChange(of:)` on a
computed/Observable property proves awkward — either is acceptable, but
prefer `.onChange(of:)` for simplicity). `// VERIFY(iOS26):` confirm
`.onChange(of:)` fires correctly for an `@Observable` `currentTime` at 4 Hz
without extra plumbing; if not, fall back to a `Task` loop polling
`engine.currentTime` every 250ms via `Task.sleep`.

Each call to `update` also feeds `startTimes`, which is
`transcriptHandle.segments.map(\.startTime)` — recompute this array only
when `segments.count` changes (cache it in the view model), not on every
tick.

### 4.3 Auto-scroll

Driven by `currentIndex` changes (not by `currentTime`). On change, when
overlay mode is `syncing` (§10):

```swift
withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.8)) {
  scrollProxy.scrollTo(segment.id, anchor: .center)
}
```

When `reduceMotion` is true, still perform the scroll (content must stay
in sync) but without the spring curve — a plain short ease, or even no
animation at all (instant `scrollTo` with `.animation(nil)`) is acceptable;
prefer the short ease so the jump isn't jarring, but do not use `.spring`.

### 4.4 Manual-scroll detection & pause/resume

`// VERIFY(iOS26):` this section assumes `View.onScrollPhaseChange { old, new in }`
and `View.onScrollGeometryChange(for:of:action:)` (introduced iOS 18,
carried into iOS 26) are available on `ScrollView`. If the exact modifier
signatures differ from what's below, keep the call site isolated in
`TranscriptOverlayView`'s scroll-area body and adapt — do not restructure
the state machine.

- Attach `.onScrollPhaseChange { oldPhase, newPhase in ... }` to the
  transcript `ScrollView`.
- When `newPhase == .interacting` (user's finger is on the scroll view):
  transition mode → `userScrolling` (from `syncing` only; ignore if
  already `userScrolling`, `selecting`, `popoverOpen`, or `sheetOpen` —
  see §10 for why those don't get interrupted by scroll phase changes).
- When `newPhase` becomes `.idle` after having been `.interacting` or
  `.decelerating`: start a 4-second `Task.sleep` timer. If the phase
  becomes `.interacting` again before the timer fires, cancel the timer
  (restart on next idle). If the timer completes without cancellation and
  mode is still `userScrolling`: transition back to `syncing` and perform
  the spring auto-scroll from §4.3 to re-center the current segment.
- Tapping `ResumeSyncPill` (§3.2) does the same transition immediately,
  cancelling any pending idle timer.
- **Never** auto-scroll (§4.3) while mode is `selecting`, `popoverOpen`, or
  `sheetOpen` — even if `currentIndex` changes underneath (audio keeps
  playing during Explain, per §0/§7 of architecture; the transcript should
  not visibly jump while the user is mid-selection or reading a popover/
  sheet). When one of those states ends, if `currentIndex` moved while it
  was open, snap-scroll (no spring, instant) to the now-current segment
  before resuming `syncing`, so the view doesn't do a jarring multi-second
  spring catch-up.

## 5. Interaction 1 — tap segment → seek

A tap anywhere in a row's background (not on a word token — word taps are
captured by the token's own `onTapGesture` and win, see §6) does:

1. Haptic: `UIImpactFeedbackGenerator(style: .light).impactOccurred()`.
2. Immediately set `syncDriver` display state so the tapped row highlights
   as current **without waiting for the time observer**: call
   `syncDriver.forceIndex(segment.index)` (add this small setter — it just
   assigns `currentIndex` directly, bypassing the `update(time:)` path) so
   the UI feels instant.
3. `Task { await engine.seek(to: segment.startTime) }`. Do not await this
   before updating the highlight — the highlight jump must be immediate
   per architecture's "honest timestamps" principle and this task's
   requirement to not wait on the seek.
4. Once the real `engine.currentTime` catches up post-seek, `syncDriver`'s
   normal `update(time:)` path takes back over on the next tick and will
   agree with the forced index (no visible conflict, since seek lands on
   `segment.startTime` and `SegmentSync.currentIndex` at that time returns
   that same index).
5. If mode was `userScrolling`, tapping a segment also resets it to
   `syncing` (the user's intent to jump implies they want to follow again)
   and performs the centering scroll.

## 6. Word tokenization

### 6.1 `WordTokenizer` (LingoPodKit)

```swift
// LingoPodKit/Sources/LingoPodKit/Transcripts/WordTokenizer.swift
import NaturalLanguage

public struct WordToken: Equatable, Sendable {
  public let text: String                  // display text, trailing punctuation merged in (see below)
  public let range: Range<String.Index>    // range into the *original* segment text
}

public enum WordTokenizer {
  /// Splits `text` into tappable word-ish tokens using NLTokenizer's word
  /// unit, which correctly handles CJK/Thai/other no-space scripts when
  /// given the right `language` hint (falls back to automatic detection
  /// when `language` is nil).
  public static func tokenize(_ text: String, language: Locale.Language?) -> [WordToken]
}
```

Implementation approach: use `NLTokenizer(unit: .word)`, set
`tokenizer.setLanguage(...)` from `language` when provided (convert
`Locale.Language` → `NLLanguage` via its `languageCode` identifier;
`NLTokenizer` also has reasonable automatic detection if you skip this),
`tokenizer.string = text`, then `tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in ... }`.

`NLTokenizer` yields whitespace and punctuation as their own tokens by
default. Post-process: merge any token that consists entirely of
punctuation/symbol characters (`CharacterSet.punctuationCharacters.union(.symbols)`)
into the **preceding** word token (extend its `range`'s upper bound,
append its text) — this keeps `"hablar,"` as one tappable/selectable unit
instead of `"hablar"` + `","`. Drop whitespace-only tokens entirely (don't
emit a `WordToken` for them — the flow layout supplies its own spacing,
see §6.2). If a punctuation run appears with no preceding word token yet
(e.g. text starts with `"—"`), keep it as its own token rather than
dropping it.

This function is called once per segment when a segment first appears (not
per-frame) — cache the result on/alongside the row (e.g. compute in
`TranscriptOverlayViewModel` when segments are appended, store
`[TranscriptSegmentSnapshot.id: [WordToken]]`, or compute lazily on first
render and memoize in `TranscriptRowView`'s own state). Never call it from
inside the 4 Hz sync path.

Unit tests (`WordTokenizerTests.swift`): a Spanish sentence with normal
spacing and trailing punctuation; a Japanese sentence with no spaces
(verify more than one token is produced, i.e. it doesn't degrade to one
giant blob); an English contraction ("don't") stays one token; an ellipsis
mid-sentence doesn't eat the following word.

### 6.2 Rendering — custom `Layout`, not `.textSelection`

**Decision and why**: SwiftUI's built-in `Text` + `.textSelection(.enabled)`
gives free text flow and native copy/paste selection, but it hands you no
hook to (a) intercept a tap on a specific word, (b) render a custom
highlight rectangle behind an in-progress phrase selection, or (c) control
what "select" means (a system text-selection handle drag is a different
gesture and UX than "press-and-drag across tokens" this spec calls for).
Because Interactions 2 and 3 both require word-granular hit-testing and a
fully custom selection-visual, **do not use `.textSelection`, and do not
lay words out as one `Text` at all.** Instead:

- `WordTokenFlowLayout`: a custom `Layout` (the `Layout` protocol, iOS 16+)
  that arranges its subviews (one per `WordToken`) left-to-right,
  wrapping to a new line when a token would overflow the available width,
  matching the row's `lineSpacing`/font metrics as closely as practical.
  Inter-token spacing: a fixed-width space sized to the current font (or
  simply lay out `word + " "` as the measured unit and trim trailing space
  visually — either approach is fine as long as wrapping looks natural).
- Each token is a small `WordTokenView`: a `Text(token.text)` with the
  same font/weight as the row (inherits current/dimmed opacity from the
  parent — tokens do not independently dim), plus:
  - `.onTapGesture { onTap(token) }` — plain tap → translation popover (§7).
  - A combined long-press-then-drag gesture for phrase selection (§7.2).
  - A highlight background (`Capsule` or rounded rect behind the text,
    translucent white/blue) rendered when the token falls within the
    current selection range or is the just-tapped word awaiting its
    popover.
- Token frames must be discoverable in a shared coordinate space so the
  drag gesture (which is anchored to whichever token the long-press
  started on) can hit-test *other* tokens, including ones in an adjacent
  row, as the finger moves. Use an `.anchorPreference` (or
  `.overlay(GeometryReader { ... })` reporting into a `PreferenceKey`) on
  each `WordTokenView` publishing `[WordTokenID: Anchor<CGRect>]` (or
  resolved `CGRect` in the `.named("transcriptScroll")` coordinate space).
  `TranscriptOverlayView` applies `.coordinateSpace(name: "transcriptScroll")`
  to the `ScrollView`. Collect/merge the preference at the transcript-area
  level so the selection-drag handler (owned by the view model) can ask
  "which token is at point P" in O(tokens-currently-on-screen), which is
  small (a handful of visible rows).
- **Caveat, document it in code comments where the drag handler lives**:
  because rows are in a `LazyVStack`, only tokens whose row is currently
  laid out publish an anchor. Practically, the overlay shows enough
  padding that the current line plus a few neighbors above/below are
  always laid out, so cross-segment selection works for the visually
  adjacent lines a user can plausibly drag across. If the drag reaches
  past the last known anchor (into not-yet-laid-out territory), clamp the
  extent to the furthest known token rather than crashing or silently
  doing nothing — do not attempt to force-render off-screen rows to make
  unbounded cross-segment selection work; that's out of scope.

`WordTokenID`: `struct WordTokenID: Hashable { let segmentIndex: Int; let tokenIndex: Int }` — `segmentIndex` is `TranscriptSegmentSnapshot.index` (stable ordering key from the data model), `tokenIndex` is the position in that segment's `[WordToken]` array. Document order for two IDs is lexicographic `(segmentIndex, tokenIndex)` comparison — this is how anchor/extent get normalized into start/end (§10.2).

## 7. Interaction 2 — word tap & phrase selection → translation

### 7.1 Single word tap

Plain tap (no drag) on a `WordTokenView`:

1. Transition mode → `popoverOpen` with selection `anchor == extent == that token` (§10.2).
2. Present `WordTranslationPopover` anchored to that token's frame:
   `.popover(isPresented:attachmentAnchor: .rect(.rect(tokenFrame)))`, and
   force the compact (iPhone) presentation to render as an actual anchored
   bubble rather than expanding to a sheet:
   `.presentationCompactAdaptation(.popover)`.
3. Popover content, top to bottom:
   - Original word/text (bold, source language).
   - Translated text — while awaiting the async call, a small inline
     `ProgressView()`; once resolved, replace with the translated string.
     Call: `try await translationService.translate(token.text, from: sourceLanguage, to: targetLanguage)` (languages from §2 assumptions). This is
     cache-first per M5's contract — no need for M4 to add its own cache,
     but do debounce/guard against firing a second call if the same token
     is tapped again while one is in flight (track in-flight token id in
     the view model, ignore duplicate taps for the same token).
   - **Optional, cut first under time pressure**: a small speaker-icon
     button that uses `AVSpeechSynthesizer` (first-party, no protocol
     needed) to speak the original word aloud with an `AVSpeechSynthesisVoice`
     matched to the source language. This is self-contained inside M4 —
     it is not one of the §5 cross-module protocols, and it is not part of
     the acceptance criteria (§14). Build it only if the rest of M4 is
     solid.
   - "Explain more" link/button: promotes to the Explain sheet (§8) using
     `passage = token.text`, `context` = the containing segment's full
     `text` plus, if available, the previous and next segment's text
     (space-joined) — see §8's context rule.
4. Dismissing the popover (tap outside, or swipe down) → mode returns to
   `syncing` if it was `syncing` before the tap, else `userScrolling` (i.e.
   restore whatever the pre-popover mode was; track it in the view model
   as `modeBeforeInterruption` whenever entering `popoverOpen`/`selecting`/
   `sheetOpen`).

### 7.2 Phrase selection (press-and-drag)

Gesture on each `WordTokenView`, composed as: `LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("transcriptScroll")))`.

- On the long-press succeeding (before drag starts): haptic
  (`UIImpactFeedbackGenerator(style: .medium)`), set
  `selection.anchor = selection.extent = thisToken`, transition mode →
  `selecting`.
- On each drag update: hit-test the drag's current location against the
  collected token-anchor map (§6.2) to find the nearest token whose frame
  contains (or is closest to) the point; set `selection.extent` to that
  token's ID. Recompute the highlighted range (anchor…extent normalized to
  document order, §6.2) and re-render the Capsule backgrounds on affected
  tokens.
- **280-character cap**: before committing a new `extent`, compute the
  candidate selected text length (§10.2's derivation). If it would exceed
  280 UTF-16 code units, do not extend further in that direction — clamp
  `extent` to the last token that keeps the total ≤ 280, and fire a light
  haptic (`UINotificationFeedbackGenerator().notificationOccurred(.warning)`)
  once per drag gesture the first time the cap is hit (don't spam it every
  subsequent update while still pinned at the cap).
- On drag end (release): mode stays `selecting` (this is the "committed"
  sub-state — see §10), and `SelectionActionBar` appears: a small floating
  `HStack` with two buttons, "Translate" and "Explain", positioned above
  the selected text (or centered over the transcript area if the
  selection spans off-screen edges — simplest: just center it
  horizontally at a fixed vertical offset above the bottom playback bar,
  don't attempt precise anchoring to the selection's bounding box, that's
  not worth the complexity for v1).
- Tapping anywhere else in the transcript area (not on a token, not on the
  action bar) while `selecting` clears the selection and returns to the
  prior mode.
- Tapping **Translate**: transition → `popoverOpen`, call
  `translationService.translate(selectedText, from:to:)` and show it in
  the same `WordTranslationPopover` component (it already handles
  arbitrary-length source text, not just single words — no separate view
  needed), anchored to the action bar's position rather than a token
  frame.
- Tapping **Explain**: transition → `sheetOpen` (§8), passing
  `passage = selectedText`, `context` per §8's rule using the segment
  range the selection spans.

## 8. Interaction 3 — highlight → Explain sheet

`ExplainSheetView`, presented via
`.sheet(isPresented:) { ExplainSheetView(...) }` with
`.presentationDetents([.medium, .large])` and
`.presentationDragIndicator(.visible)`.

**Audio must keep playing.** Do not call `engine.pause()` when the sheet
opens. Provide a pause/play toggle button inside the sheet's header
(mirrors `engine.state`) so the user can pause explicitly if they want to;
closing the sheet never changes playback state either.

**Context rule**: `context` passed to
`explainService.explain(passage:context:sourceLanguage:targetLanguage:)`
is the `text` of the segment(s) the passage came from, plus one segment of
padding on each side when available: if the passage spans segments
`[i...j]`, context = `segments[max(0, i-1)...min(segments.count-1, j+1)].map(\.text).joined(separator: " ")`. No hard length cap is specified by the architecture doc for `context`; as a sane bound, truncate to roughly 600 characters (trim from the padding segments first, never trim the passage's own segment(s)) if it would be longer — this is a judgment call M4 is allowed to make since M6 owns actual prompt construction and just receives this string.

**Streaming render**: consume
`AsyncThrowingStream<PassageExplanation.PartiallyGenerated, Error>` in a
`.task` scoped to the sheet's lifetime (cancel on dismiss). `PartiallyGenerated` fields are optional as they stream in. Card layout, top to bottom:

1. "Translation" section — `translation` field.
2. "Meaning" section — `meaning` field.
3. "Grammar notes" — bulleted list from `grammarNotes` (only rendered if non-empty once populated).
4. "Idioms & register" — bulleted list from `idiomNotes` (same).
5. Footer, always present once any content is showing: `"Generated by on-device AI"` in small secondary text.

While a section's field is still `nil`, render a skeleton placeholder in
its place: 2–3 rounded rectangles (`RoundedRectangle(cornerRadius: 6)`,
`.fill(.white.opacity(0.15))`) with a shimmer animation (a diagonal
gradient sweeping via `.mask` + an infinitely-repeating `.animation`, or
the simpler `redacted(reason: .placeholder)` modifier applied to
placeholder text — either is acceptable; `redacted` is far less code and
sufficient). When a field transitions from nil → populated, cross-fade
(`.transition(.opacity)`, wrapped in `withAnimation(.easeInOut(duration: 0.2))`).

**Error / unavailable states** (architecture §8 pattern — inline banner,
one action button, no alerts):

- `explainService.availability == .unavailable(let reason)`: show a banner
  in place of the whole card, `Text(reason)` (or a friendly fixed string
  if `reason` isn't meant for display — check M6's spec once it exists;
  until then assume `reason` is human-readable), no action button (nothing
  the user can do from here — Apple Intelligence is a device/region/
  Settings-level requirement).
- `.modelNotReady`: banner "On-device model is preparing…" with a
  `ProgressView()`. **Gap**: `ExplainServiceProtocol` doesn't define a way
  to be notified when readiness changes. M4's approach: poll
  `explainService.availability` every 2 seconds via a `Task.sleep` loop
  while the sheet is open and state is `.modelNotReady`; re-attempt
  `explain()` automatically the first time it flips to `.ready`. Stop
  polling when the sheet closes.
- Stream throws mid-generation: replace the card (or whatever's been
  populated so far — keep partial content visible above the error, don't
  discard it) with an inline error row + "Retry" button that re-invokes
  `explain()` with the same passage/context from scratch.

Dismissing the sheet (swipe down or drag indicator) → mode returns to
`modeBeforeInterruption` (§7.1's rule), same as popover dismissal. If
`currentIndex` moved while the sheet was open, snap-scroll per §4.4.

## 9. Transcript lifecycle states in the overlay

Driven by `transcriptHandle.state: TranscriptState` (`pending`, `partial`,
`complete`, `failed(reason: String)`) and `transcriptHandle.progress: Double`.
The top bar and `PlaybackBarView` are always visible regardless of state —
only the transcript area's content switches:

- **`.pending`**: centered `ProgressView()` + `"Preparing transcript…"`,
  vertically centered in the transcript area. No rows.
- **`.partial`**: render `transcriptHandle.segments` as normal rows (sync/
  tap/select all work against whatever's available — §4.1's "past the
  last segment" edge case naturally covers the playhead running ahead of
  transcription), plus one non-interactive **frontier row** appended after
  the last real segment: three dots with a subtle staggered pulse
  animation (opacity 0.3↔1.0, offset by 150ms each), plus underneath it a
  slim `ProgressView(value: transcriptHandle.progress)` and
  `"\(Int(progress * 100))% transcribed"`. Remove the frontier row the
  instant `state` becomes `.complete` (or `.failed`).
- **`.complete`**: normal rows, no frontier row, no banner.
- **`.failed(let reason)`**: replace the transcript area (not the whole
  screen — top bar and playback bar stay) with a centered banner: an
  icon (`exclamationmark.triangle`), the reason text, and one action
  button. **Gap** (see report to spec author, not blocking): `reason` is
  a raw `String`, not a typed enum, so button choice is heuristic. Use
  this fallback logic, most-specific first:
  - If `reason` contains `"download"` or `"asset"` (case-insensitive):
    button **"Download language"** → calls
    `transcriptProvider.invalidateAndRetranscribe(episodeID:)` (this is
    the only retry entry point M4 has; assume M3's implementation
    internally prompts/performs any needed `AssetInventory` download
    before retrying transcription — M4 has no direct `AssetInventory`
    access and none is exposed via §5).
  - Else if `reason` contains `"episode"` or `"audio"`: button
    **"Download episode"** → M4 does **not** have `CatalogServiceProtocol`
    in its declared dependencies (architecture §3 module map lists only
    M2/M3/M5/M6 for M4). If `AppContainer` happens to expose it anyway
    (likely, since it's one shared container), call
    `catalogService.download(episodeID:)`; if it's not reachable from
    M4's environment, fall back to the generic **"Retry"** button below
    and note the limitation in a code comment — do not add a new
    cross-module dependency without updating architecture §3 first.
  - Otherwise: generic **"Retry"** button →
    `transcriptProvider.invalidateAndRetranscribe(episodeID:)`.
  - All three buttons, while their retry is in flight, show a spinner in
    place of the button label and are disabled to prevent double-fire.

Regardless of state, tap-to-seek and playback controls keep working —
transcript problems never block audio (product overview principle #3).

## 10. State machine

### 10.1 Modes

| Mode | Meaning |
|---|---|
| `syncing` | Default. Auto-scroll follows `currentIndex`. |
| `userScrolling` | User is dragging/has recently dragged the transcript; auto-scroll suspended. |
| `selecting` | Press-and-drag phrase selection in progress or just committed (action bar showing). |
| `popoverOpen` | Word/phrase translation popover visible. |
| `sheetOpen` | Explain sheet visible. |

### 10.2 Selection state model

```swift
struct TranscriptSelection: Equatable {
  var anchor: WordTokenID
  var extent: WordTokenID
}
```

Derived (computed, not stored):
- `orderedRange`: `(min(anchor, extent, by: lexicographic (segmentIndex, tokenIndex)), max(...))`.
- `text`: concatenate token texts from `orderedRange.lower` to `orderedRange.upper` inclusive, in document order, joining tokens within a segment with a single space and joining across a segment boundary also with a single space (do not insert the segment's raw newlines/punctuation beyond what's already in each token).
- `segmentRange`: `orderedRange.lower.segmentIndex...orderedRange.upper.segmentIndex` — this is what §8's context rule uses.

A single word tap (§7.1) is represented the same way with `anchor == extent`.

### 10.3 Transitions

| From | Event | To | Notes |
|---|---|---|---|
| `syncing` | scroll phase → `.interacting` | `userScrolling` | §4.4 |
| `userScrolling` | 4s idle with no re-interaction | `syncing` | resumes spring auto-scroll |
| `userScrolling` | tap `ResumeSyncPill` | `syncing` | immediate, cancels idle timer |
| `userScrolling` | tap a segment (§5) | `syncing` | seek + immediate resync |
| `syncing` / `userScrolling` | tap a word (no drag) | `popoverOpen` | store prior mode as `modeBeforeInterruption` |
| `syncing` / `userScrolling` | long-press on a word succeeds | `selecting` | anchor = extent = that token |
| `selecting` | drag update | `selecting` | extent changes, self-transition |
| `selecting` | tap elsewhere (not token, not action bar) | `modeBeforeInterruption` | selection cleared |
| `selecting` | tap "Translate" | `popoverOpen` | |
| `selecting` | tap "Explain" | `sheetOpen` | |
| `popoverOpen` | dismiss popover | `modeBeforeInterruption` | |
| `popoverOpen` | tap "Explain more" | `sheetOpen` | promotes, same passage |
| `sheetOpen` | dismiss sheet | `modeBeforeInterruption` | snap-scroll if `currentIndex` drifted, §4.4 |

Any mode not listed as a valid `From` for a given event ignores that
event (e.g. scroll-phase changes while `popoverOpen` do not transition
anything — the popover captures the gesture surface enough in practice
that this is mostly moot, but the state machine should treat it as a
no-op defensively rather than asserting).

`modeBeforeInterruption` is only ever `syncing` or `userScrolling` (it's
set when leaving one of those two into `popoverOpen`/`selecting`/
`sheetOpen`, and consumed on the way back out). If somehow unset, default
to `syncing`.

## 11. Performance

- Transcript area is a `LazyVStack` inside a `ScrollView` — never a
  non-lazy `VStack` or `List` (List's row recycling fights the custom
  spacing/anchor-preference approach in §6.2).
- `TranscriptRowView` conforms to `Equatable`, comparing only
  `segment.id` and `isCurrent` (ignore the row's closures in `==` — they're
  stable references, not meaningfully comparable, and irrelevant to
  whether the row needs to re-render):

  ```swift
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.segment.id == rhs.segment.id && lhs.isCurrent == rhs.isCurrent
  }
  ```

  Apply `.equatable()` where the row is constructed in the `ForEach`.
- `isCurrent` is computed **once per row, by the parent**, as a plain
  `Bool` (`segment.index == syncDriver.currentIndex`) passed into the row
  as an ordinary (non-`@Observable`, non-environment) `let` property. Row
  views must not read `syncDriver.currentIndex` (or `engine.currentTime`)
  themselves — only the parent (`TranscriptOverlayView`'s body, which
  legitimately re-runs on every `currentIndex` change) touches those
  observables. This is what makes `.equatable()` effective: because rows
  don't independently subscribe to the observable, SwiftUI's diffing
  correctly skips re-invoking the body for every row except the (at most
  two) whose `isCurrent` actually flipped.
- Word tokenization (§6.1) is computed once per segment and cached, never
  recomputed during scroll or sync ticks.
- The `[WordTokenID: CGRect]` anchor-preference map (§6.2) should only be
  actively collected/merged while `selecting` is in progress or about to
  start (i.e., the preference *reporting* from each token can be
  unconditional and cheap — it's just publishing a frame — but the
  *consumer* only bothers computing hit-tests from it during an active
  drag; don't run hit-testing logic every frame when nothing is being
  dragged).

## 12. Accessibility

- **Dynamic Type**: base font size 28pt via `@ScaledMetric(relativeTo: .title)`
  (or `.body` — pick one text style as the relative anchor and use it
  consistently). Cap scaling at `.accessibility2`: beyond that size
  category, switch to a tighter layout — reduce `lineSpacing` from 6 to 2
  and reduce inter-row `spacing` in the `LazyVStack` from 28 to 16 — via
  `@Environment(\.dynamicTypeSize)` checks (`dynamicTypeSize >= .accessibility3`
  as the trigger for the tighter mode, giving one accessibility step of
  normal spacing before tightening). Do not let text clip or truncate —
  the flow layout (§6.2) already wraps, so growing font size just means
  more lines, which is fine.
- **VoiceOver**: with VoiceOver running, per-row word-level tap targets
  are not practically navigable via swipe gestures, so collapse each row
  to a single accessibility element:
  `.accessibilityElement(children: .combine)`,
  `.accessibilityLabel("Line \(segment.index + 1)\(isCurrent ? ", currently playing" : ""), tap to play from \(formattedTimestamp(segment.startTime))")`
  where `formattedTimestamp` renders like `"3 minutes 5 seconds"` (spelled
  out, not `"3:05"`, for VoiceOver clarity), `.accessibilityAddTraits(.isButton)`,
  and `.accessibilityAction { onTapLine() }` (same seek action as §5).
  Additionally add a custom action for word-level translation's VoiceOver
  equivalent: `.accessibilityAction(named: "Translate line") { onTapLine's segment text sent to translate flow, opening the popover anchored to the row instead of a token }` — this is the practical VoiceOver substitute for per-word tap since fine-grained token navigation isn't realistic through swipe-based VoiceOver interaction.
- **Reduce Motion**: `@Environment(\.accessibilityReduceMotion)`. When
  true: auto-scroll uses the non-spring ease per §4.3; the optional
  non-current-row blur (§3.1) is skipped entirely; row opacity
  transitions still use a short `.easeInOut` (opacity-only fades are
  generally fine under reduce-motion; only movement/spring physics are
  avoided).

## 13. Preview & mock strategy

`Previews/PreviewMocks.swift`, wrapped in `#if DEBUG`:

- `FakePlayerEngine: PlayerEngineProtocol` — `@MainActor @Observable`.
  Holds `currentTime`, `state`, `rate`, `duration` as plain stored
  properties. `play()` starts a `Task` loop that does
  `try? await Task.sleep(for: .milliseconds(250)); currentTime += 0.25 * Double(rate)`
  repeatedly while `state == .playing`; `pause()` sets state and lets the
  loop's next check end it; `seek(to:)` sets `currentTime` directly and
  returns immediately (simulate an `await Task.yield()` for realism);
  `skip(by:)` adds/subtracts from `currentTime`, clamped to
  `0...(duration ?? .infinity)`.
- A canned Spanish `TranscriptHandle` builder function producing ~15–20
  segments, 2–6s apart, realistic short Spanish sentences, via the
  `internal init` from §2's preview-construction assumption. Provide
  variants: `.complete`, `.partial` (only first ~8 segments + `progress: 0.4`),
  `.pending` (empty segments), `.failed(reason: "asset download required")`.
- `FakeTranslationService: TranslationServiceProtocol` — returns a
  deterministic canned string (e.g. reverse the input, or a fixed
  `"[translated] \(text)"`) after an artificial `Task.sleep(for: .milliseconds(400))`
  to exercise the popover's loading state.
- `FakeExplainService: ExplainServiceProtocol` — `availability = .ready`;
  `explain(...)` returns an `AsyncThrowingStream` that yields 3–4
  increasingly-complete `PassageExplanation.PartiallyGenerated` values with
  small delays between them (to exercise the skeleton→content transition),
  then finishes.

`#Preview` blocks to include in `TranscriptOverlayView.swift` (or a
dedicated preview file), each wiring the fakes above through a
preview-only `AppContainer`/environment injection:

1. `.complete` transcript, mid-playback (currentTime inside a middle segment).
2. `.partial` transcript (verify frontier row + progress bar).
3. `.pending` transcript.
4. `.failed` transcript (verify banner + action button).
5. Popover open on a word (verify anchoring + translation loading→loaded).
6. Explain sheet open (verify skeleton shimmer → populated card).
7. Accessibility: Dynamic Type at `.accessibility5` and Reduce Motion
   enabled, layered via `.environment(\.dynamicTypeSize, .accessibility5)` /
   `.environment(\.accessibilityReduceMotion, true)` on a couple of the
   above.

This lets the whole overlay be exercised in Xcode Previews with zero real
audio, zero downloaded models, zero network.

### Manual verification script (device required)

1. Play a downloaded episode with a feed transcript; open the overlay;
   confirm the highlighted line tracks audio within ~1s (product overview
   success criterion) and auto-scroll keeps it roughly centered.
2. Manually scroll the transcript away from the current line; confirm
   auto-scroll stops; wait 4s without touching it; confirm it snaps back
   with the spring animation.
3. Scroll away again; tap the "Resume sync" pill; confirm immediate
   resync (no 4s wait).
4. Tap an earlier line; confirm haptic, instant highlight jump, and audio
   actually seeks there (within ~1s per product overview).
5. Tap a single word; confirm popover appears anchored at that word,
   shows original + translated text (spinner first if the language pack
   needed a moment), dismiss, confirm mode returns to what it was.
6. Press-and-hold a word, drag across 2–3 lines; confirm the highlighted
   region follows the finger, confirm it stops extending at 280
   characters with a warning haptic if you keep dragging; release;
   confirm the Translate/Explain action bar appears.
7. Tap Explain from the action bar; confirm the sheet opens at `.medium`,
   shows skeleton placeholders that fill in as content streams, and that
   **audio keeps playing** throughout; use the sheet's pause button;
   confirm playback pauses without the sheet closing; close the sheet;
   confirm playback state is unaffected by the close itself.
8. On a device/simulator without Apple Intelligence enabled, confirm the
   Explain path shows the inline unavailable banner instead of crashing
   or hanging.
9. Play an episode with no feed transcript so on-device transcription is
   running; open the overlay mid-transcription; confirm partial segments
   render, the frontier ellipsis row animates, and the progress percentage
   increases over time; confirm it disappears once complete.
10. Force a transcript failure (e.g. airplane mode on an episode with
    neither a feed transcript nor a cached on-device transcript); confirm
    the failed banner and its action button appear, and that tapping the
    button doesn't crash even if the retry also fails.
11. Enable VoiceOver; swipe through several lines; confirm each line's
    spoken label includes its position and spoken-out timestamp, and that
    activating a line seeks.
12. Set Text Size to a top accessibility size in Settings; confirm the
    overlay tightens spacing and nothing clips or becomes unreadable.
13. Enable Reduce Motion; confirm auto-scroll no longer uses the spring
    bounce (short ease or instant jump instead).

## 14. Acceptance criteria checklist

- [ ] Overlay presents full-screen from Now Playing via `fullScreenCover`, dismiss chevron works.
- [ ] Blurred artwork background with contrast gradient renders behind all content; falls back gracefully if artwork fails to load.
- [ ] Transcript lines: ~28pt bold rounded type, leading-aligned, current line full opacity, others ~0.35, generous line spacing.
- [ ] Current segment is derived via `SegmentSync.currentIndex` (binary search) with the exact edge semantics in §4.1, unit-tested in `LingoPodKitTests`.
- [ ] Auto-scroll centers the current line with a spring animation and only when mode is `syncing`.
- [ ] Manual scroll suspends auto-scroll; resumes after 4s idle or on "Resume sync" pill tap; never auto-scrolls during `selecting`/`popoverOpen`/`sheetOpen`.
- [ ] Tapping a line seeks playback, produces a haptic, and moves the highlight immediately (not gated on the next time-observer tick).
- [ ] Words render as individually tappable tokens via a custom wrapping `Layout`, correctly segmented (including for a no-space script) via `WordTokenizer`, unit-tested.
- [ ] Tapping a word opens an anchored popover with original + translated text (translated via `TranslationServiceProtocol`, cache-first, loading state shown), plus an "Explain more" link.
- [ ] Press-and-hold-drag selects a phrase across tokens/rows, capped at 280 characters, shows a Translate/Explain action bar on release.
- [ ] Explain streams `PassageExplanation.PartiallyGenerated` into a card with skeleton placeholders per field, an on-device-AI footer, and inline error/unavailable states with retry where applicable.
- [ ] Audio never auto-pauses when the Explain sheet opens; a pause control exists inside the sheet.
- [ ] All four transcript lifecycle states (`pending`/`partial`/`complete`/`failed`) render distinctly, with `partial` showing a frontier row + progress and `failed` showing an actionable banner.
- [ ] The five-mode state machine (§10) matches the transition table; no auto-scroll or state leaks across `selecting`/`popoverOpen`/`sheetOpen`.
- [ ] Row views are `Equatable` on `(segment.id, isCurrent)`, marked `.equatable()`, and read no observable state themselves; only the parent computes `isCurrent`.
- [ ] Dynamic Type scales the transcript, with a tighter layout past `.accessibility2`; VoiceOver exposes line-level labels with spoken timestamps and a seek action; Reduce Motion disables the spring auto-scroll and row blur.
- [ ] `PreviewMocks` (`FakePlayerEngine`, canned Spanish `TranscriptHandle` variants, fake translation/explain services) make every state above viewable in Xcode Previews without real audio, downloaded models, or network access.
