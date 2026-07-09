# Flashlock — Technical Architecture

Synthesized from the research briefs in `docs/research/` (read those for citations;
this doc states decisions). Last updated 2026-07-09.

## 1. Targets

| Target | Kind | Extension point | Role |
|---|---|---|---|
| `Flashlock` | iOS app | — | UI, flashcards, gate sessions, applies/removes shields |
| `FlashlockMonitor` | appex | `com.apple.deviceactivity.monitor-extension` | Reacts to schedule/threshold events: applies shields at the daily limit, re-locks when earned time expires |
| `FlashlockShieldUI` | appex | `com.apple.ManagedSettingsUI.shield-configuration-service` | Custom shield appearance ("Answer N cards to unlock") |
| `FlashlockShieldAction` | appex | `com.apple.ManagedSettings.shield-action-service` (**no "UI"** in the identifier — a classic App Store rejection) | Handles shield buttons: routes the user into the app's gate flow |
| `FlashlockCore` | SPM package | — | Platform-independent engine: FSRS-6 scheduler, quiz generation/grading, gate state machine. Fully unit-tested; no UIKit/FamilyControls imports |

All four app/extension targets require the `com.apple.developer.family-controls`
entitlement and membership in the App Group `group.com.flashlock.shared`.

**Minimum deployment target: iOS 17.4** (first OS with
`DeviceActivityEvent.includesPastActivity`, which we need for correct earned-time
thresholds). The extensions MUST declare the same minimum target as the app —
mismatched targets are the most-cited cause of "custom shield never appears".

## 2. The control loop

```
                          ┌─────────────────────────────────────────────┐
                          │                iOS (system)                 │
                          │  DeviceActivity schedules & usage tracking  │
                          └───────┬──────────────────────────┬──────────┘
                 eventDidReachThreshold              intervalDidEnd / DidStart
                     ("daily limit hit")                ("earned time over")
                          ▼                                  ▼
                ┌──────────────────────────────────────────────────┐
                │  FlashlockMonitor (headless, ~6 MB memory cap)   │
                │  reads App Group state → writes shields via      │
                │  ManagedSettingsStore(named: .flashlock)         │
                └──────────────────────────────────────────────────┘
                          ▲                                  │ shields on
             re-lock schedule registered                     ▼
┌──────────────────┐   grant    ┌──────────────┐   tap    ┌─────────────────────┐
│  Flashlock app   │◄───────────│  App Group   │◄─────────│ Shield UI + Action  │
│  gate session:   │  TimeCredit│  (source of  │  intent  │ "Answer cards to    │
│  N correct cards │───────────►│   truth)     │          │  unlock" button     │
└──────────────────┘            └──────────────┘          └─────────────────────┘
```

### 2.1 Daily limit
- User picks apps with `FamilyActivityPicker` → `FamilyActivitySelection` (opaque
  tokens; ≤ 50 app tokens per shield — enforce at selection time), JSON-persisted
  to App Group defaults.
- App registers a repeating daily `DeviceActivitySchedule` (00:00–23:59) with one
  `DeviceActivityEvent` whose `threshold` = the user's daily limit over the
  selected tokens, `includesPastActivity: true`.
- `eventDidReachThreshold` in FlashlockMonitor → set
  `store.shield.applications = selection.applicationTokens`. Also write
  `limitReachedAt` to the App Group.
- `intervalDidStart` (new day) → clear shields, reset day state.

### 2.2 Shield → gate flow
- FlashlockShieldUI renders: title "Time's up", subtitle "Answer {N} cards to earn
  {M} more minutes", primary button "Practice to unlock". Config is read per
  invocation from App Group defaults (fresh datasource instance every time; must
  return fast or iOS silently falls back to the default shield).
- FlashlockShieldAction, on primary button:
  - **iOS 26.5+**: return `.openParentalControlsApp` (official API — opens Flashlock).
  - **iOS ≤ 26.4 fallback**: write `pendingGateRequest = true` to the App Group,
    schedule a local notification ("Tap to practice and unlock") that deep-links
    into the gate, return `.close`.
- App opens (either path) → `GateSession` starts if
  `UnlockLedger.canStartSession` allows it.

### 2.3 Earning time back
- Gate session (FlashlockCore): serve due cards first (`ReviewQueue.gatePool`),
  every question in a recall mode (`forceRecall: true` upgrades self-graded cards
  to multiple choice). Correct answers count toward `requiredCorrect`; wrong
  answers add penalty cards. Answers on cards that were actually due are also fed
  to FSRS (`inGateSession: true` in the log); padding cards are quiz-only.
- On completion → `TimeCredit` (e.g. 15 min) recorded in the `UnlockLedger`
  (App Group). The app then:
  1. Removes the tokens from `shield.applications` (nil-ing the setting).
  2. Registers a **non-repeating** DeviceActivity schedule
     `flashlockRelock` ending at `credit.expiresAt` (clamped to ≥ 15 min — the
     undocumented minimum interval; for grants shorter than 15 min, use a
     usage-threshold event of `minutes` on the unlocked tokens instead).
  3. FlashlockMonitor's `intervalDidEnd(flashlockRelock)` re-applies the shield —
     but only after checking the ledger: if a *newer* credit is still active
     (user earned more time mid-window), skip re-shielding. Guarding
     `intervalDidEnd` against stale/replaced activities is mandatory; re-calling
     `startMonitoring` can fire it as a side effect.

