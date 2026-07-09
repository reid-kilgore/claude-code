#!/usr/bin/env python3
"""Convert an Anki .apkg export into a Flashlock deck JSON file.

Usage:
    python3 apkg_to_flashlock.py MyDeck.apkg -o mydeck.flashlock.json
    python3 apkg_to_flashlock.py MyDeck.apkg --mode multipleChoice --name "Spanish B1"

Then import the JSON in Flashlock (Decks -> Import deck...). Re-running the
conversion after editing the deck in Anki and re-importing is the sync path:
Flashlock matches cards by Anki's stable note guid, updates text in place,
adds new notes, never touches scheduling state, and never deletes anything.

Scope (deliberately simple, personal use):
  - front = first note field, back = second (override with --front/--back)
  - HTML is stripped, [sound:...] and <img> references are dropped
  - cloze notes are skipped with a warning
  - media is ignored
  - needs the LEGACY package format: in Anki's export dialog, check
    "Support older Anki versions". The newer zstd-compressed format
    (collection.anki21b) is rejected with a clear error.
"""

import argparse
import html
import json
import re
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path

FIELD_SEP = "\x1f"
CLOZE_MODEL_TYPE = 1
ANSWER_MODES = ("selfGraded", "multipleChoice", "typed")

SOUND_RE = re.compile(r"\[sound:[^]]*\]")
TAG_RE = re.compile(r"<[^>]+>")
BR_RE = re.compile(r"<\s*(br|div|p)\s*/?>", re.IGNORECASE)
WS_RE = re.compile(r"\s+")


def clean_field(raw: str) -> str:
    text = SOUND_RE.sub(" ", raw)
    text = BR_RE.sub(" ", text)
    text = TAG_RE.sub(" ", text)
    text = html.unescape(text)
    return WS_RE.sub(" ", text).strip()


def open_collection(apkg_path: Path, tmpdir: str) -> sqlite3.Connection:
    with zipfile.ZipFile(apkg_path) as zf:
        names = set(zf.namelist())
        for candidate in ("collection.anki21", "collection.anki2"):
            if candidate in names:
                target = Path(tmpdir) / candidate
                target.write_bytes(zf.read(candidate))
                return sqlite3.connect(target)
        if "collection.anki21b" in names:
            sys.exit(
                "error: this .apkg uses the new compressed format. Re-export from "
                'Anki with "Support older Anki versions" checked and try again.'
            )
        sys.exit(f"error: no Anki collection found in {apkg_path} (contents: {sorted(names)[:8]})")


def load_models(conn: sqlite3.Connection) -> dict:
    (models_json,) = conn.execute("SELECT models FROM col").fetchone()
    return {int(mid): m for mid, m in json.loads(models_json).items()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("apkg", type=Path, help="Anki .apkg export (legacy format)")
    parser.add_argument("-o", "--output", type=Path, help="output JSON path (default: <apkg>.flashlock.json)")
    parser.add_argument("--name", help="deck name in Flashlock (default: apkg filename)")
    parser.add_argument("--mode", choices=ANSWER_MODES, default="selfGraded",
                        help="answer mode for every imported card (default: selfGraded)")
    parser.add_argument("--front", type=int, default=0, help="note field index for the front (default 0)")
    parser.add_argument("--back", type=int, default=1, help="note field index for the back (default 1)")
    args = parser.parse_args()

    output = args.output or args.apkg.with_suffix(".flashlock.json")
    name = args.name or args.apkg.stem

    cards, skipped_cloze, skipped_short, seen_guids = [], 0, 0, set()
    with tempfile.TemporaryDirectory() as tmpdir:
        conn = open_collection(args.apkg, tmpdir)
        try:
            models = load_models(conn)
            for guid, mid, flds in conn.execute("SELECT guid, mid, flds FROM notes"):
                if guid in seen_guids:
                    continue
                seen_guids.add(guid)
                model = models.get(mid, {})
                if model.get("type") == CLOZE_MODEL_TYPE:
                    skipped_cloze += 1
                    continue
                fields = flds.split(FIELD_SEP)
                if len(fields) <= max(args.front, args.back):
                    skipped_short += 1
                    continue
                front = clean_field(fields[args.front])
                back = clean_field(fields[args.back])
                if not front or not back:
                    skipped_short += 1
                    continue
                cards.append({
                    "guid": guid,
                    "front": front,
                    "back": back,
                    "alternativeAnswers": [],
                    "answerMode": args.mode,
                })
        finally:
            conn.close()

    if not cards:
        sys.exit("error: no usable notes found (all cloze/empty?)")

    deck = {"format": "flashlock-deck-v1", "name": name, "cards": cards}
    output.write_text(json.dumps(deck, ensure_ascii=False, indent=1))
    print(f"wrote {output}: {len(cards)} cards" +
          (f", skipped {skipped_cloze} cloze" if skipped_cloze else "") +
          (f", skipped {skipped_short} empty/short" if skipped_short else ""))


if __name__ == "__main__":
    main()
