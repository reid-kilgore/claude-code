# LingoPod — Product Overview

## One-liner

A podcast player for iOS built for language learners: every episode gets a big,
Apple Music–lyrics-style transcript overlay that follows the audio, and the
transcript itself is interactive — tap a line to jump to it, tap a word or
phrase to translate it, or highlight a passage to have an on-device LLM explain
it (grammar, idiom, register, cultural context).

## Why

Podcasts are one of the best sources of authentic, current, spoken language —
but they're hard for learners because there's usually no transcript, no way to
"look at" what you just heard, and no fast path from *heard something
confusing* to *understood it*. LingoPod closes that loop entirely on-device:
no accounts, no server costs, works offline once an episode is downloaded.

## Target user

An intermediate language learner (A2–C1) who already consumes podcasts in
their target language, or wants to start. They have a modern iPhone with
Apple Intelligence support. Their device/UI language is their *native*
language; the podcast is in their *target* language.

## Core loop

1. Subscribe to podcasts in the target language (search via iTunes Search API,
   or paste an RSS URL).
2. Play an episode. If the feed ships a transcript
   (`<podcast:transcript>` tag), we use it; **otherwise we transcribe
   on-device** with Apple's `SpeechAnalyzer`/`SpeechTranscriber`, which yields
   per-run timestamps.
3. The Now Playing screen offers a full-screen **transcript overlay** styled
   like Apple Music lyrics: large type, current line highlighted and
   auto-scrolling in sync with playback.
4. Three interactions inside the overlay:
   - **Tap a line/section → seek** playback to that timestamp.
   - **Tap a word (or select a short phrase) → inline translation** into the
     user's native language via Apple's Translation framework.
   - **Highlight (tap-and-drag) a passage → "Explain"**: the on-device
     Foundation Model explains the passage — meaning, grammar constructions,
     idioms, register — in the user's native language.

## Feature set (v1)

| Area | Included in v1 |
|---|---|
| Podcast directory search (iTunes Search API) + add-by-RSS-URL | ✅ |
| Subscriptions, episode list, artwork, feed refresh | ✅ |
| Streaming + download-for-offline playback, background audio, lock-screen controls, playback speed | ✅ |
| Feed-provided transcripts (SRT / VTT / Podcasting-2.0 JSON) | ✅ |
| On-device transcription with timestamps (SpeechAnalyzer), progressively during playback of a downloaded episode | ✅ |
| Lyrics-style synced transcript overlay with tap-to-seek | ✅ |
| Tap-a-word / select-phrase translation (Translation framework) | ✅ |
| Highlight → on-device LLM explanation (Foundation Models framework) | ✅ |
| Transcript + translation caching (SwiftData), fully offline after download | ✅ |
| Per-podcast language override (when feed metadata is wrong) | ✅ |

### Explicitly out of scope for v1

- Accounts, sync, server backend of any kind.
- Cloud transcription/translation fallbacks (device without Apple
  Intelligence gets feed transcripts only; we show a clear empty state).
- Vocabulary/SRS review decks, progress tracking, streaks (v2 candidates).
- iPad/macOS layouts (design for iPhone; don't preclude iPad).
- Chapters, video podcasts, private feeds with auth.

## Product principles

1. **The transcript is the app.** Player chrome is minimal; the overlay is the
   hero surface. Every design decision optimizes time-to-understanding.
2. **On-device only.** Privacy story is absolute; airplane-mode is a first-class
   demo. Degrade gracefully (and say why) when models/assets are unavailable.
3. **Never block playback.** Transcription, translation-model downloads, and
   LLM calls are all async and cancellable; audio keeps playing.
4. **Honest timestamps.** Tap-to-seek must land within ~1s of the spoken line;
   highlight state must track the actual playhead, including after seeks and
   speed changes.

## Key risks

| Risk | Mitigation |
|---|---|
| `SpeechTranscriber` locale/asset unavailable for target language | Check `SpeechTranscriber.supportedLocales`; prompt asset download via `AssetInventory`; fall back to feed transcript or a "transcription unavailable for this language" state. |
| Transcription slower than real-time on older devices | Transcribe downloaded audio file ahead of the playhead (windowed), persist results; UI shows "transcribing…" progress per section. |
| Foundation model unavailable (no Apple Intelligence, region, battery) | Feature-gate the Explain action on `SystemLanguageModel.default.availability`; translation still works (separate framework). |
| Feed transcript timestamps are coarse (paragraph-level SRT) | Normalize all sources into one `TranscriptSegment` model; seek granularity = segment granularity; on-device transcription can replace a coarse feed transcript on user request. |
| LLM explanation quality/hallucination | Prompt scoping (explain only the given passage, given surrounding context), constrained output via `@Generable`, and a "generated by on-device AI" disclosure footer. |

## Success criteria for v1

- Cold start → playing a searched-for episode in < 5 taps.
- A downloaded 30-min episode in a supported language has a complete,
  seekable transcript with no user intervention.
- Word translation appears in < 1s (after one-time language-pack download).
- Explain-a-passage streams first tokens in < 3s on an iPhone 16-class device.
