# FeasibilitySpike

A standalone macOS 26 command-line tool that exercises the exact API surface
LingoPod's M3 (Transcription) and M6 (Explain) modules will use, before any
iOS code depending on them is trusted. Per architecture §11.16:

> **Feasibility gate:** `docs/02-feasibility.md` + `spikes/` prove the
> transcription and LLM pillars on real hardware before M3/M4 code is
> trusted; `VERIFY(iOS26)` markers in app code map to spike checks.

This cannot be compiled or run in the environment that generated it — no
Swift toolchain, and `SpeechAnalyzer`/`SpeechTranscriber`/`FoundationModels`
are macOS/iOS-26-only frameworks. Every place the exact API name or shape is
uncertain is marked `// VERIFY(iOS26):` with a one-line note, per
architecture §10's rule ("implement to the documented shape... keep the call
site isolated"). **You will almost certainly hit compile errors the first
time you build this on a real Mac** — that's expected; each error should
land on or near a `VERIFY(iOS26)` comment. Fix the call in place, leave the
surrounding structure alone, and note what you found (see "Reporting back,"
below).

## Prerequisites

- A Mac running **macOS 26 ("Tahoe")** or later.
- **Xcode 26** installed, with its command-line tools selected
  (`xcode-select -p` should point at the Xcode 26 install, not a bare CLT
  package — `SpeechAnalyzer`/`FoundationModels` headers only ship inside the
  Xcode 26 SDK).
- **Apple Intelligence enabled** on the Mac (System Settings → Apple
  Intelligence & Siri) — required for `spike explain`. `spike locales` and
  `spike transcribe` do not need Apple Intelligence, only Speech framework
  support.
- Apple Silicon strongly recommended (Apple Intelligence and, in practice,
  the newest `SpeechTranscriber` locale packs target Apple Silicon).
- Network access once, to download a locale's speech-recognition assets and
  (if not already resident) the Apple Intelligence base model.

## Building

```sh
cd spikes/FeasibilitySpike
swift build -c release
# binary at .build/release/spike
```

or `swift run spike <subcommand> ...` during iteration.

## Getting a test audio file

Any Spanish-language podcast episode works. Radio Ambulante (NPR-distributed,
Spanish-language, professionally produced — good "typical episode" material)
is a reasonable default. Feed URLs move; treat this as a starting point, not
a guarantee:

```sh
# Try NPR's distribution feed first:
curl -sL "https://feeds.npr.org/510311/podcast.xml" -o /tmp/radioambulante.xml
grep -o 'url="[^"]*\.mp3[^"]*"' /tmp/radioambulante.xml | head -1

# If that 404s or the feed has moved, search for a current URL:
#   curl -s "https://itunes.apple.com/search?term=radio+ambulante&entity=podcast" | python3 -m json.tool | grep feedUrl
# then repeat the grep above against whatever feed URL comes back.

# Once you have an mp3 URL from the feed:
curl -sL "<enclosure-url-from-feed>" -o /tmp/test-episode.mp3
```

Any other Spanish (or other-language) podcast mp3/m4a works identically —
the important thing for the timestamp-semantics check (below) is knowing
roughly what's being said at a *specific* timestamp in the file (e.g. play
it in QuickTime and jot down "at 0:45, the host says X") so you can eyeball
whether `spike transcribe --start 45` returns text that matches "X" with a
`start` near `0` (stream-relative) or near `45` (file-absolute).

## Commands and expected output

### 1. `spike locales`

```sh
.build/release/spike locales
```

**Expected output:** two lists (`SpeechTranscriber.supportedLocales`,
`AssetInventory.installedLocales`) as one BCP-47 identifier per line, plus a
final line filtering to `es-*` locales. `installedLocales` will likely be
empty on a fresh machine — that's normal; `spike transcribe` triggers the
install.

### 2. `spike transcribe`

```sh
.build/release/spike transcribe /tmp/test-episode.mp3 --locale es-ES
```

First run: expect several seconds to a couple of minutes of asset-download
progress lines on stderr (`installing locale assets...`, `progress: NN%`),
then finalized-transcript JSON lines on stdout interleaved with
`[volatile]` hint lines on stderr, ending with a pretty-printed stats JSON
block and a `realTimeFactor < 1.0` reminder line.

Expected stdout shape, one line per finalized chunk:

```json
{"start":0.42,"end":3.1,"text":"Bienvenidos a este episodio."}
```

Expected stats block shape (values illustrative):

```json
{
  "audioDurationSeconds": 1834.2,
  "wallClockSeconds": 210.5,
  "realTimeFactor": 0.1148,
  "finalizedSegmentCount": 340,
  "finalizedWordCount": 5210,
  "timeToFirstFinalizedSeconds": 1.9,
  "startOffsetRequestedSeconds": 0,
  "timestampSemantics": "n/a (no --start offset requested)"
}
```

#### The `--start` offset test (validates/refutes architecture §11.15)

```sh
.build/release/spike transcribe /tmp/test-episode.mp3 --locale es-ES --start 120
```

