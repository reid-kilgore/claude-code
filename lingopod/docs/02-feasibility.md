# LingoPod — Feasibility Evidence (docs research pass)

Status: **research-verified against primary sources; hardware spike pending.**
This document is one half of the feasibility gate defined in architecture
§11.16; the other half is `spikes/FeasibilitySpike/`, whose subcommands
(`locales`, `transcribe [--start]`, `explain`, `translate-check`) resolve the
questions documentation cannot (see "Device spike checklist," below).

## Methodology

Every row below cites a URL that was actually fetched during this research
pass (2026-07-09), not a search-result snippet. Note on Apple documentation
URLs: `developer.apple.com/documentation/...` pages are JavaScript-rendered
and return only page titles to plain HTTP fetches, so evidence was pulled
from Apple's underlying DocC JSON endpoints at
`developer.apple.com/tutorials/data/documentation/....json` — the same
primary source in machine-readable form. Rows cite whichever form was
fetched. Where a fetch failed (403/JS shell), the row says so and confidence
is lowered accordingly. Confidence scale: **High** = confirmed from a fetched
primary (Apple) source; **Med** = supported by a fetched source but with an
inference step, or primary source partially inaccessible; **Low** =
secondary/unfetched sources only — treat as a spike question, not a fact.

---

## Pillar 1 — SpeechAnalyzer / SpeechTranscriber (Speech framework)

