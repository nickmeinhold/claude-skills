#!/usr/bin/env python3
"""Apply per-recording corrections to the attributed turns.

The corrections file ($TRANSCRIBE_WORK/corrections.json) is the durable home of
every transcript fix, so hand corrections and approved repair-pass proposals
SURVIVE any --reattribute (which regenerates turns_named.json from raw turns).
The SoT is asymmetric: it governs FUTURE (re)application — removing an approved
entry stops it re-applying on the next --reattribute, but does NOT un-bake text
already written into the current turns_named.json until that re-derive runs.
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
inserted LITERALLY (regex backreferences like \1 are NOT interpreted), so an
LLM-proposed replacement containing a backslash can't crash or mangle. Applied
in file order; idempotent when a replacement doesn't re-match its own output.

Reads  $TRANSCRIBE_WORK/corrections.json (absent -> no-op)
Edits  $TRANSCRIBE_WORK/turns_named.json (or turns.json if no attribution ran)
"""
import json
import os
import re
import sys
from pathlib import Path

WORK = Path(os.environ["TRANSCRIBE_WORK"])


def make_repl(r):
    """Literal + IDEMPOTENT replacement function for re.subn. Inserts r verbatim
    (no regex backreferences), BUT if r is already present starting at the match
    position, leaves the matched text untouched. This makes re-application a
    no-op: running apply twice on already-corrected text can't re-expand a
    self-matching replacement ("Worry"->"Worrying" then "Worryinging")."""
    def _repl(m):
        s, a = m.string, m.start()
        return m.group(0) if s[a:a + len(r)] == r else r
    return _repl


def load_corrections():
    p = WORK / "corrections.json"
    if not p.exists():
        return []
    data = json.loads(p.read_text())
    # tolerant: {"corrections": [...]} or a bare list. The isinstance check must
    # precede .get — a bare list has no .get, so a default-arg guard never fires.
    return (data.get("corrections", []) if isinstance(data, dict)
            else data if isinstance(data, list) else [])


def main():
    corrections = load_corrections()
    # fail closed: only entries with an EXPLICIT status=="approved" are applied.
    # A missing status is treated as not-yet-approved (proposed), never as an
    # implicit go — this is a propose-only safety pipeline.
    approved = [c for c in corrections
                if c.get("status") == "approved"
                and c.get("scope", "correction") == "correction"
                and c.get("pattern") and c.get("replacement") is not None]
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
    for i, t in enumerate(turns):
        txt = t.get("text", "")
        for c in approved:
            # turn-scoped corrections (repair.py findings) only apply to the
            # turn their evidence came from; unscoped ones apply globally
            if c.get("turn") is not None and c["turn"] != i:
                continue
            flags = re.I if "i" in c.get("flags", "") else 0
            # turn-scoped corrections replace only the FIRST match in the turn,
            # matching the single occurrence the review card previews (find_context
            # uses re.search); unscoped hand corrections (glossary fixes) still
            # replace every occurrence globally (count=0).
            count = 1 if c.get("turn") is not None else 0
            # literal + idempotent replacement (see make_repl): backrefs are never
            # interpreted, and an already-applied replacement is left untouched so
            # repeated apply passes don't re-expand self-matching text.
            try:
                txt, n = re.subn(c["pattern"], make_repl(c["replacement"]),
                                 txt, count=count, flags=flags)
            except re.error as e:
                # a bad hand-written PATTERN skips itself, doesn't nuke the batch
                print(f"  skip correction with bad pattern {c['pattern']!r}: {e}",
                      flush=True)
                continue
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
