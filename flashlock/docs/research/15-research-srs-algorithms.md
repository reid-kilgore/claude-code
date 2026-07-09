> Research brief produced by a web-research agent on 2026-07-09 for the Flashlock project.
> Topic: Spaced repetition algorithms (SM-2, FSRS). Claims are cited inline; confidence flags are the agent's own.

All research complete. Here's the technical brief.

---

# Spaced-Repetition Scheduling: Technical Brief (as of July 2026)

## 1. SM-2 (SuperMemo 2, 1987)

Canonical spec: https://super-memory.com/english/ol/sm2.htm (mirror: https://www-beta.supermemo.com/archives1990-2015/english/ol/sm2)

**State per item:** repetition count `n`, ease factor `EF` (init 2.5), interval `I` (days).
**Grade:** quality `q ∈ 0..5` (5=perfect, 3=correct with difficulty, <3=fail).

```
if q >= 3:
    n == 1  -> I = 1
    n == 2  -> I = 6
    n >= 3  -> I = round(I_prev * EF)
    n += 1
else:  # lapse
    n = 1; I = 1        # restart intervals; EF is NOT changed on failure per spec
# EF update (applied after every graded repetition, q>=3 in strict spec readings; most implementations apply always):
EF' = EF + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02))
EF' = max(EF', 1.3)
```
Per-grade EF delta: q=5 → +0.10, q=4 → 0, q=3 → −0.14, q=2 → −0.32, q=1 → −0.54, q=0 → −0.80. Spec also says: at end of session, re-drill all items graded <4 until they score ≥4 (this is the origin of "learning steps").

**Anki's SM-2 variant** (legacy scheduler, still selectable; source: Anki manual deck-options, https://docs.ankiweb.net/deck-options.html): 4 buttons instead of q0–5; learning steps (default `1m 10m`) before graduation; graduating interval 1d, easy interval 4d; starting ease 2.50; ease deltas Again −0.20, Hard −0.15, Good 0, Easy +0.15 (deltas from Anki FAQ — faqs.ankiweb.net blocked my fetch, values from knowledge, high confidence); Hard interval = prev × 1.2; Easy bonus × 1.3; Interval Modifier global multiplier (default 1.0); lapse → relearning steps (default `10m`), New Interval multiplier default 0.00 (interval resets), Minimum Interval 1d; new interval forced ≥ prev+1 day.

