# Flashlock — MVP Scope

**One sentence:** when your chosen apps hit their daily time limit, they lock, and
the only way to buy more time is to correctly answer flashcards you actually have
to recall.

## Product thesis

Blockers (Brick, one sec, Opal) create friction; flashcard apps (Anki) demand
discipline nobody has. Coupling them turns doomscroll cravings into spaced-
repetition reps: the craving *is* the study reminder. The gate must be
**recall-based** — self-graded "flip and rate" cards can be mashed through, so
gated cards always require producing or selecting the right answer.

## Personas / mode

MVP targets **self-control for adults** (`FamilyControls .individual`
authorization, iOS 17.4+, own device, no Family Sharing needed). Parent/child
mode is explicitly out of scope for MVP (different auth flow, different
revocation semantics, more App Review scrutiny).

## User stories (MVP — all must ship)

Setup
1. As a user I grant Screen Time access (Face ID prompt) during onboarding.
2. I pick which apps count against my limit (system app picker; up to 50 apps).
3. I set a daily limit (e.g. 45 min/day) and an unlock deal: **clear a pile of
   N cards → M minutes** (defaults: 5 cards → 15 min), with an optional max
   unlocks/day.

Blocking
4. When my selected apps' combined usage hits the limit, they shield with a
   custom screen: "Time's up — answer 5 cards to earn 15 minutes."
5. Tapping the shield's button lands me in Flashlock's gate flow (directly on
   iOS 26.5+; via a tap-the-notification hop on older iOS).
6. If the system misses a lock/unlock event, opening Flashlock fixes the state
   (idempotent reconcile — no stuck shields, no free time).

Gate
7. A gate session is a **pile of N cards, Anki-style: miss a card and it goes
   to the back of the pile**; the unlock is earned only when the pile is
   cleared. Misses never grow the pile or shrink the reward.
8. The pile mixes card styles freely — self-graded (Again/Good) cards are
   allowed, and cheating through those is accepted — but it always contains at
   least K recall cards ("harder gates"): multiple choice with plausible
   same-deck distractors, or typed answers (normalized, typo-tolerant, short
   answers exact).
9. On clearing the pile the apps unlock for M minutes and automatically
   re-lock after.

Flashcards
10. I get a starter deck; I can create/edit/delete decks and cards (front, back,
    optional alternative answers, answer mode).
11. I can study anytime for free (self-graded cards show just **Again / Good**;
    recall cards auto-grade). Scheduling is FSRS-6
    (desired retention 0.9, learning steps 1m/10m, relearn 10m) — gate reviews
    of due cards advance the same schedule, so gating never corrupts learning.

Trust
12. All data stays on device. No accounts, no network calls in MVP.

## Explicitly OUT of MVP (see 03-roadmap.md)

- In-app .apkg parsing (interim: `scripts/apkg_to_flashlock.py` converts an
  Anki export to JSON, imported in-app with guid-keyed merge/sync), AI card
  generation, shared/downloadable decks
- Typed-answer character diff display; audio/image cards; cloze deletions
- Per-user FSRS weight optimization (we keep the review log so it's possible later)
- Category-based blocking (`.all(except:)`), website/domain blocking
- Schedules (block only 9-5), multiple app groups with different limits
- Strict/hardcore mode (anti-bypass), parent/child mode, Android
- Widgets, Live Activities, usage charts (DeviceActivityReport extension)
- Monetization (and note guideline 4.10: never paywall the Screen Time API itself)

## MVP acceptance test (manual, on device)

1. Fresh install → onboarding → authorize → select 2 sacrificial apps → limit
   2 min (dev builds allow tiny limits) → deal 3 cards / 15 min.
2. Use the apps for 2 minutes → shield appears on both.
3. Tap "Practice to unlock" → arrive in gate with a pile of 3 → miss one card
   (it visibly returns to the pile) → clear the other two → the missed card
   comes around again → answer it right → unlocked, timer visible.
4. Apps open normally; after 15 min they shield again without Flashlock running.
5. Kill Flashlock mid-window, wait past expiry, open a blocked app → shield up.
6. Next calendar day: usage resets, apps open normally.
7. Study 10 cards in free mode; verify due dates spread out over days; relaunch
   → state persisted.

## Key risks (and how the design absorbs them)

| Risk | Mitigation |
|---|---|
| DeviceActivity callbacks missed (well-documented flakiness) | Timestamp-window ledger + idempotent `reconcile()` on every foreground; no state is a bare flag |
| Distribution entitlement approval takes weeks, silently | File all 4 bundle-ID requests the moment bundle IDs exist; dev builds unblocked meanwhile |
| Token rotation bug invalidates stored app selections | Generic shield fallback + re-pick prompt |
| Gate spam (mash through cards) | Missed cards requeue until answered right; a guaranteed minimum of recall cards per pile; optional daily unlock cap; min-latency answer buttons (post-MVP polish). Cheating on self-graded pile cards is tolerated by design |
| User just revokes Screen Time access | Accepted: this is a commitment device, not a jail. Surface a gentle "recommit" flow on reauthorization |
| 15-min DeviceActivity minimum vs shorter grants | Grants < 15 min use usage-threshold events instead of wall-clock schedules |
