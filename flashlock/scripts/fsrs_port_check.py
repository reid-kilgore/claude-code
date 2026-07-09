"""Fuzz-compare a line-for-line Python transliteration of the Swift FSRS port
(FSRS.swift) against the reference py-fsrs Scheduler.

Any divergence in stability/difficulty/state/due indicates a transcription bug
in the Swift port's logic.
"""
import math
import random
from datetime import datetime, timezone, timedelta

from fsrs import Scheduler, Card as RefCard, Rating

P = list(Scheduler().parameters)  # FSRS-6 defaults
DESIRED = 0.9
LEARNING = [60.0, 600.0]
RELEARNING = [600.0]
MAX_IVL = 36500
DECAY = -P[20]
FACTOR = 0.9 ** (1 / DECAY) - 1


class SwiftCard:
    def __init__(self):
        self.phase = "new"
        self.stability = None
        self.difficulty = None
        self.step = 0
        self.due = 0.0          # seconds from epoch0
        self.last_review = None
        self.lapses = 0


def clamp_d(d): return min(max(d, 1.0), 10.0)


def whole_days(start, end):
    return int(math.floor((end - start) / 86400.0))


def retrievability(card, now):
    if card.stability is None or card.last_review is None:
        return 0.0
    elapsed = max(0, whole_days(card.last_review, now))
    return (1 + FACTOR * elapsed / card.stability) ** DECAY


def initial_stability(g): return max(P[g - 1], 0.001)


def initial_difficulty(g, clamp):
    d = P[4] - math.exp(P[5] * (g - 1)) + 1
    return clamp_d(d) if clamp else d


def next_interval_days(s):
    raw = (s / FACTOR) * (DESIRED ** (1 / DECAY) - 1)
    # Swift .rounded(.toNearestOrEven) == Python round()
    return min(max(round(raw), 1), MAX_IVL)


def short_term_stability(s, g):
    inc = math.exp(P[17] * (g - 3 + P[18])) * (s ** -P[19])
    if g in (3, 4):
        inc = max(inc, 1.0)
    return max(s * inc, 0.001)


def next_difficulty(d, g):
    delta = -(P[6] * (g - 3))
    damped = d + (10.0 - d) * delta / 9.0
    target = initial_difficulty(4, clamp=False)
    return clamp_d(P[7] * target + (1 - P[7]) * damped)


def next_forget_stability(d, s, r):
    long_term = P[11] * (d ** -P[12]) * ((s + 1) ** P[13] - 1) * math.exp((1 - r) * P[14])
    short_term = s / math.exp(P[17] * P[18])
    return min(long_term, short_term)


def next_recall_stability(d, s, r, g):
    hard = P[15] if g == 2 else 1
    easy = P[16] if g == 4 else 1
    return s * (1 + math.exp(P[8]) * (11 - d) * (s ** -P[9])
                * (math.exp((1 - r) * P[10]) - 1) * hard * easy)


def next_stability(d, s, r, g):
    if g == 1:
        return max(next_forget_stability(d, s, r), 0.001)
    return max(next_recall_stability(d, s, r, g), 0.001)


def update_memory(card, g, now, days_since):
    if card.stability is None:
        card.stability = initial_stability(g)
        card.difficulty = initial_difficulty(g, clamp=True)
    elif days_since is not None and days_since < 1:
        card.stability = short_term_stability(card.stability, g)
        card.difficulty = next_difficulty(card.difficulty, g)
    else:
        card.stability = next_stability(
            card.difficulty, card.stability, retrievability(card, now), g)
        card.difficulty = next_difficulty(card.difficulty, g)


def step_interval(card, g, steps):
    def graduate():
        card.phase = "review"
        card.step = 0
        return next_interval_days(card.stability) * 86400.0

    if not steps or (card.step >= len(steps) and g != 1):
        return graduate()
    if g == 1:
        card.step = 0
        return steps[0]
    if g == 2:
        if card.step == 0 and len(steps) == 1:
            return steps[0] * 1.5
        if card.step == 0 and len(steps) >= 2:
            return (steps[0] + steps[1]) / 2.0
        return steps[card.step]
    if g == 3:
        if card.step + 1 == len(steps):
            return graduate()
        card.step += 1
        return steps[card.step]
    return graduate()  # easy