**Known weaknesses** (documented in Anki manual FSRS section and Expertium's writeups):
- **No memory model.** EF conflates item difficulty with memory-strength growth; no notion of recall probability, so early/late reviews are mishandled (a review done 3× late that succeeds should grow the interval much more; SM-2 can't express this).
- **"Ease hell":** repeated Again presses drive EF to the 1.3 floor permanently; the card then grows at 1.3× forever with no recovery path (Anki manual explicitly cites this as a reason FSRS doesn't need >1d learning steps).
- Fixed 1d/6d initial intervals for everyone and every card.
- Lapse handling is crude: full interval reset regardless of how overdue/strong the memory was.
- Empirically much worse than FSRS at predicting recall: see the benchmark repo https://github.com/open-spaced-repetition/srs-benchmark (FSRS-6 leads; SM-2 near bottom — I did not re-fetch the current leaderboard numbers; directional claim is high-confidence).

## 2. FSRS — current version: **FSRS-6** (21 parameters)

**Version status (confident):** FSRS-4.5 (17 params, fixed decay −0.5) → FSRS-5 (19 params, added same-day/short-term terms w17–w18; shipped in Anki 24.11) → **FSRS-6** (21 params: adds w19 stability-dependence of same-day reviews and w20 trainable forgetting-curve decay; shipped in Anki 25.06, current in Anki and py-fsrs/ts-fsrs/rs-fsrs as of mid-2026). Minor uncertainty only on the exact Anki point release that made FSRS-6 the default.

Primary sources:
- Algorithm wiki: https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm (the old fsrs4anki wiki redirects here)
- Reference implementation (I extracted all formulas below directly from this source): https://github.com/open-spaced-repetition/py-fsrs — `fsrs/scheduler.py`
- Anki FSRS docs: https://docs.ankiweb.net/deck-options.html#fsrs (403s to bots; readable via the manual source repo https://github.com/ankitects/anki-manual, `src/deck-options.md`)
- Expertium's technical explanation: https://expertium.github.io/Algorithm.html (403'd my fetcher; recommended reading in a browser)

**Model:** per-card memory state = (Difficulty `D ∈ [1,10]`, Stability `S` = days until R drops to 90%). Retrievability `R` is computed, not stored. Grades `G`: 1=Again, 2=Hard, 3=Good, 4=Easy.

**Default parameters (FSRS-6, from py-fsrs `DEFAULT_PARAMETERS`):**
```
w = [0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001,
     1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014,
     1.8729, 0.5425, 0.0912, 0.0658, 0.1542]
```
Constants: `STABILITY_MIN = 0.001`, `D ∈ [1.0, 10.0]`.

**Forgetting curve (power law, trainable decay):**
```
DECAY  = -w[20]                      # default -0.1542
FACTOR = 0.9 ** (1/DECAY) - 1        # ensures R(S, S) = 0.9
R(t, S) = (1 + FACTOR * t / S) ** DECAY     # t = days since last review (integer days, >= 0)
```

**Interval from desired retention `r`:**
```
I(r, S) = (S / FACTOR) * (r ** (1/DECAY) - 1)
interval = clamp(round(I), 1, maximum_interval)   # py-fsrs default maximum_interval = 36500
# note: at r = 0.9, I = S exactly
```

**Initial state (first review, grade G):**
```
S0(G) = max(w[G-1], 0.001)                       # w0..w3 = per-grade initial stability
D0(G) = clamp(w[4] - e**(w[5]*(G-1)) + 1, 1, 10) # D0(1) = w4 + ... highest for Again
```

**Difficulty update (every review, ≥1 day or same-day non-initial):**
```
dD      = -w[6] * (G - 3)                    # Again +2w6, Hard +w6, Good 0, Easy -w6
damped  = D + (10 - D) * dD / 9              # linear damping: harder to get more difficult near 10
D'      = clamp( w[7]*D0_unclamped(4) + (1 - w[7])*damped , 1, 10 )   # mean reversion toward Easy's initial D
```
Note: mean-reversion target uses the *unclamped* `D0(4)`; `w7` default 0.001, so reversion is very weak with default weights.

**Stability after successful review (G ∈ {2,3,4}, elapsed ≥ 1 day):**
```
S' = S * (1 + e**w[8]
            * (11 - D)                       # easier cards grow faster
            * S ** (-w[9])                   # saturation: large S grows slower
            * (e**((1 - R) * w[10]) - 1)     # lower R at review time => bigger boost
            * (w[15] if G == 2 else 1)       # hard penalty, 0.6014 < 1
            * (w[16] if G == 4 else 1))      # easy bonus, 1.8729 > 1
```

**Stability after lapse (G = 1 = Again, elapsed ≥ 1 day):**
```
S_f = w[11] * D**(-w[12]) * ((S + 1)**w[13] - 1) * e**(w[14] * (1 - R))
S'  = min(S_f, S / e**(w[17] * w[18]))    # post-lapse stability can't exceed a fraction of prior S
S'  = max(S', 0.001)
```

**Same-day review (elapsed < 1 day — the FSRS-5/6 "short-term memory" component):**
```
SInc = e**(w[17] * (G - 3 + w[18])) * S**(-w[19])
if G >= 3: SInc = max(SInc, 1.0)          # Good/Easy never reduce S
S' = max(S * SInc, 0.001)
# Difficulty is also updated on same-day reviews (same D' formula).
# R is NOT computed for same-day reviews (no forgetting assumed intra-day).
```
FSRS-6 difference vs FSRS-5: the `S**(-w[19])` term (small S grows faster intra-day) and trainable `w[20]` decay; FSRS-5 used fixed decay −0.5 and no w19/w20.

**Learning / relearning steps interaction (py-fsrs behavior, mirrors Anki):**
- States: `Learning` → `Review` → (`Again`) → `Relearning` → `Review`. Defaults: learning steps `[1m, 10m]`, relearning steps `[10m]`.
- While in steps, the *step timer* determines the next due time, but D/S are updated on every rating (first rating sets S0/D0). Again → back to step 0. Hard on step 0: with 1 step, `step*1.5`; with ≥2 steps, `(step0+step1)/2`. Good on last step, or Easy anytime → graduate to Review with `interval = I(r, S)`.
- On lapse in Review: rate Again → state=Relearning, step 0 (if relearning steps non-empty; if empty, stays Review and gets `I(r, S_f)` directly — effectively next-day since post-lapse S is small).
- Anki's guidance with FSRS: keep steps < 1 day, few of them (evidence that many same-day reps add little), and never press Hard when you actually failed (FSRS treats Hard as success — this skews S badly).

**Fuzz (py-fsrs = Anki's scheme):** none below 2.5 days; otherwise
```
delta = 1.0 + 0.15*max(min(ivl,7)-2.5, 0) + 0.10*max(min(ivl,20)-7, 0) + 0.05*max(ivl-20, 0)
fuzzed = uniform_int(round(ivl-delta), round(ivl+delta)), clamped to [2, maximum_interval]
```
(Piecewise factors verified from source; the exact rounding/min-2 tail of `_get_fuzzed_interval` was truncated in my fetch — low-stakes detail, matches ts-fsrs.) Anki also adds up to 5 min random delay to learning steps to break card ordering.

## 3. Swift FSRS implementations

| Repo | FSRS ver | License | Activity | Notes |
|---|---|---|---|---|
| https://github.com/open-spaced-repetition/swift-fsrs (official org) | **FSRS-6 on `main`** (accepts 19-param w for v5 compat); latest *tagged release* v5.0.0 (Oct 2024) = FSRS-5 | MIT | 90★, pushed 2026-07-06, active (recent Sendable/concurrency work) | Port lineage follows ts-fsrs. **Caveat: for FSRS-6 you may need to pin `main` or a post-v5.0.0 tag — verify before depending.** |
| https://github.com/4rays/swift-fsrs | FSRS-5 | MIT | 34★, pushed 2026-05 | Idiomatic Swift; `Scheduler` protocol with separate short-term and long-term schedulers; nice API, but one major version behind. |
| https://github.com/bootuz/SwiftFSRS | FSRS-6 | unverified (repo page fetch 403'd) | 4★, created 2025-11, updated 2026-06 | Young, tiny community. |
| https://github.com/bitbemol/swift-fsrs | FSRS-6 (mirrors ts-fsrs) | unverified | 0★, Apr 2026 | Unofficial one-person port. |

Also relevant prior art: https://github.com/antigluten/amgi — iOS Anki-compatible client embedding the official Anki Rust backend via C FFI (171★, active 2026) — the maximal-fidelity route if you want Anki's exact scheduler.

**Depend vs hand-roll:** the pure scheduling math is ~100–150 LOC (see the py-fsrs functions above; also https://borretti.me/article/implementing-fsrs-in-100-lines, which 403'd my fetcher but is a known-good FSRS-4.5 walkthrough). Reasonable call: use `open-spaced-repetition/swift-fsrs` if a tagged FSRS-6 release exists when you start; otherwise hand-roll a direct port of py-fsrs's `scheduler.py` (it is small, MIT, and you control the state machine — valuable for your gate use case) and validate against py-fsrs/ts-fsrs test vectors (the org publishes cross-implementation golden tests in each repo's test suite). Do NOT hand-roll the *optimizer* (parameter fitting needs ML tooling); ship default weights and keep review logs so you can optimize later server-side or via fsrs-rs bindings.

## 4. Anki data model essentials

Source: https://docs.ankiweb.net/getting-started.html, /studying.html, /leeches.html (fetched via https://github.com/ankitects/anki-manual `src/`).

- **Note** = a record of fields (e.g. French/English/Page). **Note type** defines the field set + card types. **Card type** = template pair (front/back) over fields; adding one note generates one card per card type (e.g. Basic-and-reversed → 2 cards). Cards are what get scheduled; editing the note updates all its cards. Sibling cards (same note) get "burying": only one sibling shown per day (new/review siblings buried; learning cards never buried).
- **Card states:** New → Learning (in learning steps) → Review (Young <21d interval, Mature ≥21d) → on lapse → Relearning → Review. Orthogonal flags: Suspended (never shown until unsuspended), Buried (hidden until next day).
- **Daily limits:** New cards/day (Anki default 20), Maximum reviews/day (default 200); per-deck with subdeck-limit interaction; missed days don't accumulate. Anki gathers intraday learning → interday learning → reviews → new.
- **Ratings:** Again (fail) / Hard (correct, effortful/slow) / Good (correct) / Easy (effortless). Manual guidance: Again ~5–20%, Good 80–95%; two-button usage (Again/Good) is explicitly endorsed — relevant to your gate, where correctness is machine-judged.
- **Leeches:** each lapse in Review state increments a counter; at threshold (default 8) the note is tagged "leech" and the card suspended (configurable: tag-only). Repeat warnings every threshold/2 lapses. Recommended handling: rewrite/delete/suspend the card.
- **Max interval:** default 100 years (36500d). **Desired retention** default 0.90; Anki warns workload explodes >0.97.

## 5. MVP recommendation

**Use FSRS-6 with default weights.** Rationale:
- SM-2 is not meaningfully simpler anymore: FSRS scheduling is ~6 pure functions (above) + the same learning-steps state machine SM-2 needs anyway. The only thing SM-2 saves you is understanding the formulas.
- Default FSRS weights (fit on ~20k Anki users' data) beat SM-2 for a cold-start user by a wide margin per the srs-benchmark; per-user optimization is an optional later upgrade, not required.
- "Simplified FSRS" that's actually worth it: (a) skip the optimizer, (b) if you don't allow multiple graded reviews of a card per day, you can skip the short-term formula entirely (elapsed<1d branch never fires outside learning steps — but keep it anyway, it's 3 lines), (c) two-button UI (Wrong→Again, Right→Good) is fully compatible — FSRS handles never-Hard/never-Easy users fine, and for machine-graded gating you *should* collapse to 2 grades (auto-assigning Hard/Easy from response latency is unvalidated; flag: my inference, no source).
- Concrete defaults: **desired retention 0.9**; learning steps `[1m, 10m]`, relearning `[10m]`; **min interval 1d; max interval 365d** (tighter than Anki's 36500 — for a gate app you likely want cards to keep circulating; this is a product choice, not algorithmic); fuzz on (prevents cards clumping — matters when a fixed N cards/day feeds a gate); leech threshold 8 → auto-suspend + surface to user.
- Persist an append-only review log `(card_id, rating, review_datetime, review_duration)` from day one — it's what lets you re-run `reschedule_card` under new parameters/versions later (py-fsrs pattern). Store `(state, step, S, D, due, last_review)` on the card; use UTC with a configurable day-rollover hour (Anki default 4am) for "days elapsed".

## 6. Gate use case (answer N correctly to unlock)

Prior art here is thin/fragmented; the mechanics below are part sourced, part engineering synthesis — flagged accordingly.

**Multiple-choice distractor generation (sourced + synthesis):**
- Academic survey: "Distractor Generation in Multiple-Choice Tasks: A Survey" https://arxiv.org/abs/2402.01512; plausibility-ranked generation: https://aclanthology.org/2025.acl-long.1154/ (ACL 2025, arXiv:2501.13125). Core finding: good distractors are incorrect, semantically related to the key, and discriminative.
- Practical deck-local pipeline (synthesis; this is essentially what Quizlet-style "Learn" modes do — same-set answer sampling; I could not locate a published Quizlet spec, treat as folklore):
  1. Candidate pool = answer field of other cards **in the same deck** (guarantees domain plausibility for free).
  2. **Exclude correct-collisions:** drop candidates equal to the key after normalization (case/diacritics/whitespace), and — important for many-to-one decks — drop candidates that are a valid answer to the *same prompt* (check prompt-side similarity or maintain answer-set per prompt).
  3. **Exclude near-duplicates of the key:** normalized Levenshtein similarity > ~0.8 → too confusable to be fair (threshold is a tuning knob, not sourced).
  4. **Prefer moderate similarity:** rank remaining candidates by similarity to the key (same length band ±40%, same script/capitalization pattern; on iOS, `NLEmbedding.wordEmbedding`/`sentenceEmbedding` cosine works offline) and sample from the middle of the ranking — top-ranked are too confusable, bottom-ranked are giveaway-wrong. Fall back to uniform same-deck sampling for small decks; require deck ≥ ~8 cards for 4-option MC, else use typed answers.
  5. Fix the option count at 4, shuffle positions, and regenerate distractors per encounter (memorizing "the answer is always B" is a real failure mode).
- **Anti-spam mechanics for the gate** (synthesis; informed by Duolingo-style hearts/streaks patterns, no formal spec): with 4-option MC, guess probability is 0.25, so "N correct" alone is beatable in expectation at N/0.25 taps. Countermeasures: (a) require N correct with **wrong-answer penalty** (reset streak, or +1 to required count); (b) minimum answer latency ~1.5–2s before options are tappable (defeats mashing); (c) never re-ask the just-failed card immediately with the same option set; (d) escalate to typed-answer after k consecutive wrongs or for the final unlock card; (e) map machine grades to FSRS: wrong→Again, correct→Good (and optionally correct-but-slow→Hard — unvalidated, see §5); (f) cap gate cards to due+new from the real scheduler so the gate *is* the study session, with a fallback pool (already-answered cards re-quizzed, not re-graded) when nothing is due — do not feed extra gate reps into FSRS as graded reviews or you'll corrupt the memory states (same-day formula would apply repeatedly; Anki's own guidance is that many same-day reps contribute little).

**Typed-answer grading (sourced from Anki's implementation, `rslib/src/typeanswer.rs` in https://github.com/ankitects/anki):**
- Anki's pipeline: strip AV tags → collapse linebreaks/`<br>`/`<div>` to spaces → strip HTML → trim → **NFC-normalize** both strings → compare as `[char]`.
- Diff engine is `difflib::SequenceMatcher` (Ratcliff/Obershelp, Python-difflib port) over chars, producing equal/delete/insert/replace opcodes rendered as `typeGood`/`typeBad`/`typeMissed` spans. Exact-match short-circuits.
- `type:nc` variant strips combining marks so `élite` == `elite` (`DiffNonCombining`, uses `is_combining_mark` after decomposition).
- The comparison is **case-sensitive** in the code I inspected (no case folding present; moderate confidence there's no user pref overriding this in current Anki).
- **Crucially: Anki does not auto-grade typed answers** — the diff is display-only and the user still self-rates (manual: "This feature does not change how the cards are answered"). Your gate must auto-grade, which is a departure from Anki. Suggested policy (synthesis): normalize (trim, collapse whitespace, NFC, casefold, optionally strip diacritics per-deck setting, strip trailing punctuation) → exact match = correct; then tolerance: allow Damerau-Levenshtein distance ≤ 1 for answers ≥ 5 chars (typo forgiveness) but distance 0 required for short answers (numbers, kana, single words ≤ 4 chars where 1 edit changes meaning); support multi-valued answers via `;`/`,`-separated alternates like Anki's cloze multi-answer convention. Show the Anki-style character diff on failure — it's proven UX.

**Key uncertainty flags recap:** (1) exact Anki release that defaulted FSRS-6 (25.06 vs adjacent); (2) whether open-spaced-repetition/swift-fsrs has a *tagged* FSRS-6 release yet — check before depending, `main` has it; (3) bootuz/SwiftFSRS and bitbemol licenses unverified; (4) Anki ease-delta values (−0.20/−0.15/+0.15) cited from knowledge of the Anki FAQ, not re-fetched; (5) fuzz-clamp tail of py-fsrs truncated in fetch; (6) all gate/anti-spam thresholds are engineering judgment, not sourced; (7) case-sensitivity of Anki typed-answer compare inferred from source, not docs.

Sources: [py-fsrs scheduler.py](https://github.com/open-spaced-repetition/py-fsrs) · [awesome-fsrs Algorithm wiki](https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm) · [Anki manual source](https://github.com/ankitects/anki-manual) ([deck options](https://docs.ankiweb.net/deck-options.html), [studying](https://docs.ankiweb.net/studying.html), [leeches](https://docs.ankiweb.net/leeches.html), [getting started](https://docs.ankiweb.net/getting-started.html), [type-answer fields](https://docs.ankiweb.net/templates/fields.html)) · [Anki typeanswer.rs](https://github.com/ankitects/anki/blob/main/rslib/src/typeanswer.rs) · [SM-2 spec](https://super-memory.com/english/ol/sm2.htm) · [srs-benchmark](https://github.com/open-spaced-repetition/srs-benchmark) · [Expertium's FSRS explanation](https://expertium.github.io/Algorithm.html) · [Implementing FSRS in 100 lines](https://borretti.me/article/implementing-fsrs-in-100-lines) · [open-spaced-repetition/swift-fsrs](https://github.com/open-spaced-repetition/swift-fsrs) · [4rays/swift-fsrs](https://github.com/4rays/swift-fsrs) · [bootuz/SwiftFSRS](https://github.com/bootuz/SwiftFSRS) · [bitbemol/swift-fsrs](https://github.com/bitbemol/swift-fsrs) · [amgi](https://github.com/antigluten/amgi) · [Distractor generation survey](https://arxiv.org/abs/2402.01512) · [Plausible distractors via student choice prediction](https://aclanthology.org/2025.acl-long.1154/)
