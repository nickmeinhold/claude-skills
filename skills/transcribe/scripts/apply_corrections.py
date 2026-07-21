#!/usr/bin/env python3
"""Derive the corrected transcript from a PRISTINE base + approved corrections.

apply_corrections is a PURE FUNCTION: it reads an immutable base
(turns_attributed.json in named mode, else raw turns.json in anonymous mode),
applies EVERY approved correction to that clean base, and writes a FRESH
turns_named.json every run. It never mutates its own input. Consequences:

  * Re-applying is idempotent BY CONSTRUCTION — each run starts from the same
    clean base, so a correction can't re-fire on already-corrected text. No
    idempotency guard, no count-budget/skip interaction. (This dissolves the
    whole bug class the old in-place `make_repl`/self-match guard defended.)
  * --reattribute regenerates a clean base (attribute.py rewrites
    turns_attributed.json) and re-derives turns_named.json cleanly.
  * Removing an approved entry actually un-bakes it on the next run — the SoT is
    now symmetric, because the output is rebuilt from scratch, not accumulated.

The corrections file ($TRANSCRIBE_WORK/corrections.json) is the durable home of
every transcript fix, so hand corrections and approved repair-pass proposals
SURVIVE any --reattribute. Convention:

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
in file order.

Reads  $TRANSCRIBE_WORK/turns_attributed.json (named base) or turns.json (anon)
       + $TRANSCRIBE_WORK/corrections.json (absent -> a plain copy of the base)
Writes $TRANSCRIBE_WORK/turns_named.json (FRESH each run — never mutated in place)
"""
import json
import os
import re
import sys
from pathlib import Path

WORK = Path(os.environ["TRANSCRIBE_WORK"])


def apply_literal(pattern, r, text, flags=0, first_only=False):
    """Replace matches of `pattern` with the LITERAL string `r` (no regex
    backreferences — a backslash/\\1 in r is inserted verbatim, never a backref).

    Applied to a PRISTINE base in a single pass, so a replacement can't re-match
    its own output (that only happened under the old in-place re-application; a
    pure derivation never feeds output back as input). `first_only` stops after
    the first match (turn-scoped corrections, matching the single occurrence the
    review card previews); otherwise every match is replaced (unscoped/global).
    The `a < last` guard skips a match that overlaps a prior replacement WITHIN
    this call (two matches of the same pattern that share offsets). Empty r
    (deletion) applies normally. Returns (new_text, n_mutations)."""
    out, last, n = [], 0, 0
    for m in re.finditer(pattern, text, flags=flags):
        a, b = m.start(), m.end()
        if a < last:                      # overlaps a prior replacement — skip
            continue
        out.append(text[last:a])
        out.append(r)
        last = b
        n += 1
        if first_only:
            break
    out.append(text[last:])
    return "".join(out), n


def load_corrections():
    p = WORK / "corrections.json"
    if not p.exists():
        return []
    data = json.loads(p.read_text())
    # tolerant: {"corrections": [...]} or a bare list. The isinstance check must
    # precede .get — a bare list has no .get, so a default-arg guard never fires.
    return (data.get("corrections", []) if isinstance(data, dict)
            else data if isinstance(data, list) else [])


def resolve_base():
    """Return the pristine base Path to derive turns_named.json from.

    Precedence: turns_attributed.json (named mode) -> turns.json (anonymous).
    turns_attributed.json's existence IS the named-mode signal (attribute.py
    writes it iff attribution ran). Returns None to signal a LEGACY workdir
    (written before base-derivation) whose attribution lives only in an existing
    turns_named.json — falling back to raw turns.json would silently drop it, so
    the caller refuses and asks for a --reattribute migration instead."""
    attributed = WORK / "turns_attributed.json"
    if attributed.exists():
        return attributed
    # No attributed base. Fresh anonymous run -> raw turns.json. But guard the
    # legacy case: a pre-refactor turns_named.json that carries real speaker
    # names is the ONLY copy of that attribution.
    named = WORK / "turns_named.json"
    if named.exists():
        try:
            existing = json.loads(named.read_text())
        except json.JSONDecodeError:
            existing = None
        # isinstance guard, not a bare existing[0]: a turns_named.json that is a
        # JSON object (not the expected list) would raise KeyError/TypeError on
        # [0], which the narrow except would NOT catch. Only a non-empty LIST has
        # a meaningful first turn.
        first = existing[0] if isinstance(existing, list) and existing else {}
        if isinstance(first, dict) and "speaker" in first:
            return None  # legacy named workdir -> caller refuses
    return WORK / "turns.json"