| # | Claim (from architecture §6.1, product overview) | Evidence | Confidence | Fallback if false |
|---|---|---|---|---|
| 1.1 | `SpeechAnalyzer`+`SpeechTranscriber` exist in iOS 26 and are Apple's recommended long-form on-device transcription API, superseding `SFSpeechRecognizer` | **TRUE.** WWDC25 session 277 ("Bring advanced speech-to-text to your app: SpeechAnalyzer"): "New API and model replacing SFSpeechRecognizer… Faster and more flexible than the previous model… Already powering system apps: Notes, Voice Memos, Journal." Speech framework overview files `SFSpeechRecognizer` under a "Legacy API" section; SpeechAnalyzer/SpeechTranscriber under "Essentials." URLs: <https://developer.apple.com/videos/play/wwdc2025/277/> ; <https://developer.apple.com/tutorials/data/documentation/speech.json> | High | None needed — but if the API were absent, the whole M3 pillar falls back to feed transcripts only (product overview's explicit degraded state). |
| 1.2 | Results are `AttributedString` whose **runs** carry an `audioTimeRange` (`CMTimeRange`) attribute — timestamps usable for tap-to-seek | **TRUE.** `SpeechTranscriber.Result.text` is `AttributedString`; timestamps enabled via `ResultAttributeOption.audioTimeRange` ("Includes time-code attributes in a transcription's attributed string"), read per run. URLs: <https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/result.json> ; <https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/resultattributeoption.json> | High | If timestamps were absent, tap-to-seek granularity collapses to feed transcripts only; M4's overlay degrades to non-seekable text. Not needed. |
| 1.3 | Timestamp granularity is per **word** | **PARTIALLY TRUE — documented contract is per-run, not per-word.** Apple's sample code iterates `.runs` to highlight "each word," implying runs are typically word-sized when volatile results are enabled, but the API only guarantees run-level attributes. URL: as row 1.2. | Med | Architecture already tolerates this: §6.4 says v1 highlight granularity is the *segment*, and `TranscriptSegment.wordTimings` may legitimately be coarse/empty. M3 §6.6 `extractWords` must skip runs lacking `audioTimeRange` rather than crash (rubric row 3 of the spike README). Spike `transcribe` verifies actual run sizing. |
| 1.4 | Volatile (provisional) vs finalized results are both available | **TRUE, with a shape detail.** `ReportingOption.volatileResults` "Provides tentative results for an audio range in addition to the finalized result." Both kinds arrive on a **single** `results` async sequence distinguished by `Result.isFinal: Bool` — not two separate sequences. URL: <https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/reportingoption.json> | High | N/A — M3 only persists finalized results, which is compatible with either shape. Pipeline code must branch on `isFinal`, not consume two streams. |
| 1.5 | Fully on-device; works offline after a per-locale asset download managed via `AssetInventory`; locale support queried via `SpeechTranscriber.supportedLocales` | **TRUE.** `AssetInventory` "Manages the assets that are necessary for transcription… machine-learning models downloaded from Apple's servers and managed by the system." `static var supportedLocales: [Locale] { get async }` — "locales the transcriber can transcribe into, including locales that may not be installed but are downloadable." WWDC25 transcript: "transcription is entirely on device but the models need to be fetched." URLs: <https://developer.apple.com/tutorials/data/documentation/speech/assetinventory.json> ; <https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/supportedlocales.json> ; <https://developer.apple.com/videos/play/wwdc2025/277/> | High | If a target locale is unsupported: already designed — `TranscriptFailureCode.unsupportedLocale` → feed transcript or explicit empty state (product overview "Key risks" row 1). |
| 1.6 | Launch language coverage includes the pairs LingoPod cares about (es, fr, de, ja, zh, pt, it, ko, …) | **PLAUSIBLE BUT NOT APPLE-DOC-CONFIRMED.** The locale list is dynamic (`supportedLocales`), and no fetched Apple page enumerates it. A ~40-locale list (ar, da, de ×3, en ×8, es ×4, fi, fr ×4, he, it ×2, ja, ko, ms, nb, nl ×2, pt-BR, ru, sv, th, tr, vi, yue, zh ×3) recurs in community writeups traced to Xcode 26 beta SDK contents, but the two candidate confirming pages could not be fetched (one had no list; one returned HTTP 403 via the proxy). | **Low** | This is spike `locales`' first job: print `supportedLocales` on real hardware. If a launch language is missing, that language ships feed-transcript-only, with the per-podcast language override (§ product overview) unchanged. |
| 1.7 | Faster than real time on device; long-form audio (30–60 min) supported without SFSpeechRecognizer's ~1-minute limits | **PARTIALLY TRUE.** WWDC25: the new model is "faster and more flexible than the one previously available through SFSpeechRecognizer," designed for "long-form and conversational use cases," "sustained transcription over minutes or hours" — long-form support is explicit. But **no** "faster than real-time" phrase and **no numeric benchmark** appear in Apple materials; a third-party benchmark post (Argmax) returned 403 and could not be verified. URL: <https://developer.apple.com/videos/play/wwdc2025/277/> | Med (long-form: High; speed: **Low/undocumented as a number**) | If real-time factor ≥ ~1.0 on target hardware, §11.7's "linear-from-start, no windowing" simplification is at risk — fallback is playhead-priority windowed transcription (product overview "Key risks" row 2). Spike `transcribe` measures RTF directly. |
| 1.8 | Can analyze from an audio FILE, not just live mic | **TRUE.** `SpeechAnalyzer.analyzeSequence(from:)`: `final func analyzeSequence(from audioFile: AVAudioFile) async throws -> CMTime?` — "When this method returns, the file will have been read… Returns the time-code of the last audio sample of the input." Also `start(inputAudioFile:finishAfterFile:)`. URL: <https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer/analyzesequence(from:).json> | High | None needed; this is the exact input mode §6.1 chose. |
| 1.9 | Can start analysis mid-file at an arbitrary offset (required by §11.15 resume-from-checkpoint) | **UNDOCUMENTED.** Both file-input APIs take a whole `AVAudioFile`; no parameter or documented mechanism for starting at a time offset or resuming from a checkpoint. Seeking `AVAudioFile.framePosition` before handing the file over *may* work, and feeding buffers from an offset via `AnalyzerInput` certainly compiles — but whether resulting timestamps are then **stream-relative** (restart at ~0) or **file-absolute** is not documented anywhere fetched. | **Low — designated spike question #1** | The app ships §11.15 with a **defensive offset-detection branch**: `TranscriptionEngine` threads `resumeOffsetSeconds` through to timestamp extraction and adds it back if the spike proves timestamps are stream-relative (the structurally likely outcome — `AnalyzerInput` carries raw PCM with no file-position metadata). Spike `transcribe --start N` decides which branch is real; see the two-outcomes analysis in `spikes/FeasibilitySpike/README.md`. Worst case (offsets unusable entirely): resume degrades to re-transcribe-from-scratch — the pre-§11.15 design — costing recompute time but no functionality. |
| 1.10 | Available on macOS 26 with the same API (so the Mac CLI spike is valid iOS evidence) | **TRUE.** Both `SpeechAnalyzer` and `SpeechTranscriber` doc pages list iOS 26.0+, iPadOS 26.0+, Mac Catalyst 26.0+, **macOS 26.0+**, tvOS 26.0+, visionOS 26.0+ (watchOS excluded), identical API surface. URLs: <https://developer.apple.com/tutorials/data/documentation/speech/speechanalyzer.json> ; <https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber.json> | High | N/A. Caveat: Mac RTF numbers will be optimistic vs iPhone; treat Mac spike as API-shape evidence, and A17/M-series iPhone RTF as a separate device question. |

