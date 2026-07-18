#!/usr/bin/env python3
"""Apply per-recording corrections to the attributed turns.

The corrections file ($TRANSCRIBE_WORK/corrections.json) is the durable home of
every transcript fix, so hand corrections and approved repair-pass proposals
SURVIVE any --reattribute (which regenerates turns_named.json from raw turns).
Convention:

{
  "corrections": [
    {"pattern": "picture request", "replacement": "feature request",
     "flags": "i",                       # optional: "i" = case-insensitive
     "scope": "correction",              # "correction" (fix mishearing, default)
                                         # or "edit" (intelligent-verbatim; only
                                         # applied to the EDITED rendering)
     "status": "approved",               # only "approved" entries are applied;
                                         # repair.py emits "proposed"
     "class": "semantic-absurdity",      # optional: detector class / provenance
     "note": "ASR misheard; DreamFinder corroborates 'feature'"}
  ]
}

Patterns are Python regexes matched against each turn's text. Replacements are
applied in file order. Idempotent by construction when replacements don't
re-match their own output (keep them literal).

Reads  $TRANSCRIBE_WORK/corrections.json (absent -> no-op)
Edits  $TRANSCRIBE_WORK/turns_named.json (or turns.json if no attribution ran)
"""
import json
import os
import re
import sys
from pathlib import Path

WORK = Path(os.environ["TRANSCRIBE_WORK"])


def load_corrections():
    p = WORK / "corrections.json"
    if not p.exists():
        return []
    data = json.loads(p.read_text())
    return data.get("corrections", data if isinstance(data, list) else [])


def main():
    corrections = load_corrections()
    approved = [c for c in corrections
                if c.get("status", "approved") == "approved"
                and c.get("scope", "correction") == "correction"]
    proposed = sum(1 for c in corrections if c.get("status") == "proposed")
    if not approved:
        if proposed:
            print(f"  corrections.json: 0 approved to apply "
                  f"({proposed} proposed awaiting review)", flush=True)
        return

    target = WORK / "turns_named.json"
    if not target.exists():
        target = WORK / "turns.json"
    turns = json.loads(target.read_text())

    counts = {}
    for t in turns:
        txt = t.get("text", "")
        for c in approved:
            flags = re.I if "i" in c.get("flags", "") else 0
            txt, n = re.subn(c["pattern"], c["replacement"], txt, flags=flags)
            if n:
                counts[c["pattern"]] = counts.get(c["pattern"], 0) + n
        t["text"] = txt

    target.write_text(json.dumps(turns, indent=1, ensure_ascii=False))
    print(f"  corrections: {sum(counts.values())} replacements "
          f"({len(counts)}/{len(approved)} approved patterns matched"
          + (f"; {proposed} proposed awaiting review" if proposed else "")
          + f") -> {target.name}", flush=True)
    unmatched = [c["pattern"] for c in approved if c["pattern"] not in counts]
    if unmatched:
        print(f"  corrections with no match (already applied, or stale?): "
              f"{unmatched}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
