"""Generate FSRS golden test vectors from the reference py-fsrs package.

Each scenario replays a rating sequence where every review happens exactly at
the card's due time (so learning steps exercise the same-day/short-term path
and review intervals exercise the long-term path). Fuzzing is disabled.
"""
import json
from datetime import datetime, timezone

from fsrs import Scheduler, Card, Rating

START = datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc)

SCENARIOS = {
    "all_good": [3, 3, 3, 3, 3, 3],
    "with_lapse": [3, 3, 3, 1, 3, 3],
    "easy_path": [4, 3, 4],
    "struggle": [1, 2, 3, 3, 2, 3],
    "hard_only": [2, 2, 2, 2],
    "lapse_then_recover": [3, 3, 1, 1, 3, 3, 3],
}

def run(ratings, desired_retention=0.9):
    scheduler = Scheduler(desired_retention=desired_retention, enable_fuzzing=False)
    card = Card(card_id=1, due=START)
    now = START
    steps = []
    for r in ratings:
        card, _ = scheduler.review_card(card, Rating(r), review_datetime=now)
        steps.append({
            "rating": r,
            "reviewedAtOffsetSec": (now - START).total_seconds(),
            "state": card.state.name.lower(),
            "step": card.step,
            "stability": card.stability,
            "difficulty": card.difficulty,
            "dueOffsetSec": (card.due - START).total_seconds(),
        })
        now = card.due  # next review exactly when due
    return steps

vectors = {
    "generator": "py-fsrs 6.3.1, FSRS-6 default parameters, desired_retention=0.9, "
                 "learning_steps=[1m,10m], relearning_steps=[10m], fuzzing off, "
                 "reviews at exact due times from 2026-01-01T00:00:00Z",
    "scenarios": {name: run(ratings) for name, ratings in SCENARIOS.items()},
    "retention_08": {"all_good": run(SCENARIOS["all_good"], desired_retention=0.8)},
}

print(json.dumps(vectors, indent=1))
