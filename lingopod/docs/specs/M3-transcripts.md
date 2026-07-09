# M3 — Transcripts

Status: spec for implementation. Binding contract: `docs/00-product-overview.md`
and `docs/01-architecture.md`. This spec adds detail; it does not override
either doc. Where this spec had to make a judgment call not fully settled by
those docs, it says so explicitly (search for "**Judgment call**").

This is the riskiest module in the app: it is the only place that touches an
iOS 26 framework whose exact API shape can't be fully verified from this
environment (`Speech` / `SpeechAnalyzer`). Every place the exact API name or
behavior is uncertain is marked `// VERIFY(iOS26):`. Follow the rule in
architecture §10: implement to the documented shape, keep the guess isolated
in a thin wrapper, don't restructure around it.

## 0. Scope

M3 owns:

1. Three pure parsers (SRT, VTT, Podcasting-2.0 JSON) → `[RawTranscriptCue]`.
2. `SegmentNormalizer`, pure, converts raw cues *or* on-device word timings
   into canonical `NormalizedSegment`s (the segmentation rule owner per
   architecture §4).
3. `TranscriptionEngine`, an actor wrapping `SpeechAnalyzer`/`SpeechTranscriber`
   for on-device transcription of a downloaded episode's audio file.
4. `TranscriptProvider`, the concrete implementation of
   `TranscriptProviderProtocol` (architecture §5.2) that orchestrates
   feed-vs-on-device sourcing, persistence, and single-flight concurrency.
5. `TranscriptHandle` construction/update mechanics (the `@MainActor` type is
   *declared* in architecture §5.2; this spec covers how M3 drives it).

M3 does **not** own: RSS/feed XML parsing (M1 parses `<podcast:transcript
href= type=>` into `Episode.feedTranscriptURL`/`feedTranscriptType` — M3
only fetches whatever URL M1 already extracted), episode downloading (M1),
playback (M2), or any UI (M4 renders `TranscriptHandle`).

## 1. File map

```
LingoPodKit/Sources/LingoPodKit/Transcripts/
  RawTranscriptCue.swift          // + RawTranscriptWord, NormalizedSegment
  TranscriptParseError.swift
  TranscriptFailureCode.swift
  SRTParser.swift
  VTTParser.swift
  PodcastIndexJSONTranscriptParser.swift
  TranscriptFormatSniffer.swift   // MIME/extension/content-sniff dispatch
  SegmentNormalizer.swift
  LocaleResolver.swift

LingoPodKit/Tests/LingoPodKitTests/
  SRTParserTests.swift
  VTTParserTests.swift
  PodcastIndexJSONTranscriptParserTests.swift
  SegmentNormalizerTests.swift
  LocaleResolverTests.swift
  Fixtures/Transcripts/           // see §10

LingoPod/Transcription/
  TranscriptionEngine.swift       // actor; SpeechAnalyzer pipeline
  SpeechTranscribing.swift        // thin protocol wrapping Speech framework calls (the VERIFY(iOS26) seam)
  TranscriptWriter.swift          // @ModelActor; batched SwiftData writes
  TranscriptProvider.swift        // TranscriptProviderProtocol conformance + orchestration
```

`TranscriptProviderProtocol` and `TranscriptHandle` themselves are declared
in `LingoPod/App/Interfaces.swift` per architecture §5 — M3 supplies the
concrete `TranscriptProvider` type that conforms, plus internal methods on
`TranscriptHandle` (see §8) that only `TranscriptProvider` calls.

## 2. Shared types (LingoPodKit)

```swift
// M3
/// One cue from a parsed feed transcript (SRT/VTT/Podcasting-2.0 JSON).
/// No word-level timing — feed transcripts are cue/paragraph granularity.
public struct RawTranscriptCue: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String        // whitespace-collapsed, markup-stripped
    public var speaker: String?    // from <v Speaker> or JSON "speaker"; nil if absent
}

// M3
/// One attributed run from a finalized SpeechTranscriber result — treat as
/// "approximately one word or token." `text` is the exact substring sliced
/// from the transcriber's AttributedString for that run's range: it already
/// carries whatever spacing/punctuation the framework naturally produces.
/// Concatenating a sequence of RawTranscriptWord.text values with NO
/// separator reproduces the original text exactly. Never trim or re-space it.
public struct RawTranscriptWord: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
}

// M3
/// Canonical output of SegmentNormalizer; maps 1:1 onto TranscriptSegment
/// fields (architecture §4) but is a plain value type so it's Sendable and
/// testable without SwiftData.
public struct NormalizedSegment: Sendable, Equatable {
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var wordTimings: [WordTiming]   // empty for feed-sourced segments
}

// M3
public enum TranscriptParseError: Error, Sendable, Equatable {
    case emptyInput
    case malformedTimestamp(line: String)
    case malformedCueBlock(context: String)
    case malformedJSON(detail: String)
    case unrecognizedFormat
}
```