def swift_review(card, g, now):
    days_since = whole_days(card.last_review, now) if card.last_review is not None else None
    if card.phase == "new":
        card.phase = "learning"
        card.step = 0

    if card.phase == "learning":
        update_memory(card, g, now, days_since)
        interval = step_interval(card, g, LEARNING)
    elif card.phase == "review":
        if days_since is not None and days_since < 1:
            card.stability = short_term_stability(card.stability, g)
        else:
            card.stability = next_stability(
                card.difficulty, card.stability, retrievability(card, now), g)
        card.difficulty = next_difficulty(card.difficulty, g)
        if g == 1:
            card.lapses += 1
            if not RELEARNING:
                interval = next_interval_days(card.stability) * 86400.0
            else:
                card.phase = "relearning"
                card.step = 0
                interval = RELEARNING[0]
        else:
            interval = next_interval_days(card.stability) * 86400.0
    else:  # relearning
        update_memory(card, g, now, days_since)
        interval = step_interval(card, g, RELEARNING)

    card.due = now + interval
    card.last_review = now
    return card


def run_fuzz(iterations=4000, seed=42):
    rng = random.Random(seed)
    start = datetime(2026, 1, 1, tzinfo=timezone.utc)
    failures = 0
    for i in range(iterations):
        n = rng.randint(1, 15)
        ref_sched = Scheduler(enable_fuzzing=False)
        ref = RefCard(card_id=1, due=start)
        mine = SwiftCard()
        now_ref = start
        now_mine = 0.0
        for k in range(n):
            g = rng.randint(1, 4)
            # Review at due time, or early/late by a random offset (including
            # same-day re-reviews and multi-day delays).
            mode = rng.random()
            # Whole-second gaps: the reference tracks time as datetime
            # (microsecond resolution) while this driver uses a float; whole
            # seconds keep both clocks exactly in lockstep.
            if mode < 0.4:
                gap = 0.0
            elif mode < 0.7:
                gap = float(rng.randint(0, 3600 * 20))   # same-ish day late
            else:
                gap = float(rng.randint(0, 86400 * 30))  # up to a month late
            due_wait_ref = max((ref.due - now_ref).total_seconds(), 0)
            due_wait_mine = max(mine.due - now_mine, 0)
            assert abs(due_wait_ref - due_wait_mine) < 1e-6, (i, k, due_wait_ref, due_wait_mine)
            step = due_wait_ref + gap
            now_ref = now_ref + timedelta(seconds=step)
            now_mine = now_mine + step

            ref, _ = ref_sched.review_card(ref, Rating(g), review_datetime=now_ref)
            mine = swift_review(mine, g, now_mine)

            state_map = {"Learning": "learning", "Review": "review", "Relearning": "relearning"}
            ok = (
                state_map[ref.state.name] == mine.phase
                and abs(ref.stability - mine.stability) < 1e-9 * max(1, abs(ref.stability))
                and abs(ref.difficulty - mine.difficulty) < 1e-9
                and abs((ref.due - start).total_seconds() - mine.due) < 1e-6
            )
            if not ok:
                failures += 1
                print(f"MISMATCH iter={i} step={k} g={g}")
                print(f"  ref : {ref.state.name} step={ref.step} S={ref.stability} D={ref.difficulty} due={(ref.due-start).total_seconds()}")
                print(f"  mine: {mine.phase} step={mine.step} S={mine.stability} D={mine.difficulty} due={mine.due}")
                if failures > 5:
                    return False
    print(f"OK: {iterations} random sequences, no divergence")
    return failures == 0


if __name__ == "__main__":
    import sys
    sys.exit(0 if run_fuzz() else 1)