---

## Pillar 2 — FoundationModels

| # | Claim (from §5.4, §6.3, M6) | Evidence | Confidence | Fallback if false |
|---|---|---|---|---|
| 2.1 | Exact API spellings: `LanguageModelSession(instructions:)`, `streamResponse(...)`, `@Generable`, `@Guide(description:, .count(0...4))`, `PartiallyGenerated` | **TRUE — all confirmed.** `LanguageModelSession` `init(model:tools:instructions:)` with instructions-builder usage `LanguageModelSession(instructions: "…")`; `streamResponse(generating:includeSchemaInPrompt:options:prompt:) -> ResponseStream<Content>` for `@Generable` types; `@Generable` macro on structs/enums; `associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self` on the `Generable` protocol; `@Guide` with `description:` plus `GenerationGuide.count(_:)` documented for both exact `Int` and `ClosedRange<Int>` (so `.count(0...4)` in §5.4 is valid). URLs: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession> ; <https://developer.apple.com/documentation/foundationmodels/generable-swift.macro> ; <https://developer.apple.com/documentation/foundationmodels/generationguide/count(_:)> (all fetched via the `/tutorials/data/documentation/….json` endpoints) | High | None needed. |
| 2.2 | Availability gating via `SystemLanguageModel.default.availability` with cases for device/AI/model readiness | **TRUE.** `SystemLanguageModel.Availability` has exactly two cases: `.available` and `.unavailable(UnavailableReason)`; `UnavailableReason` has exactly three: `.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`. URL: <https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason>. Device/region prerequisites (A17 Pro-class iPhone or later, Apple Silicon Mac/iPad, Apple Intelligence enabled, staged regional rollout) are consistent across sources but the primary "Acceptable use requirements" page returned a JS shell and could not be fetched. | High (enum cases) / Med (device-region prerequisites) | Already designed for: `ExplainAvailability` gating in §5.4/§8; devices without Apple Intelligence keep transcription + translation and lose only Explain. This matches product overview's out-of-scope note (no cloud fallback). |
| 2.3 | Context window ≈ 4096 tokens | **TRUE.** Apple technote TN3193, direct quote: "Apple's on-device foundation model has a context window of 4096 tokens per language model session." URL: <https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window>. (Note: post-iOS 26.4 additions — `contextSize` / `tokenCount(for:)` — suggest the figure may become queryable/dynamic; M6 should query at runtime where available rather than hard-coding 4096.) | High | 4096 tokens comfortably fits a highlighted passage + surrounding-segment context + the `PassageExplanation` schema. M6 must truncate `context` defensively and map `.exceededContextWindowSize` to a retry-with-less-context path (its §4.1 table already does). |
| 2.4 | Rate limits documented | **UNDOCUMENTED.** No official thresholds (foreground/background) found; however `GenerationError.rateLimited(_:)` exists as a case, proving throttling occurs mechanically. URL: as row 2.5. | Low | M6 treats `.rateLimited` as transient-retry with backoff; Explain is a user-initiated foreground action, the least likely to be throttled. |
| 2.5 | `GenerationError` includes `.guardrailViolation` and `.exceededContextWindowSize` | **TRUE, with a naming correction.** The type is the **nested** `LanguageModelSession.GenerationError` (not a top-level `FoundationModels.GenerationError`). Confirmed cases: `assetsUnavailable`, `decodingFailure`, `exceededContextWindowSize`, `guardrailViolation`, `rateLimited`, `refusal`, `concurrentRequests`, `unsupportedGuide`, `unsupportedLanguageOrLocale`. URL: <https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror>. Caveat: the fetched page carries a deprecation note ("as of iOS 27.0" in favor of `LanguageModelError`-family types) reflecting the current mid-2026 docs, not the iOS 26 surface we target — catch sites should be isolated in M6's thin wrapper per §10 so the future rename is one-file work. | High (cases) / Med (deprecation trajectory) | M6 §4.1's error-mapping table is implementable as specced; also map `.refusal` and `.unsupportedLanguageOrLocale`, which the spec's table should add. |
| 2.6 | On-device model is multilingual; can explain Spanish text with English instructions/output | **PARTIALLY TRUE / Med.** WWDC25 "Meet the Foundation Models framework" is reported (via wwdcnotes.com summary + search corroboration — the Apple transcript fetch returned 403) as stating the model "is multilingual" and recommending "instructions in English with the user prompt in the desired language" — which directly matches M6's design. Apple Intelligence's language list (per Apple newsroom, not developer docs): English, French, German, Italian, Portuguese, Spanish, Japanese, Korean, Chinese (Simplified/Traditional), with Danish, Dutch, Norwegian, Swedish, Turkish, Vietnamese added through 2025–26. | Med (multilingual claim) / Low (exact list) | If cross-language quality is poor for a pair, `GenerationError.unsupportedLanguageOrLocale` and output-quality checks route users to translation-only (Pillar 3 still works). **Explain-quality in the actual tutoring direction (es passage → en explanation) is spike question #4** — docs cannot answer quality. |
| 2.7 | `PartiallyGenerated` values constructible manually (for cache-replay of `ExplanationCacheEntry`) | **UNDOCUMENTED AS A PATTERN; possible in principle via public API.** `PartiallyGenerated` conforms to `ConvertibleFromGeneratedContent`, whose sole requirement is `init(_ content: GeneratedContent) throws`; `GeneratedContent` has public `init(properties:id:)` and `init(json:)`. So `PassageExplanation.PartiallyGenerated(GeneratedContent(json: cachedBlob))` should compile — but Apple never documents this replay pattern, and `GenerationID`/`isComplete`/nested-partial semantics are unverified. URLs: <https://developer.apple.com/documentation/foundationmodels/convertiblefromgeneratedcontent> ; <https://developer.apple.com/documentation/foundationmodels/generatedcontent> | Med — **designated spike question #6** | Zero-risk fallback already implicit in §5.4: decode the cached `explanationJSON` into the *complete* `PassageExplanation` and emit it as a single final stream element (an `AsyncThrowingStream` of one). Cache replay loses the fill-in animation, nothing else. |