```swift
// M3
/// Stable, non-localized failure codes. TranscriptState.failed(reason:)
/// stores `code.rawValue` (optionally with a ":detail" suffix for
/// diagnostics — see §9). M4 owns mapping codes to localized, user-facing
/// copy and an action button; M3 never produces localized prose here.
///
/// **Judgment call**: architecture types `TranscriptState.failed(reason:
/// String)` without specifying whether `reason` is a display string or a
/// machine key. This spec uses a stable machine key so M4 can localize and
/// so failure states are testable by equality. Flagged upstream — see the
/// summary returned with this spec.
public enum TranscriptFailureCode: String, Sendable, Equatable {
    case noLanguageSpecified       // podcast has no languageCode/languageOverride, or it's unparseable
    case unsupportedLocale         // resolved locale not in SpeechTranscriber.supportedLocales
    case assetDownloadFailed       // AssetInventory install request threw
    case assetDownloadNoNetwork    // install request failed specifically due to connectivity
    case audioFileUnreadable       // AVAudioFile init threw, or localAudioPath missing on disk
    case analyzerError             // SpeechAnalyzer/SpeechTranscriber threw mid-stream
    case needsDownload             // on-device path chosen but episode never finished downloading (watcher timeout / download failed)
    case feedFetchFailed           // URLSession error/non-2xx fetching feedTranscriptURL
    case feedUnsupportedFormat     // MIME/extension/content sniff didn't match a known parser
    case feedParseError            // parser threw on the fetched bytes
}
```

## 3. Parsers

All three parsers are pure functions on an enum namespace (no instances,
nothing to construct), throw `TranscriptParseError` on malformed input, and
never force-unwrap. Assume UTF-8 input: callers decode fetched `Data` with
`String(decoding: data, as: UTF8.self)` (never crashes; invalid byte
sequences become U+FFFD) before calling the SRT/VTT parsers. This is a known
v1 limitation — some very old SRT files use Latin-1; out of scope.

### 3.1 SRTParser

```swift
public enum SRTParser {
    public static func parse(_ contents: String) throws -> [RawTranscriptCue]
}
```

Input shape (SubRip):

```
1
00:00:01,000 --> 00:00:04,000
Hello world.

2
00:00:04,500 --> 00:00:08,000
This is a test,
across two lines.
```

Parsing rules:

- Strip a leading UTF-8 BOM (`\u{FEFF}`) if present.
- Normalize line endings: replace `\r\n` and bare `\r` with `\n` before
  splitting (CRLF is a required test fixture — see §10).
- Split into blocks on one-or-more blank lines.
- Each block: first non-blank line is a sequence number — **parse it
  tolerantly**: if it doesn't parse as an integer, don't fail the block, just
  ignore that it's missing and try to interpret the same line as the
  timestamp line instead (some malformed SRTs omit the index). The sequence
  number itself is never used for anything (index is reassigned by the
  normalizer later) — don't rely on it for ordering.
- Timestamp line: `HH:MM:SS,mmm --> HH:MM:SS,mmm`, optionally followed by
  cue settings SRT sometimes borrows from VTT (e.g. `X1:... X2:...`) — split
  on whitespace and only parse the first two tokens as timestamps and the
  arrow; ignore trailing tokens. Accept `.` as well as `,` for the decimal
  separator (some generators emit VTT-style timestamps inside `.srt` files —
  be lenient). If the timestamp line can't be parsed, throw
  `.malformedTimestamp(line:)` naming the offending line — do not silently
  skip the whole file; skip just that one block (log and continue) so one bad
  cue doesn't blank the entire transcript. **Concretely**: `parse(_:)`
  collects per-block parse failures, skips the block, and only throws
  `.emptyInput` if *zero* cues parsed successfully out of a non-empty input.
- All remaining lines in the block until the next blank line are cue text;
  join with `" "`, then collapse runs of whitespace to a single space, then
  trim.
- `speaker` is always `nil` for SRT (the format has no speaker concept).
- Time parsing: `HH:MM:SS,mmm` → `TimeInterval` via
  `h*3600 + m*60 + s + ms/1000.0`. Hours are always present and required in
  SRT (unlike VTT).

### 3.2 VTTParser

```swift
public enum VTTParser {
    public static func parse(_ contents: String) throws -> [RawTranscriptCue]
}
```

Input shape (WebVTT):

```
WEBVTT

NOTE
This block is a comment; skip until the next blank line.

STYLE
::cue { color: yellow; }

intro-1
00:00:01.000 --> 00:00:04.000 align:start position:10%
<v Host>Hello world.</v>

00:04.500 --> 00:08.000
<v Guest>This is a test.</v>
```

Parsing rules:

- BOM + CRLF handling identical to SRTParser.
- First non-blank line must start with `WEBVTT` (may have trailing text on
  the same line, e.g. `WEBVTT - sample`, and optional header metadata lines
  until the first blank line) — if missing, still attempt to parse the rest
  leniently (some generators forget it) rather than hard-failing; only throw
  `.unrecognizedFormat` if nothing that looks like a cue is found anywhere.
- Blocks are separated by blank lines, same as SRT.
- Within a block, skip `NOTE` blocks and `STYLE` blocks and `REGION` blocks
  entirely (identified by the block's first line starting with that keyword,
  case-sensitive per spec) — do not attempt to parse their contents as cues.
- A block that is a cue may have an **optional cue identifier line** before
  the timestamp line (any text not containing `-->`). If the first line of
  the block contains `-->`, treat it directly as the timestamp line (no
  identifier present).
- Timestamp line: `<start> --> <end>` optionally followed by cue settings
  (`align:`, `position:`, `size:`, `line:`, `vertical:`, region id, etc. —
  arbitrary `key:value` tokens). Parse rule: split the line on `-->`, trim
  both sides; the left side is the start timestamp; the right side's **first
  whitespace-delimited token** is the end timestamp, everything after is cue
  settings and is discarded.
- Timestamp format accepts **both**:
  - `HH:MM:SS.mmm` (hours present, any number of digits ≥ 2)
  - `MM:SS.mmm` (hours omitted — legal WebVTT when hours = 0; minutes must
    be exactly 2 digits in this form). Detect by counting `:` separators:
    two colons → hours present; one colon → hours omitted, hours = 0.
  - Decimal separator is always `.` per the WebVTT spec (unlike SRT's `,`),
    but accept `,` too for robustness against hand-edited files.
  - Any other shape → `.malformedTimestamp`, same skip-block-not-file
    behavior as SRTParser.
- Cue **payload** (the text lines after the timestamp line, until the next
  blank line): this is where markup lives.
  - `<v Speaker Name>...</v>` (or self-closing/unclosed `<v Speaker Name>`
    spanning to end of payload): extract `Speaker Name` into
    `RawTranscriptCue.speaker`. If more than one `<v>` span appears in one
    cue (multi-speaker single cue — rare), use the **first** speaker found
    and still concatenate all the text (v1 doesn't split one cue into
    multiple speaker turns; that's an acceptable simplification — the
    normalizer's speaker-change force-break only applies across cues, not
    within one).
  - Strip **all** other tag-shaped markup: `<b>`, `<i>`, `<u>`, `<c.class>`,
    `<ruby>`, `<rt>`, and timestamp tags `<00:00:03.500>` (used for
    karaoke-style intra-cue timing — v1 does not consume these; a future
    version could feed them into word timings, out of scope now). Strip via
    a simple `<[^>]*>` removal after extracting the voice span's speaker
    name, keeping the inner text.
  - Decode common HTML entities in the remaining text: `&amp;` `&lt;` `&gt;`
    `&quot;` `&#39;`/`&apos;` `&nbsp;` (→ regular space).
  - Join multiple payload lines with `" "`, collapse whitespace, trim —
    same as SRT.
- Cue block ordering in the source file is not guaranteed monotonic (some
  generators emit cues out of order for accessibility reasons) — the parser
  does **not** sort; `SegmentNormalizer` is responsible for enforcing
  monotonic, non-overlapping output (§4.6). The parser's job is faithful
  extraction only.

### 3.3 PodcastIndexJSONTranscriptParser

```swift
public enum PodcastIndexJSONTranscriptParser {
    public static func parse(_ data: Data) throws -> [RawTranscriptCue]
}
```

This is the Podcasting 2.0 `podcast:transcript` JSON format (the format
served when `feedTranscriptType == "application/json"`). Precise shape:

```json
{
  "version": "1.0.0",
  "segments": [
    {
      "speaker": "Host",
      "startTime": 0.78,
      "endTime": 4.32,
      "body": "Hello and welcome to the show."
    },
    {
      "startTime": 4.32,
      "endTime": 9.1,
      "body": "Today we're talking about coffee."
    }
  ]
}
```

- Top level: an object with a `segments` array. `version` is present in
  practice but not required by this parser — ignore it, don't validate it.
- Each segment: `startTime` / `endTime` are **numbers, in seconds** (not
  milliseconds, not a timestamp string) — `Double`. `body` is the spoken
  text, `String`, required. `speaker` is `String?`, **optional** — many
  generators omit it entirely for single-speaker podcasts.
- Decode with `JSONDecoder` into a private `Codable` DTO
  (`PodcastIndexTranscriptDocument { segments: [PodcastIndexSegment] }`,
  `PodcastIndexSegment { speaker: String?; startTime: Double; endTime:
  Double; body: String }`), then map to `[RawTranscriptCue]`
  (`start: startTime, end: endTime, text: body.trimmed, speaker: speaker)`.
- Filter out segments whose `body`, after trimming whitespace, is empty —
  don't emit empty cues.
- **Do not assume `segments` is sorted by `startTime`.** Sort ascending by
  `startTime` before returning (stable sort, so ties preserve source order).
- Malformed JSON (fails to decode) → throw `.malformedJSON(detail:)` with
  the underlying `DecodingError`'s description. Missing `segments` key at
  all → same error path (it's just a decode failure).
- Top-level array instead of object (some malformed feeds shortcut straight
  to a bare array of segments) — **tolerate this**: first try decoding the
  documented object shape; on failure, try decoding `[PodcastIndexSegment]`
  directly before giving up and throwing.

### 3.4 Format dispatch

Not a parser itself — `TranscriptFormatSniffer` picks which parser to run,
used by `TranscriptProvider` (§7.2). Pure function, LingoPodKit:

```swift
public enum TranscriptFormat: Sendable, Equatable { case srt, vtt, podcastIndexJSON }

public enum TranscriptFormatSniffer {
    /// mimeType is Episode.feedTranscriptType (may be nil or wrong); url is
    /// Episode.feedTranscriptURL (for extension fallback); data is the
    /// fetched bytes (for content-sniff last resort).
    public static func detect(mimeType: String?, url: URL, data: Data) -> TranscriptFormat?
}
```

Resolution order:

1. **MIME type**, lowercased, ignoring any `;charset=...` suffix:
   - `application/json`, `application/json+podcast`, `text/json` → `.podcastIndexJSON`
   - `text/vtt`, `application/x-subrip+vtt` → `.vtt`
   - `application/x-subrip`, `text/srt`, `application/srt` → `.srt`
2. If MIME didn't match (nil, empty, or unrecognized): **URL path
   extension**, lowercased: `.json` → JSON, `.vtt` → VTT, `.srt` → SRT.
3. If still unresolved: **content sniff** on `data` (decode first ~64 bytes
   as UTF-8, trim leading whitespace/BOM):
   - starts with `WEBVTT` → `.vtt`
   - starts with `{` or `[` → `.podcastIndexJSON`
   - first non-blank line is an integer and the next non-blank line matches
     `\d+:\d+:\d+[,.]\d+\s*-->` → `.srt`
4. Otherwise → `nil` (caller surfaces `TranscriptFailureCode.feedUnsupportedFormat`).

## 4. SegmentNormalizer

Pure, static, LingoPodKit. This is the algorithm architecture §4 delegates to
M3. It has **two entry points** that share one internal core:

```swift
public enum SegmentNormalizer {
    /// One-shot: the whole feed transcript is known up front.
    public static func normalize(cues: [RawTranscriptCue]) -> [NormalizedSegment]

    /// Streaming: on-device transcription arrives in batches. Caller owns
    /// `state` across calls (see §6.8 for who that caller is).
    public static func normalizeIncremental(
        newWords: [RawTranscriptWord],
        state: inout StreamState
    ) -> [NormalizedSegment]   // only newly *closed* segments; open builder stays in `state`

    /// Call once when the word stream ends (audio fully consumed) to flush
    /// whatever's left in the open builder as a final segment.
    public static func finalizeStream(state: inout StreamState) -> [NormalizedSegment]

    public struct StreamState: Sendable {
        public init()
        // opaque; holds the not-yet-closed builder's atoms + next index
    }
}
```

### 4.1 Constants

```swift
private let maxSegmentChars = 90          // hard cap; long-atom split enforces this
private let targetMinSeconds: TimeInterval = 2.0   // soft, informational only in v1
private let targetMaxSeconds: TimeInterval = 8.0   // soft cap on merging
private let silenceGapBreak: TimeInterval = 2.0     // gap ≥ this forces a segment break
```

### 4.2 Shared core: atoms

Internally (not public), both entry points reduce their input to a flat,
ordered array of **atoms**:

```swift
private struct Atom {
    var text: String            // exact text for this atom; see spacing rule below
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?        // nil for word-path atoms
    var words: [RawTranscriptWord]?  // non-nil only for word-path atoms (always exactly 1 element there)
    var joinsWithoutSpace: Bool // true for word-path atoms (framework already embeds spacing); false for cue-path atoms (normalizer inserts " " when merging)
}
```

**Cue-path atoms** (from `normalize(cues:)`): for each `RawTranscriptCue`,
run the sentence-splitter (§4.3) over `cue.text`, producing 1+ atoms that
share the cue's `speaker` and whose `start`/`end` are computed by
**character-proportional interpolation** within `[cue.start, cue.end]` (the
cue only tells us the boundaries of the whole block, not of a sentence
within it): for a fragment spanning UTF-16 offsets `[c0, c1)` out of the
cue's total length `N`,

```
fragmentStart = cue.start + (cue.end - cue.start) * (c0 / N)
fragmentEnd   = cue.start + (cue.end - cue.start) * (c1 / N)
```

`joinsWithoutSpace = false` for these.

**Word-path atoms** (from `normalizeIncremental(newWords:)`): one atom per
`RawTranscriptWord`, `speaker = nil`, `words = [that word]`,
`joinsWithoutSpace = true` (per §2's contract, `RawTranscriptWord.text`
already carries its natural spacing — never insert an extra space between
word-path atoms).

### 4.3 Sentence splitting

Used both to split a cue's text into atoms (cue path) and, conceptually, to
decide sentence-boundary force-breaks in the word path (a word atom whose
`text`, trimmed, ends in a terminal punctuation mark is a sentence boundary
candidate — see §4.4).

Terminal punctuation set: `. ! ? … 。 ！ ？` (Latin + common CJK
full-width forms). Algorithm, scanning a string left to right:

1. Find the next terminal-punctuation character.
2. **Don't** treat it as a boundary if it's a `.` immediately preceded and
   followed by a digit (decimal number heuristic, e.g. `3.14`) — peek one
   char each side.
3. **Don't** treat it as a boundary if it's the middle character of an
   ellipsis written as three separate `.` characters (`...`) — only the
   *last* `.` of a run of `.` characters is a boundary candidate; collapse
   consecutive terminal-punctuation runs into one boundary point.
4. A boundary is confirmed if, after the punctuation (and any immediately
   following closing quote/bracket characters `" ' ” ’ )`), the next
   non-whitespace character starts a new word, or there is no more text
   (end of string).
5. Split *after* the punctuation (and any trailing quote/bracket absorbed in
   step 4), trim each resulting fragment.

This is intentionally simple (no abbreviation dictionary, no locale-specific
tokenizer) — good enough for "sentence-ish" per architecture §4, not a
linguistic sentence boundary detector. If a cue has zero terminal
punctuation, it yields exactly one atom (its whole text) — that's expected
and normal; the long-atom split in §4.5 handles it if it's too long.

### 4.4 Merge / force-break / long-atom-split core

Both entry points feed their atom stream through this same state machine.
Pseudocode (this is the algorithm to implement, not a suggestion — keep it
deterministic and match this shape so unit tests in §10 are meaningful):

```
builder: [Atom] = []
segments: [NormalizedSegment] = []
nextIndex = 0

func candidateText(_ atoms: [Atom]) -> String {
    // join respecting each atom's joinsWithoutSpace flag: for atom i>0,
    // insert " " before it unless atoms[i].joinsWithoutSpace == true
}

func flush() {
    guard !builder.isEmpty else { return }
    segments.append(makeSegment(from: builder, index: nextIndex))
    nextIndex += 1
    builder = []
}

for atom in atomStream {
    if builder.isEmpty {
        builder = [atom]
        continue
    }
    let last = builder.last!
    let gap = atom.start - last.end
    let speakerChanged = last.speaker != nil && atom.speaker != nil && last.speaker != atom.speaker
    let forcedBreak = speakerChanged || gap >= silenceGapBreak

    if forcedBreak {
        flush()
        builder = [atom]
        continue
    }

    let candidate = builder + [atom]
    let candidateLen = candidateText(candidate).utf16.count
    let candidateDuration = atom.end - builder.first!.start

    if candidateLen <= maxSegmentChars && candidateDuration <= targetMaxSeconds {
        builder = candidate   // keep merging
    } else {
        flush()
        builder = [atom]
    }
}
// caller decides when to call flush() for the tail — see §4.5/§4.6 for the
// one-shot vs streaming difference.
```

`makeSegment(from:index:)` builds `NormalizedSegment`:

- `text = candidateText(atoms)`.
- `startTime = atoms.first!.start`, `endTime = atoms.last!.end`.
- `wordTimings`: if any atom has non-nil `words`, walk atoms in order
  tracking a running UTF-16 offset into the just-built `text` (starting at
  0); for each atom's word(s), `rangeInSegmentText = offset..<(offset +
  word.text.utf16.count)`, then `offset += word.text.utf16.count`. This
  works correctly *only* because word-path atoms join without an inserted
  separator (§4.2) — the running offset exactly tracks concatenation. If no
  atom has `words`, `wordTimings = []`.

**Long-atom split**: if a single incoming atom's own `text.utf16.count >
maxSegmentChars` (this can happen with a cue-path atom when a whole
sentence has no internal terminal punctuation and is just long), split it
*before* it ever enters the merge loop:

1. `n = ceil(text.utf16.count / maxSegmentChars)`.
2. Target split points at `text.utf16.count * k / n` for `k = 1..<n`.
3. Snap each target point to the nearest whitespace character (search
   outward from the target index, prefer the earlier whitespace on ties) so
   words are never cut mid-word. If no whitespace exists in the whole
   string (single very long token — pathological), split at the exact
   character index as a last resort.
4. Compute each sub-atom's `start`/`end` by the same character-proportional
   interpolation as §4.2 (using the *sub-atom's* UTF-16 offsets within the
   original atom's full duration).
5. Replace the one long atom with the resulting sequence of smaller atoms in
   the stream (each inherits the original atom's `speaker`/`joinsWithoutSpace`).

A single atom whose *duration* exceeds `targetMaxSeconds` but whose text is
short (e.g., a cue that's mostly silence/music with a few words) is **not**
force-split — there's no meaningful place to cut it, and 8s is a soft
target for merging, not a hard cap on an individual atom. Document this as
accepted looseness; it only affects atypical source material.

### 4.5 `normalize(cues:)` (feed path, one-shot)

1. Collapse each cue's whitespace, run the sentence splitter (§4.3) to
   produce atoms (§4.2), applying the long-atom split (§4.4) to any
   resulting atom that's still over 90 chars.
2. Sort the full atom stream by `start` (cues are not guaranteed sorted —
   §3.2).
3. Run the merge/force-break core (§4.4) over the full stream.
4. After the loop, call `flush()` once more to close the trailing builder
   (there is no "streaming tail" concern here — everything is known
   up-front).
5. Run the monotonicity pass (§4.6).
6. Return `segments`.

### 4.6 `normalizeIncremental` / `finalizeStream` (on-device path, streaming)

`StreamState` privately holds `builder: [Atom]` and `nextIndex: Int`
(initially `[]`/`0`), carried across calls by the caller (TranscriptionEngine
— see §6.8).

`normalizeIncremental(newWords:state:)`:

1. Convert `newWords` to word-path atoms, applying long-atom split (§4.4) —
   rare for a single word but keep the check for safety/uniformity.
2. Run the merge/force-break core (§4.4) starting from `state.builder`
   (i.e., the loop's `builder` variable is seeded from `state.builder`
   before consuming the new atoms) and `nextIndex = state.nextIndex`.
3. **Do not** flush the trailing builder at the end of this call — a
   sentence may continue into the next batch. Save whatever's left as
   `state.builder`, save `nextIndex` back to `state.nextIndex`.
4. Return only the segments that were closed (flushed) during this call.

`finalizeStream(state:)`: force-flush whatever remains in `state.builder`
(if non-empty) as one final segment, clear `state.builder`, return that
segment (0 or 1 element). Call this exactly once, when the audio file's
last buffer has been fed and `transcriber.results` has terminated normally
(§6.6) — not on cancellation (a cancelled run discards its partial builder;
see §7.6's simplicity rationale).

### 4.7 Monotonicity / non-overlap pass

Run as the last step of `normalize(cues:)` (word path's incremental segments
are already naturally monotonic by construction since atoms are consumed in
time order and never revisited — no separate pass needed there, but it's
harmless to be defensive; not required by tests).

```
for i in 1..<segments.count {
    if segments[i].startTime < segments[i-1].endTime {
        segments[i].startTime = segments[i-1].endTime
        if segments[i].startTime >= segments[i].endTime {
            segments[i].endTime = segments[i].startTime + 0.01
        }
    }
}
```

Then (re)assign `index = 0..<segments.count` in final order — this is the
"index assignment" step; never reuse indices from parser input.

### 4.8 Worked examples

**Example A — merging tiny cues (SRT-style, no word timings).**

Input:

```
[0] 0.0–1.0  "Yeah."
[1] 1.0–1.4  "So,"
[2] 1.4–5.0  "today we're going to talk about the history of coffee in Ethiopia."
```

Sentence split: each cue has no *internal* terminal punctuation splits
(cue 0 and 2 each end with exactly one terminal mark at the very end, cue 1
has none) → one atom per cue, unchanged. Merge loop: builder=[A0] (5 chars).
Add A1: gap = 1.0-1.0 = 0, no speaker change, candidate text `"Yeah. So,"`
(9 chars) ≤ 90, duration 1.4s ≤ 8s → merge. Add A2: gap = 1.4-1.4 = 0,
candidate text `"Yeah. So, today we're going to talk about the history of
coffee in Ethiopia."` (79 chars) ≤ 90, duration 5.0s ≤ 8s → merge. End of
stream → flush. **Result: one segment**, `index=0, start=0.0, end=5.0,
text="Yeah. So, today we're going to talk about the history of coffee in
Ethiopia.", wordTimings=[]`. This is the intended "merge tiny cues" outcome.

**Example B — proportional split of a long, punctuation-poor cue.**

Input: one cue, `start=10.0, end=22.0` (12s), text (148 UTF-16 units, one
long sentence, no internal terminal punctuation until the very end).
Sentence split yields exactly one atom of 148 chars spanning 10.0–22.0.
148 > 90 → long-atom split: `n = ceil(148/90) = 2`. Target split point =
`148 * 1/2 = 74`; nearest whitespace found at offset 71. Sub-atom 1 =
chars `[0,71)`, sub-atom 2 = chars `[71,148)`. Proportional time: sub-atom 1
spans fraction `71/148 ≈ 0.4797` of the 12s duration ≈ 5.76s →
`start=10.0, end=15.76`. Sub-atom 2 = `start=15.76, end=22.0`. Both are now
≤90 chars, so the merge loop just emits them as two consecutive segments
(no further merging happens across them, since each sub-atom alone is
already close to the 90-char cap and adding the other would exceed it).

**Example C — word-path with wordTimings and UTF-16 offsets.**

Input words (`RawTranscriptWord`, text already includes natural spacing per
§2):

```
("Coffee",0.00,0.42) (" originated",0.42,1.10) (" in",1.10,1.25)
(" Ethiopia.",1.25,2.00) (" It's",2.00,2.30) (" now",2.30,2.55)
(" grown",2.55,2.90) (" worldwide.",2.90,3.60)
```

Sentence split treats "Ethiopia." (word text ends with `.` after trim) as a
boundary → force-break after that word (this is a *sentence-boundary*
signal feeding the same merge loop as any other atom-level decision — in
implementation this is simplest to express as: after appending a word atom
whose trimmed text ends in terminal punctuation, immediately flush rather
than waiting for the char/duration cap). Segment 1: atoms
`["Coffee"," originated"," in"," Ethiopia."]`, joined *without* inserted
spaces (word-path) → `text = "Coffee originated in Ethiopia."` (32 UTF-16
units), `start=0.00, end=2.00`. `wordTimings`, tracking running offset:

| word | rangeInSegmentText | start | end |
|---|---|---|---|
| `"Coffee"` | 0..<6 | 0.00 | 0.42 |
| `" originated"` | 6..<17 | 0.42 | 1.10 |
| `" in"` | 17..<20 | 1.10 | 1.25 |
| `" Ethiopia."` | 20..<30 | 1.25 | 2.00 |

Wait — `"Coffee originated in Ethiopia."` is 32 chars but the table above
only accounts for 30; the implementer should compute offsets by actually
summing `word.text.utf16.count`, not by eyeballing the rendered string —
this table is illustrative of the *method* (running offset, no inserted
separators), not a byte-exact reference. Segment 2 (from the remaining
words, force-broken after "worldwide." by end-of-stream via
`finalizeStream`): `text = "It's now grown worldwide."`, `start=2.00,
end=3.60`, wordTimings built the same way.

## 5. LocaleResolver (LingoPodKit, pure)

```swift
public enum LocaleResolver {
    /// Normalizes a raw feed/user string into a Locale.Language, or nil if
    /// it's empty/unparseable. Handles "en-us" (case), "en_US" (underscore),
    /// "ES" (bare, uppercase), "es-419" (UN numeric macro-region), "pt-BR".
    public static func normalizeBCP47(_ raw: String?) -> Locale.Language?

    /// `supported` is whatever SpeechTranscriber.supportedLocales returned
    /// (app-target glue fetches that list; this function does the matching,
    /// so the matching logic is unit-testable without the Speech framework).
    /// Returns the *actual* supported Locale to use, or nil if none match.
    public static func resolve(requested: Locale.Language, supported: [Locale]) -> Locale?
}
```

`normalizeBCP47`:

1. `nil` or empty-after-trim → `nil`.
2. Replace `_` with `-`.
3. Validate shape with a light regex before trusting `Locale.Language`:
   `^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$` — rejects free-text like "Spanish".
   (`Locale.Language(identifier:)` itself doesn't reliably reject garbage —
   // VERIFY(iOS26)/Foundation: don't rely on its failability, use the regex
   gate instead.)
4. Construct `Locale.Language(identifier: normalized)` and return it if step
   3 passed.

`resolve(requested:supported:)`:

1. Exact match first: a supported locale whose `Locale.Language` is
   equivalent to `requested` (compare `languageCode` and, if `requested` has
   a `region`, `region` too).
2. Else, language-code-only fallback: the first supported locale sharing
   `requested.languageCode` (region ignored). Non-deterministic across
   OS/locale-list versions if multiple regions are supported for one
   language — that's accepted; whichever one is chosen gets written into
   `Transcript.languageCode` as the *actual* locale used (never the raw feed
   string), so it's consistent and inspectable after the fact.
3. No match at all (including `requested.languageCode == nil`, i.e. step 4
   of `normalizeBCP47` never even produced a usable language) → `nil` →
   caller surfaces `TranscriptFailureCode.unsupportedLocale` (or
   `.noLanguageSpecified` if `normalizeBCP47` itself returned `nil` before
   `resolve` was ever called).

`es-419` example: `languageCode="es"`, `region="419"`. Unlikely to
exact-match; falls through to language-code matching against whatever
`es-XX` locales `SpeechTranscriber.supportedLocales` lists.

## 6. TranscriptionEngine (app target, actor)

`LingoPod/Transcription/TranscriptionEngine.swift`. Owns one
`SpeechAnalyzer`/`SpeechTranscriber` pair per invocation — it is not a
long-lived singleton pump; `TranscriptProvider` creates/uses one instance
per transcription attempt (or reuses one actor instance across attempts if
convenient — either is fine as long as state doesn't leak between episodes;
simplest is one fresh instance per attempt).

### 6.1 Public surface

```swift
// M3
actor TranscriptionEngine {
    struct Input: Sendable {
        var episodeID: PersistentIdentifier
        var transcriptID: PersistentIdentifier   // pre-created Transcript row, state == .pending
        var audioFileURL: URL                    // absolute path to downloaded audio
        var requestedLanguage: Locale.Language    // already resolved by LocaleResolver upstream — see §7.3
        var episodeDurationHint: TimeInterval?    // Episode.duration if known; else engine derives from the audio file
    }

    /// Runs one full transcription attempt end-to-end: locale→asset→analyze→
    /// persist. Throws only for conditions the caller (TranscriptProvider)
    /// turns into TranscriptFailureCode; the engine itself doesn't touch
    /// TranscriptState — that's the writer's/provider's job (§6.9).
    /// Cooperatively cancellable: checks Task.isCancelled in every loop
    /// (asset download polling, audio feed loop, results consumption loop)
    /// and exits promptly (no partial-write-then-throw races — see §6.10).
    func run(_ input: Input, writer: TranscriptWriter, progressSink: @Sendable @escaping (Double) -> Void) async throws
}
```

`progressSink` is called by the engine with `0...1` values as finalized time
advances; `TranscriptProvider` wraps it to hop to `MainActor` and update
`TranscriptHandle.progress` (§8).

### 6.2 Locale resolution

Done by the *caller* (`TranscriptProvider`, §7.3) using `LocaleResolver`
before ever constructing `TranscriptionEngine.Input` — the engine receives
an already-resolved `Locale.Language` it trusts. This keeps the
unsupported-locale failure path entirely in pure, testable code and keeps
the engine's job purely "given a locale, transcribe."

### 6.3 Asset installation

```swift
// M3
// VERIFY(iOS26): exact static/instance member names on SpeechTranscriber /
// AssetInventory below are written to the documented shape from the task
// brief; confirm against the iOS 26 SDK's generated Speech.framework
// interface and adjust only inside this function if names differ — do not
// change the call sites elsewhere in TranscriptionEngine.
func ensureAssetsInstalled(for transcriber: SpeechTranscriber, progressSink: @Sendable @escaping (Double) -> Void) async throws {
    // VERIFY(iOS26): confirm the "already installed" check — e.g.
    // AssetInventory.installedLocales.contains(locale) or
    // AssetInventory.status(forModules: [transcriber]) — skip the
    // download entirely if already installed so re-opening an episode
    // that was already transcribed in this language doesn't re-download.
    guard needsInstall else { return }

    let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
    // VERIFY(iOS26): request.progress is a Foundation `Progress`; observe
    // fractionCompleted via KVO or polling (Progress isn't directly
    // Sendable/awaitable) and forward to progressSink. A simple polling
    // loop (check every ~0.2s, `try Task.checkCancellation()` each
    // iteration) is an acceptable, cancellation-safe implementation if KVO
    // bridging is awkward in an actor.
    try await request.downloadAndInstall()   // VERIFY(iOS26): exact method name
}
```

Failure here (network error, storage, entitlement) throws — caller maps to
`.assetDownloadFailed` or, if the underlying error is recognizably a
connectivity error (`URLError.notConnectedToInternet`,
`.networkConnectionLost`, etc. — `// VERIFY(iOS26)`: confirm what error
domain `AssetInventory` surfaces for network failures; it may not be a
plain `URLError` at all, in which case fall back to `.assetDownloadFailed`
generically), `.assetDownloadNoNetwork`.

### 6.4 Building the analyzer

```swift
// M3
// VERIFY(iOS26): transcriptionOptions/reportingOptions/attributeOptions
// enum case names below are written to the documented shape; confirm
// against SDK headers.
let transcriber = SpeechTranscriber(
    locale: resolvedLocale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],   // we need volatile results for progress feel even though we don't persist them (see §6.6)
    attributeOptions: [.audioTimeRange]     // required: this is what lets us read run.audioTimeRange below
)
let analyzer = SpeechAnalyzer(modules: [transcriber])
```

### 6.5 Feeding audio

```swift
// M3
// VERIFY(iOS26): AnalyzerInput's exact initializer and the analyzer's
// start/feed method names. Written to the most-documented public shape:
// an AsyncStream of AnalyzerInput fed to analyzer.start(inputSequence:),
// with results consumed concurrently from transcriber.results.
let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(forReading: input.audioFileURL)
} catch {
    throw TranscriptionEngineError.audioFileUnreadable(underlying: error)
}

// VERIFY(iOS26): confirm the required/best input format — likely
// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`
// or similar; if audioFile.processingFormat doesn't match, convert buffers
// with AVAudioConverter before wrapping them in AnalyzerInput.
let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

let feedTask = Task {
    defer { inputContinuation.finish() }
    let frameCount: AVAudioFrameCount = 4096 * 16   // a few hundred ms per buffer; tune if needed
    while true {
        try Task.checkCancellation()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else { break }
        try audioFile.read(into: buffer, frameCount: frameCount)
        if buffer.frameLength == 0 { break }   // EOF
        inputContinuation.yield(AnalyzerInput(buffer: buffer))   // VERIFY(iOS26): initializer shape
    }
}

async let analyzeRun: Void = analyzer.start(inputSequence: inputSequence)   // VERIFY(iOS26): method name; may throw
```

Cancellation: `feedTask` checks `Task.checkCancellation()` every buffer
(sub-second granularity against a real audio file), which throws and exits
the feed loop, finishing the input stream, which lets `analyzer.start` /
the results loop wind down naturally. `TranscriptionEngine.run` also wraps
its own top-level work in a way that re-throws `CancellationError` promptly
— see §6.10.

### 6.6 Consuming results: volatile vs final

```swift
// M3
// VERIFY(iOS26): transcriber.results element type/shape. Written to the
// documented shape: an AsyncSequence whose elements carry `.text:
// AttributedString` and something that distinguishes a volatile (in-flux,
// may still change) hypothesis from a finalized one — call it `.isFinal`
// below; confirm the actual property/case name (it may instead be a
// `resultType` enum with `.volatile`/`.final` cases) and adjust only here.
for try await result in transcriber.results {
    try Task.checkCancellation()
    guard result.isFinal else {
        // Volatile: fine to surface as a "live caption" hint in a future
        // version, but NEVER persist it (it can be revised/retracted).
        // v1: ignore volatile results entirely for the transcript store.
        continue
    }
    let words = extractWords(from: result.text)   // §6.7
    finalizedWordBuffer.append(contentsOf: words)
    // ... batch/flush logic, §6.8
}
```

`extractWords(from attributedText: AttributedString) -> [RawTranscriptWord]`:

```swift
// M3
// VERIFY(iOS26): the exact attribute key for reading a run's audioTimeRange
// (e.g. `run.audioTimeRange`, or `run[SomeAttributeScope.audioTimeRange]`).
func extractWords(from text: AttributedString) -> [RawTranscriptWord] {
    var result: [RawTranscriptWord] = []
    for run in text.runs {
        guard let timeRange = run.audioTimeRange else { continue }  // skip runs with no timing (shouldn't happen given attributeOptions: [.audioTimeRange], but don't crash if it does)
        let substring = String(text[run.range].characters)
        result.append(RawTranscriptWord(
            text: substring,
            start: TimeInterval(CMTimeGetSeconds(timeRange.start)),
            end: TimeInterval(CMTimeGetSeconds(timeRange.start + timeRange.duration))
        ))
    }
    return result
}
```

`CMTimeGetSeconds` is stable Core Media API, not iOS-26-specific — no
VERIFY needed there. A run's granularity is *approximately* one word per
the task brief, but don't assume exactly one word per run in code — the
loop above works correctly regardless of run granularity since it just
walks whatever runs exist.

### 6.7 CMTime → TimeInterval

Covered above (`TimeInterval(CMTimeGetSeconds(_:))`). Apply uniformly;
never do manual `value/timescale` arithmetic — `CMTimeGetSeconds` already
handles invalid/indefinite times sanely (returns `.nan`/`.infinity` in
degenerate cases — guard against non-finite values before using them: if
`!start.isFinite || !end.isFinite`, drop that word rather than propagating
NaN into segment math).

### 6.8 Batching → normalizer → SwiftData

`TranscriptionEngine` owns a `SegmentNormalizer.StreamState` and two
counters: `wordsSinceFlush: [RawTranscriptWord]` accumulation is actually
already handled by feeding `normalizeIncremental` continuously — the
*flush-to-SwiftData* cadence is a separate, coarser batch on top of the
normalizer's own segment-closing:

```swift
// M3
var streamState = SegmentNormalizer.StreamState()
var pendingSegments: [NormalizedSegment] = []
var audioSecondsSinceLastWrite: TimeInterval = 0
var lastWrittenEndTime: TimeInterval = 0
var wroteFirstBatch = false

func handleFinalizedWords(_ words: [RawTranscriptWord]) async throws {
    guard !words.isEmpty else { return }
    let newlyClosedSegments = SegmentNormalizer.normalizeIncremental(newWords: words, state: &streamState)
    pendingSegments.append(contentsOf: newlyClosedSegments)
    if let lastWord = words.last { audioSecondsSinceLastWrite = lastWord.end - lastWrittenEndTime }

    let shouldFlush = pendingSegments.count >= 20 || audioSecondsSinceLastWrite >= 10.0
    if shouldFlush, !pendingSegments.isEmpty {
        try await flush()
    }
}

func flush() async throws {
    let newState: TranscriptState = wroteFirstBatch ? .partial : .partial   // first successful batch also moves pending -> partial; see §6.9
    let snapshots = try await writer.appendSegments(pendingSegments, transcriptID: input.transcriptID, newState: newState)
    lastWrittenEndTime = pendingSegments.last?.endTime ?? lastWrittenEndTime
    wroteFirstBatch = true
    pendingSegments = []
    audioSecondsSinceLastWrite = 0
    let progress = input.episodeDurationHint.map { min(1.0, max(0.0, lastWrittenEndTime / $0)) } ?? 0
    progressSink(progress)
    // snapshots forwarded up to TranscriptProvider -> TranscriptHandle, see §8
}
```

At end of stream (results loop finished normally, not cancelled): call
`SegmentNormalizer.finalizeStream(state: &streamState)`, append any
resulting segment to `pendingSegments`, and force a final `flush()`
regardless of the 20/10s thresholds, then mark the transcript `.complete`
(that state transition happens in the same final `writer` call — see
§6.9). If `pendingSegments` and the finalized tail are both empty (e.g. a
completely silent file), still write `.complete` with zero segments — an
empty-but-complete transcript is valid and should show an appropriate empty
state in M4, not an error.

`TranscriptWriter` (`@ModelActor`):

```swift
// M3
@ModelActor
actor TranscriptWriter {
    /// Inserts TranscriptSegment rows for `segments`, updates
    /// Transcript.state to `newState`, saves, and returns Sendable
    /// snapshots of exactly the rows just inserted (in the same order) so
    /// the caller can push them to TranscriptHandle without a second fetch.
    func appendSegments(_ segments: [NormalizedSegment], transcriptID: PersistentIdentifier, newState: TranscriptState) throws -> [TranscriptSegmentSnapshot]

    /// Used by the feed path (§7.2) for its single one-shot write, and by
    /// invalidateAndRetranscribe (§7.4) to reset a transcript before a
    /// fresh on-device run.
    func replaceAllSegments(_ segments: [NormalizedSegment], transcriptID: PersistentIdentifier, newState: TranscriptState) throws -> [TranscriptSegmentSnapshot]

    func setState(_ state: TranscriptState, transcriptID: PersistentIdentifier) throws
    func deleteTranscript(episodeID: PersistentIdentifier) throws
    func createPendingTranscript(episodeID: PersistentIdentifier, source: TranscriptSource, languageCode: String) throws -> PersistentIdentifier
}
```

`index` values passed through `NormalizedSegment` from `SegmentNormalizer`
are already correct *within one normalizer run*, but `appendSegments` is
called multiple times per on-device transcription (once per batch) — the
writer must **not** blindly reuse `NormalizedSegment.index` as
`TranscriptSegment.index` on batches after the first, since
`SegmentNormalizer.StreamState`'s `nextIndex` is already monotonic across
the whole streaming session (§4.6 seeds `nextIndex` from `state.nextIndex`
and only increments), so in practice the indices *are* already globally
correct — just don't re-derive or re-sort them in the writer; trust the
values as given.

### 6.9 State machine

```
Transcript created (by TranscriptProvider, before engine.run is called): state = .pending, segments = []
  │
  ├─ first successful writer.appendSegments/replaceAllSegments call → state = .partial
  │
  ├─ engine.run completes normally (audio fully consumed, final flush done) → state = .complete
  │
  └─ engine.run throws (any TranscriptionEngineError) → TranscriptProvider catches it,
       maps to a TranscriptFailureCode, calls writer.setState(.failed(reason: code.rawValue), ...)
```

Cancellation (episode switch) is explicitly **not** routed through
`.failed` — see §7.6: a cancelled run's partial rows are simply discarded
wholesale on the next attempt, the `Transcript` row is deleted rather than
marked failed, so there's no misleading "failed" state left behind for an
episode the user just navigated away from.

### 6.10 Cancellation

`TranscriptProvider` runs `engine.run(...)` inside a `Task` it retains
(§7.5). Cancelling that `Task` propagates `Task.isCancelled`/
`CancellationError` into:

- the audio-feed loop (`try Task.checkCancellation()` every buffer, §6.5),
- the results-consumption loop (`try Task.checkCancellation()` every
  result, §6.6),
- the asset-install progress-poll loop if mid-download (§6.3).

`engine.run` should let `CancellationError` propagate out unmodified (don't
catch-and-wrap it into a `TranscriptionEngineError`) so
`TranscriptProvider` can distinguish "user switched episodes" (expected,
silent) from "real failure" (maps to `.failed(reason:)`) by checking
`error is CancellationError`.

## 7. TranscriptProvider

`LingoPod/Transcription/TranscriptProvider.swift`. Conforms to
`TranscriptProviderProtocol` (architecture §5.2, declared in
`LingoPod/App/Interfaces.swift`). Implemented as an `actor` (protocol
requires `Sendable`; an actor satisfies that and gives us the single-flight
state machine for free).

```swift
// M3
actor TranscriptProvider: TranscriptProviderProtocol {
    private var activeEpisodeID: PersistentIdentifier?
    private var activeTask: Task<Void, Never>?
    private var activeHandle: TranscriptHandle?   // retained only while a job for it is in-flight; see §8

    func transcript(for episodeID: PersistentIdentifier) async throws -> TranscriptHandle
    func invalidateAndRetranscribe(episodeID: PersistentIdentifier) async throws -> TranscriptHandle
}
```

### 7.1 `transcript(for:)` decision tree

1. If `episodeID == activeEpisodeID` and `activeHandle != nil` → return the
   **same** handle instance (there's already a live job for this episode;
   don't start a second one, don't fetch fresh data).
2. Else, cancel any other active job (§7.5), then fetch `Episode` +
   `Transcript?` for `episodeID` via a read-only `ModelActor` query.
3. `Transcript` exists and `state == .complete` → build a fresh
   `TranscriptHandle` directly from persisted data (map `TranscriptSegment`
   rows to `TranscriptSegmentSnapshot`, `progress = 1.0`), return it. No
   engine work, no active-job bookkeeping needed (nothing will mutate it).
4. `Transcript` exists and `state == .failed(reason:)` → build a handle
   reflecting that failed state (`segments = []` or whatever was persisted,
   `progress` = whatever's stored/derivable) and return it *without*
   retrying automatically (§7.6 rationale: don't hammer network/CPU every
   time the overlay opens; retry only via `invalidateAndRetranscribe`,
   which is the explicit "Retry" button's action in M4).
5. `Transcript` exists and `state` is `.pending` or `.partial` → this is a
   **stale** on-device job (the only way a live one exists is case 1, which
   already returned) — per §7.6, delete it and fall through to step 6 as if
   no transcript existed.
6. No usable existing transcript. If `Episode.feedTranscriptURL != nil` →
   feed path (§7.2). Else → on-device path (§7.3).
7. Whatever path is chosen creates the new active job: sets
   `activeEpisodeID`, `activeTask`, `activeHandle`, and returns
   `activeHandle`.

### 7.2 Feed path

Runs inside `activeTask`, but note: unlike the on-device path this is
normally fast (fetch + parse a text file, not minutes of audio) — there is
no meaningful "partial" phase.

1. `writer.createPendingTranscript(episodeID:, source: .feed, languageCode: bestGuessLanguageCode)` where `bestGuessLanguageCode` is `podcast.languageOverride ?? podcast.languageCode ?? "und"` (the `podcast:transcript` tag itself doesn't carry a language attribute in the fields M1's `Episode` model stores — see the note in the summary returned with this spec). Push `state = .pending` to the handle.
2. `URLSession.shared.data(from: episode.feedTranscriptURL!)`. Network/HTTP
   error (including non-2xx status) → `.feedFetchFailed`.
3. `TranscriptFormatSniffer.detect(mimeType: episode.feedTranscriptType, url: episode.feedTranscriptURL!, data: data)`. `nil` → `.feedUnsupportedFormat`.
4. Run the matching parser (§3). Throws → `.feedParseError`. Zero cues
   parsed from non-empty input is itself a throw per §3.1's rule, so it's
   already covered.
5. `SegmentNormalizer.normalize(cues:)` (§4.5).
6. `writer.replaceAllSegments(_, transcriptID:, newState: .complete)` — one
   shot, straight to `.complete`.
7. Push the final snapshot batch + `.complete` state + `progress = 1.0` to
   the handle (§8). Clear `activeTask`/`activeHandle`/`activeEpisodeID` (job
   is done, no more updates coming — `TranscriptProvider` doesn't need to
   keep a reference; the caller who called `transcript(for:)` already owns
   the handle).
8. Any failure at steps 2-4 → `writer.setState(.failed(reason: code.rawValue), transcriptID:)`, push that to the handle, clear active-job bookkeeping.

**Judgment call**: a feed-fetch/parse failure does **not** automatically
fall back to on-device transcription, even if the episode happens to be
downloaded. The failed state's actionable button (M4) is "Transcribe
on-device instead," wired to `invalidateAndRetranscribe`. This keeps
behavior predictable (no silent, surprising background work kicking off
the first time a feed URL 404s) and matches architecture §8's
one-actionable-button pattern.

### 7.3 On-device path

1. Resolve language: `LocaleResolver.normalizeBCP47(podcast.languageOverride ?? podcast.languageCode)`. `nil` → fail immediately with `.noLanguageSpecified` (write `Transcript{source: .onDevice, state: .failed(reason: "noLanguageSpecified")}`, push, done — no engine invocation at all).
2. `writer.createPendingTranscript(episodeID:, source: .onDevice, languageCode: <the normalized BCP-47 string, pre-supportedLocales-matching>)`. Push `.pending` to the handle.
3. Check `Episode.downloadState`:
   - `== .downloaded` → go straight to step 4.
   - anything else (`.none`, `.inProgress`, `.failed`) → **wait-for-download**: spawn (as part of the same `activeTask`) a watcher loop that polls `Episode.downloadState` via the read-only `ModelActor` query every 1s. Keep `Transcript.state == .pending` and `progress == 0` the whole time (M4 cross-references `Episode.downloadState` to show "Download episode to transcribe" — architecture §8 literally names this exact banner). If `downloadState` becomes `.downloaded` within a 30-minute timeout → proceed to step 4. If it becomes `.failed`, or the 30-minute timeout elapses first → `writer.setState(.failed(reason: "needsDownload"), ...)`, push, done. The watcher loop is cancellable exactly like the rest of `activeTask` (episode switch cancels it too, same as any other in-flight job — §7.5).
4. Fetch `SpeechTranscriber.supportedLocales` (`// VERIFY(iOS26)`: static/async property — isolate this one call in a tiny wrapper), call `LocaleResolver.resolve(requested:supported:)`. `nil` → `.unsupportedLocale`.
5. Build `TranscriptionEngine.Input` (resolved locale, audio file URL from `episode.localAudioPath`, `episodeDurationHint: episode.duration`), call `engine.run(...)`.
6. `CancellationError` thrown → not a failure; handled by §7.5/§7.6 (the caller that cancelled the task is responsible for cleanup, not this code path).
7. Any other thrown error → map via a small switch (audio unreadable → `.audioFileUnreadable`; asset install errors → `.assetDownloadFailed`/`.assetDownloadNoNetwork`; anything else from the results loop → `.analyzerError`) → `writer.setState(.failed(reason:), ...)`, push, done.
8. Normal completion → engine itself already drove the writer to `.complete` (§6.8/§6.9) and called `progressSink(1.0)` at the end; `TranscriptProvider` just needs to have been forwarding those writer snapshots + progress values to the handle throughout (§8) and clears active-job bookkeeping now that it's done.

### 7.4 `invalidateAndRetranscribe`

1. Cancel this episode's active job if it is the currently active one
   (same cancellation path as switching episodes, §7.5).
2. `writer.deleteTranscript(episodeID:)` — cascade-deletes segments per the
   `@Relationship(deleteRule: .cascade)` on `Transcript.segments`
   (architecture §4).
3. Run the **on-device path** (§7.3) unconditionally, regardless of what
   `Episode.feedTranscriptURL` says — this is the documented behavior
   ("forces on-device path"). If the episode isn't downloaded, the same
   wait-for-download watcher (§7.3 step 3) applies — this is not a special
   error case, it's just the normal on-device entry point.

### 7.5 Single-flight concurrency

Exactly one `activeTask` app-wide. On any call (`transcript(for:)` for a
*different* episode, or `invalidateAndRetranscribe` for any episode
including the active one) that needs to start new work:

```swift
if let activeTask, activeEpisodeID != newEpisodeID {
    activeTask.cancel()
    await activeTask.value   // wait for cooperative cancellation to actually finish (bounded: sub-second per §6.10)
}
```

Waiting for `activeTask.value` (rather than fire-and-forget cancel) keeps
things simple and correct: the old job's `writer` calls are guaranteed to
have stopped before the new job's `createPendingTranscript`/writes begin,
so there's no race between two jobs touching the same `ModelActor`.

### 7.6 Resume-after-kill / stale-partial policy

Architecture's product-overview risk table and this task's brief both point
at the same simplification: **v1 never resumes a partially-completed
on-device transcription — it always restarts from scratch.** This spec
generalizes that to every case where a stale `.pending`/`.partial`
`Transcript` row is found for an episode that doesn't have a currently
live job (§7.1 step 5), not just the app-kill case, because they're
mechanically indistinguishable at the point `transcript(for:)` runs: an
app-kill and an ordinary episode-switch-then-switch-back both leave behind
a `Transcript` row stuck in `.pending`/`.partial` with no in-memory
`activeTask` to attach to. Treating them identically (discard, restart) is
simpler and avoids the complexity of resuming mid-word-stream from an
arbitrary byte offset in the audio file (which `AVAudioFile` doesn't make
trivial, and which would require persisting a resume cursor and validating
it's still valid).

Rationale this is acceptable: transcription reads the *downloaded* file
faster than real-time (architecture §6.1), so redoing it from the start
costs seconds-to-low-minutes even for a 30-minute episode, not a
repeat of the original wait.

## 8. TranscriptHandle mechanics

`TranscriptHandle` (declared in `LingoPod/App/Interfaces.swift` per
architecture §5.2) needs internal, `TranscriptProvider`-only mutators.
Since the public `private(set)` properties are exactly `state`, `segments`,
`progress`, add `internal` (not `public`) methods in the same file/module
that only `TranscriptProvider` calls:

```swift
// M3 (lives alongside the protocol in Interfaces.swift, or a same-module extension)
@MainActor @Observable
final class TranscriptHandle {
    private(set) var state: TranscriptState
    private(set) var segments: [TranscriptSegmentSnapshot]
    private(set) var progress: Double

    init(state: TranscriptState, segments: [TranscriptSegmentSnapshot], progress: Double) {
        self.state = state; self.segments = segments; self.progress = progress
    }

    func _replaceSegments(_ new: [TranscriptSegmentSnapshot]) { segments = new }
    func _appendSegments(_ additional: [TranscriptSegmentSnapshot]) { segments.append(contentsOf: additional) }
    func _setState(_ s: TranscriptState) { state = s }
    func _setProgress(_ p: Double) { progress = p }
}

// M3
public struct TranscriptSegmentSnapshot: Sendable, Equatable, Identifiable {
    public var id: PersistentIdentifier
    public var index: Int
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var wordTimings: [WordTiming]
}
```

Bridging actor → main actor: `TranscriptWriter` (a `ModelActor`, itself
actor-isolated but not `MainActor`) builds `TranscriptSegmentSnapshot`
values *inside* its own isolation (safe: it's reading its own freshly-
inserted `@Model` objects there) and returns them as a `Sendable` array.
`TranscriptionEngine`/`TranscriptProvider` (also non-`MainActor` actors)
then do:

```swift
await handle._appendSegments(newSnapshots)
await handle._setState(.partial)
await handle._setProgress(progress)
```

This is a normal cross-actor `await` call — legal because
`TranscriptSegmentSnapshot`/`TranscriptState`/`Double` are all `Sendable`
and the method bodies are trivial (no further awaits inside them), so
Swift 6 strict concurrency accepts it without extra ceremony. Do these
three calls together, in this order (segments before state before
progress), each batch, so `state == .partial` is never observed by the UI
before the segments that justify it are already present, and `progress`
reflects the segments just appended.

Handle lifetime: `TranscriptProvider` holds `activeHandle` strongly only
while a job for it is in-flight (`.pending`/`.partial`); once a job
reaches `.complete`/`.failed` it clears its own reference (§7.2 step 7,
§7.3 step 8) — the UI (which called `transcript(for:)` and holds the
returned handle in its own view state) keeps it alive as long as it needs
it. If `transcript(for:)` is called again for that episode after
completion, `TranscriptProvider` builds a **new** `TranscriptHandle`
straight from persisted data (§7.1 step 3/4) rather than trying to locate
the old instance — there's nothing further to push to it, so a fresh
snapshot read is simplest and correct.

## 9. Failure taxonomy

| Code | Trigger | Suggested M4 action (not M3's concern to render, listed for context) |
|---|---|---|
| `noLanguageSpecified` | `podcast.languageOverride` and `podcast.languageCode` both nil, or neither passes `LocaleResolver.normalizeBCP47` | "Set podcast language" → M1's per-podcast language override setting |
| `unsupportedLocale` | Resolved locale not in `SpeechTranscriber.supportedLocales`, even after language-code-only fallback | none (nothing actionable) |
| `assetDownloadFailed` | `AssetInventory.assetInstallationRequest(...).downloadAndInstall()` threw for a non-connectivity reason | "Retry" → `invalidateAndRetranscribe` |
| `assetDownloadNoNetwork` | Same call, recognizably a connectivity failure | "Retry" |
| `audioFileUnreadable` | `AVAudioFile(forReading:)` threw, or `localAudioPath` missing on disk despite `downloadState == .downloaded` | "Re-download episode" → M1 |
| `analyzerError` | `SpeechAnalyzer`/`SpeechTranscriber` threw during `analyzeSequence`/results consumption, not a cancellation | "Retry" |
| `needsDownload` | On-device path chosen, episode never reached `.downloaded` within the watcher's 30-min timeout, or `downloadState` became `.failed` while waiting | "Retry download" → M1 |
| `feedFetchFailed` | `URLSession` error or non-2xx on `feedTranscriptURL` | "Transcribe on-device instead" → `invalidateAndRetranscribe` (if downloaded; else combines with needing a download) |
| `feedUnsupportedFormat` | `TranscriptFormatSniffer.detect` returned nil | "Transcribe on-device instead" |
| `feedParseError` | SRT/VTT/JSON parser threw on fetched bytes | "Transcribe on-device instead" |

The persisted `TranscriptState.failed(reason:)` string is exactly
`code.rawValue` (e.g. `"assetDownloadFailed"`) with no interpolated detail
by default, so equality checks in tests/UI are stable. If a diagnostic
detail is useful for `os.Logger` output, log it separately (not embedded in
the persisted reason string) — see architecture §8's logging convention
(`os.Logger`, subsystem `com.lingopod.app`, category `M3`).

## 10. Unit tests & fixtures

Fixtures live under `LingoPodKit/Tests/LingoPodKitTests/Fixtures/Transcripts/`:

| File | Purpose |
|---|---|
| `basic.srt` | Straightforward multi-cue SRT, LF line endings |
| `crlf.srt` | Same content, CRLF line endings — must parse identically |
| `overlapping.srt` | Cue N's end > cue N+1's start — exercises §4.7's monotonicity pass |
| `tiny_cues.srt` | Several sub-second, few-word cues in a row — exercises Example A (§4.8) |
| `long_paragraph.srt` | One cue, >90 chars, sparse punctuation — exercises Example B |
| `malformed.srt` | A block with an unparseable timestamp mixed among valid ones — parser must skip just that block |
| `basic.vtt` | `WEBVTT` header, hours-present timestamps |
| `no_hours.vtt` | `MM:SS.mmm` timestamps (hours omitted) |
| `voice_tags.vtt` | `<v Speaker>` spans, multiple speakers alternating — exercises speaker-change force-break |
| `cue_settings.vtt` | `align:`/`position:` tokens on timestamp lines — must be discarded, not misparsed as a second timestamp |
| `notes_and_regions.vtt` | `NOTE`/`STYLE`/`REGION` blocks interleaved with real cues — must be skipped, not emitted as cues |
| `malformed.vtt` | Bad timestamp mixed among valid cues |
| `basic.json` | Well-formed Podcasting-2.0 JSON, all segments have `speaker` |
| `missing_speaker.json` | Some/all segments omit `speaker` |
| `unsorted.json` | Segments out of `startTime` order — parser must sort |
| `bare_array.json` | Top-level array instead of `{"segments": [...]}` — tolerated fallback |
| `malformed.json` | Invalid JSON / wrong types |

Test list (each a `swift test`-runnable XCTest, no simulator, no network):

- **SRTParserTests**: basic parse produces expected cue count/times/text;
  CRLF fixture parses identically to LF fixture; overlapping cues still
  parse faithfully (monotonicity is the normalizer's job, not the
  parser's — assert the parser does *not* silently reorder/clamp);
  malformed block is skipped, valid blocks around it still parse, no throw;
  all-malformed input throws `.emptyInput`; comma vs dot decimal
  separator both accepted.
- **VTTParserTests**: header variants (`WEBVTT`, `WEBVTT - desc`, missing
  header); hours-present and hours-omitted timestamps both parse to the
  same seconds value when equivalent; cue settings tokens don't break
  timestamp parsing; `<v Speaker>` extracts speaker and strips the tag from
  text; other markup (`<b>`, `<c.x>`, timestamp tags) stripped from text;
  HTML entities decoded; `NOTE`/`STYLE`/`REGION` blocks produce zero cues;
  cue identifier line (optional) doesn't get mistaken for cue text.
- **PodcastIndexJSONTranscriptParserTests**: basic parse; missing `speaker`
  → `nil` not a throw; unsorted input gets sorted on output; empty-`body`
  segments filtered out; bare-array fallback parses; malformed JSON throws
  `.malformedJSON`.
- **SegmentNormalizerTests** (programmatic `[RawTranscriptCue]`/
  `[RawTranscriptWord]` inputs, no parser round-trip needed for most cases):
  - tiny-cue merge (Example A) produces exactly the expected single segment;
  - long-cue proportional split (Example B) produces exactly 2 segments
    with char counts ≤90 and times summing correctly to the original
    cue's span;
  - speaker change forces a break even when under the char/duration caps;
  - a ≥2s silence gap forces a break even when under the char/duration
    caps;
  - overlapping input cues come out monotonic/non-overlapping after
    `normalize(cues:)` (feed the `overlapping.srt`-equivalent raw cues in
    directly);
  - `index` is `0..<count` with no gaps regardless of how many cues were
    skipped/merged/split upstream;
  - word-path streaming: feed `normalizeIncremental` in two separate calls
    where a sentence spans the batch boundary — assert the sentence isn't
    split across two segments just because it crossed a batch boundary, and
    that `finalizeStream` correctly flushes a trailing partial sentence;
  - `wordTimings`' `rangeInSegmentText` values, when sliced out of the
    segment's `text` via UTF-16 offsets, reproduce each original word's
    text exactly (round-trip assertion, catches off-by-one offset bugs
    directly rather than eyeballing numbers).
- **LocaleResolverTests**: `"es"`, `"es-MX"`, `"ES"`, `"en_US"`, `"en-us"`,
  `"es-419"`, `""`, `nil`, `"Spanish"` (free text, must reject) each
  produce the expected `normalizeBCP47` result; `resolve` picks exact
  region match when available, falls back to language-code-only match,
  returns `nil` when no language-code match exists at all.

## 11. Manual verification script

CI can't exercise `Speech`/`AVAudioFile`/real network — this runs on a
physical iOS 26 device with Apple Intelligence support (architecture §9,
product-overview's airplane-mode-is-a-first-class-demo principle).

1. Subscribe to a Spanish-language podcast that does **not** publish a
   `<podcast:transcript>` tag (or set a per-podcast language override to
   `es` on one that does, then use "Transcribe on-device instead" to force
   the on-device path).
2. Download one episode.
3. Play it; open the transcript overlay immediately, before transcription
   finishes. Confirm: state visibly moves `pending → partial`, segments
   appear progressively (not all at once), the progress indicator advances
   roughly monotonically toward 1.0.
4. While transcription is still in progress, switch to a different
   downloaded episode. Confirm the first episode's job stops promptly (spot
   check via `os.Logger` console output for a cancellation log line, and
   that CPU/energy usage drops back down in Xcode's gauges).
5. Switch back to the first episode. Confirm — per §7.6's policy — it
   **restarts from 0%**, not resumes; old partial segments are gone before
   the new ones start appearing.
6. Force-quit the app while a transcription is mid-flight (state persisted
   as `.partial` with some segments). Relaunch, reopen the same episode.
   Confirm no crash reading the half-written `Transcript`, and that it
   restarts from scratch (§7.6), same as step 5.
7. Once an episode's language pack asset and the episode audio are both
   already downloaded, enable Airplane Mode. Re-open the episode (a fresh
   one not yet transcribed, or use "Transcribe on-device instead" on an
   already-downloaded one) and confirm transcription *and* playback both
   work fully offline end to end.
8. Test a podcast that **does** publish a feed transcript: confirm the
   transcript appears near-instantly with `state` visibly skipping straight
   from `pending` to `complete` — no progressive "transcribing…" UI shown
   for a feed-sourced transcript.
9. From a feed-sourced episode, trigger `invalidateAndRetranscribe`.
   Confirm the feed transcript is discarded and an on-device transcription
   run starts in its place; if the episode isn't downloaded, confirm the
   "download episode to transcribe" state appears instead of a crash or a
   silent no-op.
10. Pick a language not present in `SpeechTranscriber.supportedLocales`
    (check the device's actual supported list first) and attempt on-device
    transcription. Confirm a clean `failed(reason: "unsupportedLocale")`
    state — no crash, no infinite spinner.

## 12. Acceptance criteria

- [ ] `SRTParser` handles CRLF, comma/dot decimal separators, and skips
      individually-malformed blocks without failing the whole file.
- [ ] `VTTParser` handles both timestamp forms (hours present/omitted),
      cue settings tokens, `<v Speaker>` extraction + markup stripping,
      `NOTE`/`STYLE`/`REGION` skipping, HTML entity decoding.
- [ ] `PodcastIndexJSONTranscriptParser` parses the documented
      `{"segments":[{"speaker"?,"startTime","endTime","body"}]}` shape,
      tolerates missing `speaker`, sorts by `startTime`, tolerates a
      bare top-level array.
- [ ] All three parsers throw typed `TranscriptParseError`s on malformed
      input; zero force-unwraps; zero crashes on any fixture in §10
      including the `malformed.*` ones.
- [ ] `SegmentNormalizer.normalize(cues:)` output is monotonic,
      non-overlapping, sequentially indexed from 0, every segment ≤90
      UTF-16 chars (barring the documented unsplittable-long-atom edge
      case), `wordTimings == []`.
- [ ] `SegmentNormalizer.normalizeIncremental`/`finalizeStream` correctly
      carries an open sentence across a batch boundary, and produces
      `wordTimings` whose `rangeInSegmentText` values round-trip exactly
      against the segment's `text`.
- [ ] `LocaleResolver` correctly normalizes the BCP-47 edge cases in §10's
      test list and correctly implements exact-then-language-code-fallback
      matching.
- [ ] `TranscriptionEngine.run` resolves locale, installs assets only when
      not already installed and surfaces download progress, reads audio
      from the downloaded file, persists only final (never volatile)
      results, batches writes at ~10s-of-audio/20-segments granularity,
      and drives `Transcript.state` through `pending → partial → complete`
      (or `→ failed` on real errors, distinct from cancellation).
- [ ] `TranscriptProvider.transcript(for:)` implements the exact decision
      tree in §7.1: cached complete transcript returned with no pipeline
      work; feed-vs-on-device dispatch by `feedTranscriptURL` presence;
      stale `.pending`/`.partial` rows always discarded and restarted;
      exactly one transcription job active app-wide, with episode-switch
      cancellation propagating into the engine within about a second.
- [ ] `invalidateAndRetranscribe` deletes the prior transcript (cascading
      to its segments) and always takes the on-device path, honoring the
      same download-wait behavior as the normal on-device entry point.
- [ ] `TranscriptHandle` is only ever mutated on `MainActor`; nothing
      outside M3 touches `@Model` objects directly — only
      `TranscriptSegmentSnapshot` values cross module boundaries.
- [ ] Every predictable failure produces one of the `TranscriptFailureCode`
      values in §9 as `TranscriptState.failed(reason:)`, never an uncaught
      `throw` out of the `TranscriptProviderProtocol` methods.
- [ ] All `LingoPodKit` unit tests in §10 pass via `swift test` with no
      simulator boot and no network access.
- [ ] The manual verification script (§11) has been run at least once on a
      physical iOS 26 device before this module is considered done.