def main():
    corrections = load_corrections()
    # fail closed: only entries with an EXPLICIT status=="approved" are applied.
    # A missing status is treated as not-yet-approved (proposed), never as an
    # implicit go — this is a propose-only safety pipeline.
    approved = [c for c in corrections
                if c.get("status") == "approved"
                and c.get("scope", "correction") == "correction"
                and c.get("pattern") and c.get("replacement") is not None]
    # normalize a hand-written string turn ("41") to int — otherwise the turn
    # gate (c["turn"] != i) is always True (str != int) and the fix never applies.
    for c in approved:
        if c.get("turn") is not None and not isinstance(c["turn"], int):
            try:
                c["turn"] = int(c["turn"])
            except (ValueError, TypeError):
                c["turn"] = None
    # Corrections apply IN FILE ORDER, each against the text left by the prior one
    # (a later entry legitimately transforms an earlier one's output). The one
    # case that makes ambiguous is an EXACT DUPLICATE: two identical approved
    # entries both expanding the same span compound (`cat->the cat` twice ->
    # `the the cat`). Drop exact duplicates (same pattern/replacement/flags/scope/
    # turn), preserving first occurrence — fixing the data, not re-adding a
    # scanner self-match guard (which base-derivation deliberately deleted).
    seen, deduped = set(), []
    for c in approved:
        key = (c["pattern"], c["replacement"], c.get("flags") or "",
               c.get("scope", "correction"), c.get("turn"))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(c)
    approved = deduped
    proposed = sum(1 for c in corrections if c.get("status") == "proposed")

    base = resolve_base()
    if base is None:
        print("  turns_attributed.json missing but turns_named.json is already "
              "attributed — this is a legacy workdir. Regenerate a clean base "
              "first:\n    run.sh --reattribute <workdir> <speakers.json>",
              flush=True)
        return 1
    if not base.exists():
        print(f"  no base transcript in {WORK} (expected turns_attributed.json "
              "or turns.json)", flush=True)
        return 1

    # Derive FRESH from the pristine base every run — never read turns_named.json
    # (the output) as input. This is what makes re-apply idempotent.
    turns = json.loads(base.read_text())
    target = WORK / "turns_named.json"

    counts = {}
    for i, t in enumerate(turns):
        txt = t.get("text", "")
        for c in approved:
            # turn-scoped corrections (repair.py findings) only apply to the
            # turn their evidence came from; unscoped ones apply globally
            if c.get("turn") is not None and c["turn"] != i:
                continue
            # `c.get("flags") or ""` (NOT default-arg): a hand entry may carry
            # "flags": null, and "i" in None would TypeError outside the guard.
            flags = re.I if "i" in (c.get("flags") or "") else 0
            # turn-scoped corrections replace only the first match in the turn
            # (matching the single occurrence the review card previews); unscoped
            # hand/glossary corrections replace every occurrence.
            try:
                txt, n = apply_literal(c["pattern"], c["replacement"], txt,
                                       flags=flags,
                                       first_only=c.get("turn") is not None)
            except re.error as e:
                # a bad hand-written PATTERN skips itself, doesn't nuke the batch
                print(f"  skip correction with bad pattern {c['pattern']!r}: {e}",
                      flush=True)
                continue
            if n:
                counts[c["pattern"]] = counts.get(c["pattern"], 0) + n
        t["text"] = txt

    # ALWAYS write the derived output — even with 0 approved corrections it is
    # the base copied through, and it is the ONLY file downstream reads as the
    # corrected transcript (attribute.py now writes turns_attributed.json, not
    # this file), so a named run with no corrections still needs it present.
    target.write_text(json.dumps(turns, indent=1, ensure_ascii=False))

    if not approved:
        note = (f" ({proposed} proposed awaiting review)" if proposed else "")
        print(f"  corrections: 0 approved to apply{note} "
              f"-> {target.name} (base: {base.name})", flush=True)
        return
    print(f"  corrections: {sum(counts.values())} replacements "
          f"({len(counts)}/{len(approved)} approved patterns matched"
          + (f"; {proposed} proposed awaiting review" if proposed else "")
          + f") -> {target.name} (base: {base.name})", flush=True)
    unmatched = [c["pattern"] for c in approved if c["pattern"] not in counts]
    if unmatched:
        print(f"  corrections with no match (stale pattern, or turn re-indexed "
              f"by --reattribute?): {unmatched}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