### 2.4 Defense in depth (the API is flaky — design for missed callbacks)
Reliability findings (see `14-research-earnback-architecture.md`): extensions
sometimes never launch, thresholds fire late/batched/spuriously, iOS 18 requires
`stopMonitoring` before re-`startMonitoring`, schedules reportedly get unreliable
when set far out. Therefore:
- **The App Group ledger is the source of truth, never a boolean.** Every state
  is a timestamp/window (`limitReachedAt`, `credit.expiresAt`), so any process
  can recompute "should the shield be up right now?" idempotently.
- `reconcile()` — recompute and re-assert the correct shield state — runs:
  on app foreground (`scenePhase`), on every monitor callback, and after any
  gate completion. Missed re-lock ⇒ fixed at next foreground; missed unlock ⇒
  same.
- Always `stopMonitoring` an activity before re-registering it (iOS 18 bug).
- Keep re-lock schedules short-horizon; chain if a grant somehow exceeds ~45 min.

## 3. Shared state (App Group)

`UserDefaults(suiteName: "group.com.flashlock.shared")`, all values JSON via
`Codable`. Small on purpose: the monitor extension has a ~6 MB jetsam ceiling, so
it must never load decks/cards — only the settings blob and ledger.

| Key | Type | Writers → Readers |
|---|---|---|
| `selection` | `FamilyActivitySelection` | app → app, monitor |
| `limitConfig` | `LimitConfig` (daily minutes, active days) | app → monitor, shieldUI |
| `unlockPolicy` | `UnlockPolicy` | app → shieldUI |
| `ledger` | `UnlockLedger` | app, monitor → all |
| `dayState` | `DayState` (limitReachedAt, usage snapshots) | monitor → app, shieldUI |
| `pendingGateRequest` | `Bool` + timestamp | shieldAction → app |

Card/deck data (decks, cards, review log) lives in JSON files in the App Group
container, loaded only by the main app. (SwiftData/Core Data across processes is
explicitly avoided for MVP: multi-process SQLite + 6 MB extensions is a reported
pain point, and the extensions don't need card data.)

## 4. FlashlockCore (done, tested)

- `FSRS` — FSRS-6 scheduler, line-for-line port of py-fsrs 6.3.1 (21 default
  weights, power forgetting curve with trainable decay, learning/relearning
  steps, same-day short-term memory path, interval fuzzing). **Verified two
  ways:** golden vectors generated from the reference package
  (`Tests/.../Resources/fsrs_golden_vectors.json`, replayed by
  `FSRSGoldenVectorTests`), and a Python transliteration of the Swift logic
  fuzz-compared against the reference over 4,000 random review sequences with
  zero divergence (`scripts/fsrs_port_check.py`).
- `QuizEngine` — multiple-choice generation (same-deck distractors ranked by
  edit-distance similarity with jitter; falls back to typed when the deck is too
  small; never serves self-graded questions under `forceRecall`) and typed
  grading (normalization: casefold, diacritic-strip, punctuation/whitespace
  collapse; Damerau-Levenshtein tolerance scaled to answer length, exact match
  required for short answers). Auto-grade mapping: wrong → Again, fuzzy → Hard,
  exact/choice-correct → Good.
- `GateSession` / `UnlockPolicy` / `TimeCredit` / `UnlockLedger` — the unlock
  state machine with wrong-answer penalties (guessing has negative expected
  value), penalty cap, daily unlock cap, and time-windowed credits.

## 5. Entitlement & distribution reality (plan around this)

- Development on a physical device works immediately (add the Family Controls
  capability in Xcode). **Simulator does not work** for shields/monitoring —
  budget for device-only testing and ≥ 15-minute iteration loops on schedule
  logic.
- **TestFlight and App Store require Apple to grant the distribution entitlement
  per bundle ID — one request for the app and one per extension (4 total)** via
  the capability request form. Turnaround is days-to-weeks and silent. File the
  requests as early as possible; it is the schedule-critical external dependency.
- Guideline 4.10: don't paywall the Screen Time capability itself; monetize
  features. Individual (.individual) authorization is self-revocable in
  Settings → Screen Time — by design; Flashlock is a commitment device, not a
  parental control.

## 6. Known-bug mitigations checklist

| Bug (see research briefs) | Mitigation |
|---|---|
| Token rotation (FB14111223): stored tokens stop matching | Fall back to generic shield copy for unknown tokens; prompt re-selection when `Label(token)` renders blank; treat stored selection as best-effort cache |
| Extension not launched / callbacks dropped | `reconcile()` on every app foreground; ledger timestamps not flags |
| iOS 18: re-`startMonitoring` doesn't re-fire `intervalDidStart` | Always `stopMonitoring([name])` first |
| Threshold fires early/spuriously (iOS 26.x reports) | Monitor sanity-checks `dayState` before shielding (e.g. ignore threshold events < N min after interval start when usage can't plausibly have accrued) |
| Picker OOM crash on large categories | Keep `headerText` guidance short; cap selection at 50 apps; detect dead picker (blank remote view) and offer retry |
| `ShieldConfiguration` stale cache while target app foregrounded | Accept: copy on the shield is generic enough to survive staleness; exact numbers live in the app |
| `.all(except:)` misses some system apps | MVP shields explicit token selections only; category policies post-MVP |