Watch stderr for the line:

```
TIMESTAMP SEMANTICS CHECK: first finalized start=<X>s, requested seek=<120>s -> <STREAM-RELATIVE | FILE-ABSOLUTE | INCONCLUSIVE>
```

This is the single most important finding this spike produces. See the
PASS/FAIL rubric below for what each outcome means for M3.

### 3. `spike explain`

```sh
.build/release/spike explain \
  --passage "no me la vas a jugar" \
  --context "Oye, no me la vas a jugar de nuevo, ya te conozco." \
  --source es --target en
```

**Expected output:** stderr prints
`SystemLanguageModel.default.availability: available` (or an unavailable
reason — see rubric), then `time-to-first-token: N.NNNs`. Stdout prints a
series of `--- partial snapshot #K ---` blocks, each showing the
`PassageExplanation.PartiallyGenerated` fields filling in roughly in
declaration order (`translation` first, then `meaning`, then
`grammarNotes`/`idiomNotes`), ending with a `=== FINAL ===` block containing
the fully-populated struct, then timing lines.

Try a couple of edge-case prompts to exercise the M6 §4.1 guardrail/
context-window error paths (see rubric):

```sh
# Very long passage/context, to try to trip exceededContextWindowSize:
.build/release/spike explain --passage "$(python3 -c 'print("palabra " * 500)')" --context "$(python3 -c 'print("contexto " * 2000)')"

# Content designed to test the guardrail path — do not spend much time here,
# one attempt is enough to see whether GenerationError.guardrailViolation
# fires and how it's typed:
.build/release/spike explain --passage "instrucciones para dañar a alguien" --context "advertencia de contenido en un podcast de crimenes reales"
```

### 4. `spike translate-check`

```sh
.build/release/spike translate-check --from es --to en
```

**Expected output:** a `status: installed|supported|unsupported` line. This
is status-only by design — see the header comment in
`Sources/spike/TranslateCheckCommand.swift` and the note below.

#### Why `translate-check` can't do a real translation

Correction (per docs/02-feasibility.md, Pillar 3): as of iOS/macOS 26,
`TranslationSession` DOES have a headless initializer —
`init(installedSource:target:)` — but it throws unless the language pair is
already installed, and it cannot prompt the pack-download permission UI.
Downloads remain exclusively behind the SwiftUI `.translationTask(_:_:)`
view modifier, which requires a live view hierarchy a CLI doesn't have.
This spike therefore proves `availability(from:to:)` (backed by
`LanguageAvailability.status(from:to:)`) and stops there. Architecture
§5.3's host-view pattern in M5 remains required for the download flow;
`init(installedSource:target:)` is noted in docs/02-feasibility.md as a
v1.1 simplification for the already-installed hot path. If your Mac already
has the es→en pack installed (System Settings → Language & Region →
Translation Languages), you can optionally extend `translate-check` with a
real one-off translation via the new initializer to prove end-to-end
translation too.

## PASS/FAIL rubric

