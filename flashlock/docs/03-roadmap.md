# Flashlock — Roadmap beyond MVP

Tranches ordered by (user value ÷ effort), with dependency notes.

## Tranche 1 — Make the loop trustworthy (first post-MVP milestone)
- **Reliability instrumentation**: os_log in all extensions + an in-app "event
  journal" screen reading the App Group log; this is the debugging lifeline for
  the DeviceActivity flakiness documented in research.
- **Grace + streaks**: show remaining daily time in-app; warn via
  `intervalWillEndWarning`/`eventWillReachThresholdWarning` before lockout.
- **Anti-spam polish**: minimum answer latency (~1.5 s) before options become
  tappable; regenerate distractor sets per encounter (already seeded); escalate
  to typed answer after k consecutive misses.
- **Leech handling**: lapse counter ≥ 8 → suspend card + surface "rewrite this
  card" prompt (FlashlockCore already tracks lapses).

## Tranche 2 — Content acquisition (biggest adoption lever)
- **Anki .apkg import** (SQLite + zip; map notes/cards/scheduling state; FSRS
  memory states import cleanly since Anki also runs FSRS).
- **CSV/JSON import; share-sheet ingestion.**
- **AI card generation** (paste text/photo → cards). First feature that needs
  network; revisit privacy stance and App Review posture then.
- **Starter deck gallery** (bundled, curated).

## Tranche 3 — Scheduling depth
- **Per-user FSRS weight optimization**: the append-only review log is already
  the training set. Options: on-device via fsrs-rs FFI, or export/import.
  Never hand-roll the optimizer.
- **Deck presets**: desired retention per deck; max interval 365 d default.
- **Same-prompt answer-set awareness** in distractor generation (avoid
  many-to-one false negatives).
- **Typed-answer diff UI** (Anki-style character diff on miss).

## Tranche 4 — Blocking depth
- **Category & website blocking** (`shield.applicationCategories`,
  `webDomainTokens`), with the documented system-app holes called out in UI.
- **Multiple profiles**: different app groups/limits (work vs doom-scroll),
  each mapping to its own named `ManagedSettingsStore` (50-store budget).
- **Schedules**: block windows (e.g. 21:00–07:00) in addition to usage limits.
- **Strict mode**: require a gate session even to open Flashlock settings;
  `denyAppRemoval` where appropriate. Balance against "commitment device, not
  jail" positioning.

## Tranche 5 — Surfaces & delight
- **DeviceActivityReport extension**: real usage charts (sandboxed rendering).
- **Widgets/Live Activity**: time remaining, cards due. (Note: compact Live
  Activities escape shielding — don't leak blocked-app content.)
- **Watch companion** for quick reviews.
- **Onboarding polish, haptics, App Store assets.**

## Tranche 6 — Business
- Paywall *features* (multiple profiles, AI generation, optimization) — never
  the Screen Time capability itself (guideline 4.10).
- Family/child mode as a separately-scoped product decision (different auth,
  review posture, and support burden).

## Standing engineering debts to watch
- iOS 26.5 `.openParentalControlsApp` adoption vs ≤26.4 notification fallback —
  drop the fallback only when the deployment floor rises past 26.5.
- Token-rotation bug (FB14111223): re-check each iOS release; keep the re-pick
  flow prominent until fixed.
- Re-verify the undocumented constants each major iOS release: 15-min schedule
  minimum, 20-activity cap, 50 tokens/shield, 6 MB extension ceiling.