---

## Pillar 3 — Translation framework

| # | Claim (from §5.3, §11.5, M5) | Evidence | Confidence | Fallback if false |
|---|---|---|---|---|
| 3.1 | `TranslationSession` obtainable only via SwiftUI `.translationTask` | **PARTIALLY TRUE — true through iOS 18, relaxed in iOS 26.** iOS/macOS 26 added `convenience init(installedSource:target:)`: "Creates a translation session to translate between a given source and target language already installed on device… If you created TranslationSession using init(installedSource:target:), you don't need a .translationTask()." It **throws if the pair isn't installed** — the download-permission UI is still only reachable through `.translationTask`. URL: <https://developer.apple.com/tutorials/data/documentation/translation/translationsession/init(installedsource:target:).json> | High | Not a failure — a **simplification opportunity**: M5's host-view pattern (§5.3 note) remains required for the *download* flow, but the steady-state hot path (pair already installed) can use direct construction, shrinking the host-view queue to first-run-per-pair only. Recorded as a **v1.1 simplification candidate for M5**; v1 ships the host-view pattern as specced. Note: `spikes/FeasibilitySpike/README.md`'s "no documented headless initializer" paragraph is **outdated** on this point and `translate-check` could be extended to attempt a real translation via this init when the pair is installed. |
| 3.2 | Batch translation API exists | **TRUE.** Two documented methods (iOS 18.0+/macOS 15.0+): `translate(batch: [TranslationSession.Request]) -> TranslationSession.BatchResponse` (AsyncSequence, incremental) and `translations(from: [TranslationSession.Request]) async throws -> [TranslationSession.Response]` (all-at-once, order preserved). URLs: <https://developer.apple.com/tutorials/data/documentation/translation/translationsession/translate(batch:).json> ; <https://developer.apple.com/tutorials/data/documentation/translation/translationsession/translations(from:).json> | High | N/A — v1 mostly needs single-item translate; batch helps future pre-translation of segments. |
| 3.3 | `LanguageAvailability.status(from:to:)` for pair status | **TRUE.** `LanguageAvailability` (iOS 18.0+/macOS 15.0+): `func status(from: Locale.Language, to: Locale.Language?) async -> Status`, plus a sample-text overload; statuses `.installed` / `.supported` / `.unsupported` — mapping 1:1 onto §5.3's `TranslationAvailability` (`ready`/`needsDownload`/`unsupported`). URL: <https://developer.apple.com/tutorials/data/documentation/translation/languageavailability.json> (status case names summarized from the fetched JSON, not verbatim-diffed) | High | N/A. |
| 3.4 | `prepareTranslation` triggers language-pack download ahead of need | **TRUE (instance method, not a view modifier).** `func prepareTranslation() async throws` on `TranslationSession`: "Asks for permission to download translation languages without doing any translations… If the languages are already installed or in the middle of downloading, the function returns without prompting." URL: <https://developer.apple.com/tutorials/data/documentation/translation/translationsession/preparetranslation().json> | High | §11.5's `TranslationDownloadPreparing.prepare(from:to:)` maps directly onto this; the session it's called on must come from `.translationTask` (row 3.1). |
| 3.5 | Supported language pairs cover the app's launch pairs | **UNDOCUMENTED as a static list.** `var supportedLanguages: [Locale.Language] { get async }` is the only official surface — dynamic, no enumerated list in docs. Closest proxy (Translate app, via secondary sources; Apple support page 104786 returned 403): ~19–20 languages — Arabic, Chinese (CN/TW), Dutch, English (US/UK), French, German, Indonesian, Italian, Japanese, Korean, Polish, Portuguese (BR), Russian, Spanish, Thai, Turkish, Ukrainian, Vietnamese — **notably narrower than Speech's ~40+ locale list.** URL (fetched): <https://developer.apple.com/tutorials/data/documentation/translation/languageavailability/supportedlanguages.json> | Low-Med | Consequence to design for: there will be podcast languages we can *transcribe* but not *translate* (and vice versa is unlikely). §11.5's `TranslationFallbackProviding` (LLM fallback when the pair is unsupported) is exactly the mitigation — keep it. Spike `translate-check` (and `supportedLanguages` dump) confirms real pairs. |
| 3.6 | Fully offline after pack install | **STRONGLY IMPLIED, not explicitly guaranteed.** WWDC24 "Meet the Translation API": "TranslationSession performs translation using on-device ML models… shared with all apps on the system, including the Translate app," and `prepareTranslation()` is recommended "for situations where the user will be offline when they want to use translation." No literal "zero network calls" sentence found. URL: <https://developer.apple.com/videos/play/wwdc2024/10117/> | Med | Airplane-mode translation is part of the demo script; verify explicitly in the on-device pass (radio off, translate a cached-pair word). Cache layer (`TranslationCacheEntry`) already guarantees repeat lookups offline regardless. |
| 3.7 | Works on macOS (spike validity) | **TRUE, with a shape caveat.** `TranslationSession`/`.translationTask` documented macOS 15.0+ (framework floor macOS 14.4+; Mac Catalyst 26+ for the new init). `.translationTask` needs a live SwiftUI view, so a bare CLI cannot drive the download flow — which is why `translate-check` is status-only. `init(installedSource:target:)` (macOS 26+) now allows a CLI to run *real* translations for already-installed pairs. URLs: <https://developer.apple.com/tutorials/data/documentation/translation/translationsession.json> ; <https://developer.apple.com/tutorials/data/documentation/swiftui/view/translationtask(_:action:).json> | High | If CLI construction proves brittle, a minimal SwiftUI Mac app target in `spikes/` is a half-day fallback for exercising the full download+translate flow. |