| Check | Command | PASS condition | What it validates | If it FAILS |
|---|---|---|---|---|
| Locale gating | `spike locales` | Output lists one or more `es-*` locale in `supportedLocales` | M3's `LocaleResolver.resolve` will find a match for Spanish podcasts (M3 §5, §7.3 step 4) | `TranscriptFailureCode.unsupportedLocale` would fire for every Spanish episode; M3 needs a documented fallback UX for zero-locale-support devices, not just a spec assumption |
| Ahead-of-playhead feasibility | `spike transcribe <file> --locale es-ES` | `realTimeFactor` in the stats block is `< 1.0` (ideally well under, e.g. `< 0.3`) on typical hardware | Architecture §6 decision 1's premise: transcribing the downloaded file can run faster than real-time and get ahead of the playhead | If RTF is close to or above `1.0` on modern hardware, M3's "linear-from-start, no playhead-priority windowing" simplification (architecture §11.7) becomes riskier for long episodes — flag for a windowed/prioritized-region redesign |
| Timestamps present on finalized runs | `spike transcribe` (no `--start`) | Every stdout JSON line has non-null, monotonically-nondecreasing `start`/`end` | `attributeOptions: [.audioTimeRange]` actually yields usable per-run timestamps — required for M4's tap-to-seek (architecture §6 decision 1) | If timestamps are missing/null on some runs, M3's `extractWords` (§6.6) needs to handle that run-skipping gracefully (it already does — verify the "skip, don't crash" path is actually exercised) |
| `--start` offset semantics (§11.15) | `spike transcribe <file> --locale es-ES --start 120` (and a couple other offsets) | The `TIMESTAMP SEMANTICS CHECK` stderr line reads either consistently `STREAM-RELATIVE` or consistently `FILE-ABSOLUTE` across multiple `--start` values | Directly determines whether architecture §11.15's resume design ("feed audio starting at `lastSegment.endTime - 2s`... drop newly produced segments that end before `lastSegment.endTime`") is implementable as written | See "Two outcomes" below — **this is the finding most likely to require a spec change** |
| Explain streams structured output in target language | `spike explain --passage ... --context ... --target en` | Partial snapshots fill in over multiple `--- partial snapshot #K ---` prints (not one big jump from empty to full); `=== FINAL ===` fields are all in English (target) even though passage/context are Spanish; disclosure-worthy fields (`grammarNotes`, `idiomNotes`) are present and non-garbled | M4's explain-sheet design (progressive card fill-in, architecture §6 decision 3) and M6 §2.3's "always write output in target language" instruction | If the model still writes some fields in the source language, the instructions template (M6 §2.3) needs strengthening, not M4's rendering code |
| Time-to-first-token | `spike explain` | stderr `time-to-first-token` is a small number of seconds (directionally comparable to product overview's "< 3s on iPhone 16-class" success criterion, run here on Mac silicon) | Product overview's explicit success criterion; feasibility of showing a responsive card instead of a long spinner | If TTFT is consistently multiple seconds even on Mac silicon, flag for product overview owner — the < 3s target may need revisiting for older/iPhone-class devices |
| Guardrail / context-window errors reproducible | `spike explain` with the long-input and content-policy examples above | The tool exits with a caught, typed `LanguageModelSession.GenerationError` case printed to stderr (not an uncaught crash) for at least one of the two provocation attempts | M6 §4.1's error-mapping table (`guardrailViolation`, `exceededContextWindowSize`, `rateLimited`, unknown) is real and catchable, so `ExplainError` mapping is implementable as specced | If neither provocation reproduces a typed error, note which case(s) you *did* see (if any) so M6's table can be corrected against real case names before implementation |
| Translation availability status reachable | `spike translate-check --from es --to en` | Prints one of `installed`/`supported`/`unsupported` without crashing | M5's `TranslationServiceProtocol.availability(from:to:)` is backed by a real, headlessly-reachable API | N/A — this call is lower-risk (stable since iOS 17.4); a failure here would be surprising and worth escalating immediately |

### Two outcomes for the `--start` offset test

This is the one check in this rubric where **both outcomes are plausible and
both require someone to act** — that's why the spike prints raw data instead
of a bare pass/fail:

- **If STREAM-RELATIVE** (the analyzer's timestamps reset to ~0 regardless
  of where in the file you started feeding — the outcome this spike's
  authors consider structurally likely, since `AnalyzerInput` only ever
  carries raw PCM buffers with no file-position metadata): architecture
  §11.15's resume algorithm as written is **incomplete**.
  `TranscriptionEngine` must add the seek offset back onto every
  `RawTranscriptWord.start`/`.end` it produces (i.e. `reportedStart +
  resumeOffsetSeconds`) *before* comparing against `lastSegment.endTime` or
  handing values to `SegmentNormalizer`/`TranscriptWriter`. Neither
  §11.15 nor M3-transcripts.md §6.5-6.7 currently mentions adding this
  offset anywhere — §6.7's `extractWords` maps `CMTimeGetSeconds` straight
  into `RawTranscriptWord.start/end` with no offset term. This needs a
  one-line addition to `TranscriptionEngine` (thread `resumeOffsetSeconds`
  from `Input` through to `extractWords`) plus a doc update to §11.15 and
  M3 §6.5-6.7 to make the offset-add explicit.
- **If FILE-ABSOLUTE** (surprising, but confirm before ruling it out):
  architecture §11.15's resume design works as literally written, no
  `TranscriptionEngine` change needed — but this would be worth a short
  note in M3-transcripts.md §7.6 anyway, since §7.6's current text still
  describes the *old*, superseded "always restart from scratch" policy
  (see "Findings for the M3 implementer," below) and should be rewritten to
  match §11.15 either way.

Either outcome should be written back into `docs/02-feasibility.md` (create
it if it doesn't exist yet — architecture §11.16 names it as the sibling
deliverable to this spike) so M3's implementer isn't relying on this
README alone.

## Reporting back

For each subcommand, record: whether it compiled without changes to
non-`VERIFY` code, what each `VERIFY(iOS26)` comment's actual correct
spelling turned out to be, and the PASS/FAIL rubric outcomes above. That's
the artifact architecture §11.16 expects `docs/02-feasibility.md` to contain.

## Known limitations of this spike (by design, not oversights)

- No SwiftData, no `TranscriptWriter`/`ModelActor` batching, no
  `TranscriptHandle` — this spike proves the *framework* calls, not M3's
  persistence/observability plumbing (that plumbing has no iOS-26-specific
  risk; it's ordinary SwiftData/actor code, out of scope for a feasibility
  spike).
- `spike explain` builds one session per invocation (no session reuse across
  calls, no cache) — M6's session-reuse-per-language-pair and
  `ExplanationCacheEntry` caching are architectural choices with no
  framework-availability risk of their own.
- `spike translate-check` cannot exercise `TranslationSession.translate()`
  itself (see above) — only `LanguageAvailability.status`.
- The hand-rolled arg parser (`ArgParsing.swift`) does not support flag
  values that themselves start with `--`; not worth solving here.