---

## Local persistence: cost of "transcribe once, store forever" (§11.15)

**Compute cost, per episode, once ever.** A 30-min episode is 1,800 s of
audio. Apple documents long-form support but publishes no real-time-factor
numbers (row 1.7), so treat the spike's measured RTF as the real figure. For
planning: at RTF 0.15–0.3 (plausible for an on-device model that Apple calls
"faster" than SFSpeechRecognizer's, on A17/M-class silicon), a 30-min episode
transcribes in ~4.5–9 min of background compute; at a pessimistic RTF 0.5,
15 min. Battery: **no published data** from Apple for SpeechTranscriber —
spike/device measurement only. Because the result is durable (finalized
segments commit in batches, §11.15), this cost is paid exactly once per
episode per locale; every later playback, seek, translate, and explain runs
against SwiftData with zero model invocations.

**Storage cost, per 30-min episode (arithmetic).**

- Speech at ~150 wpm × 30 min ≈ **4,500 words**; average word ~5.1 chars + 1
  space ≈ 6.1 bytes UTF-8 → segment text ≈ **27 KB**.
- Segments at ~90 chars / 2–8 s (§4): ~360 segments; ~150 B/row SwiftData
  overhead → ≈ **54 KB**.
- `wordTimings` (the dominant term): 4,500 × (~word text + two Doubles +
  a `Range<Int>` ≈ 50 B serialized) → ≈ **225 KB**.
- **Total ≈ 300 KB ≈ 0.3 MB per 30-min episode.**

The episode's own audio at 64–128 kbps is **14–29 MB** — the transcript is
~**1–2 %** of the audio it describes. Even a heavy library (500 transcribed
episodes) is ~150 MB of transcript data vs ~10+ GB of audio; transcript
storage is never the constraint, and never evicting them (§11.15) is free in
practice. `TranslationCacheEntry`/`ExplanationCacheEntry` rows are hundreds
of bytes to single-digit KB each — noise at any plausible usage level.

---

## Device spike checklist

Questions that only `spikes/FeasibilitySpike` on real macOS-26/iOS-26
hardware can answer, mapped to its subcommands (`locales`, `transcribe
[--start]`, `explain`, `translate-check`) and the README's PASS/FAIL rubric:

1. **Mid-file resume timestamp semantics (`transcribe --start N`)** — are
   timestamps stream-relative or file-absolute when analysis starts at an
   offset? Decides which branch of §11.15's defensive offset-detection
   design is live code (row 1.9). *The single highest-stakes unknown.*
2. **Real-time factor on target silicon (`transcribe`)** — measured RTF for
   a 30–60 min Spanish episode on an M-series Mac, then on an A17-class
   iPhone. Validates §11.7 linear-from-start vs forcing a windowed redesign
   (row 1.7).
3. **Timestamp granularity and accuracy (`transcribe`)** — are runs
   effectively word-sized? Do `audioTimeRange` values land within ~1 s of
   the actual audio (product principle 4, "honest timestamps"), including
   late in a long file (drift check)? (Rows 1.2–1.3.)
4. **Explain quality for language tutoring (`explain`)** — with English
   instructions and a Spanish passage, does `PassageExplanation` come back
   fully in English, with useful grammar/idiom notes, streaming
   field-by-field, with time-to-first-token in the < 3 s ballpark? (Rows
   2.6, product success criteria.)
5. **Model behavior when passage language ≠ instructions language, and error
   reproduction (`explain` edge cases)** — does `unsupportedLanguageOrLocale`
   fire for niche pairs; are `guardrailViolation` /
   `exceededContextWindowSize` catchable as typed
   `LanguageModelSession.GenerationError` cases per M6 §4.1? (Row 2.5.)
6. **`PartiallyGenerated` manual constructibility** — does
   `PassageExplanation.PartiallyGenerated(GeneratedContent(json:))` compile
   and behave (nested arrays, IDs) for cache replay, or do we take the
   single-final-element fallback? (Row 2.7; add a small case to `explain` or
   a scratch target.)
7. **Actual locale coverage (`locales`)** — dump
   `SpeechTranscriber.supportedLocales` and confirm the launch languages
   (es/fr/de/ja/zh/pt/it/ko variants) are present; note asset download size
   and time on first `transcribe`. (Row 1.6.)
8. **Translation pair reality (`translate-check`)** — `status(from:to:)`
   results for the launch pairs against the device's UI language, plus a
   `supportedLanguages` dump; optionally exercise
   `TranslationSession(installedSource:target:)` for an installed pair to
   validate the v1.1 direct-construction path (row 3.1). Then one
   airplane-mode translation to close row 3.6.

---

## Verdicts

| Pillar | Verdict | Justification |
|---|---|---|
| 1 — SpeechAnalyzer/SpeechTranscriber | **GO-WITH-RISK** | Every architectural load-bearing claim (existence, file input, run timestamps, AssetInventory offline model, macOS parity) is High-confidence confirmed; the two open items — mid-file resume semantics (§11.15) and unquantified RTF — both have designed fallbacks and are exactly what spike `transcribe [--start]` measures. |
| 2 — FoundationModels | **GO** | All API spellings, availability gating, the 4096-token context window, and the specific `GenerationError` cases M6 depends on are confirmed from primary Apple docs; the two soft spots (cache-replay `PartiallyGenerated`, cross-language tutoring quality) have zero-risk fallbacks that don't change any interface. |
| 3 — Translation | **GO** | Everything M5 was specced against is confirmed (batch API, `LanguageAvailability.status`, `prepareTranslation`, macOS support), and the one surprise — iOS 26's `init(installedSource:target:)` — makes the design *simpler*, not wrong (v1.1 candidate); narrower-than-Speech language coverage is real but already mitigated by §11.5's LLM fallback. |

**No claim failed verification in a way that invalidates the architecture.**
The one genuine documentation gap that touches a ratified decision is §11.15
mid-file resume (row 1.9), which is undocumented rather than contradicted,
and ships behind a defensive branch until spike `transcribe --start`
resolves it. One doc correction to propagate: `spikes/FeasibilitySpike/`
README's claim that `TranslationSession` has no headless initializer is
outdated as of iOS/macOS 26 (row 3.1).
