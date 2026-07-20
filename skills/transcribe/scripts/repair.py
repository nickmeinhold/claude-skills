#!/usr/bin/env python3
"""LLM transcript repair pass — propose-only, human-vetoed.

Runs AFTER attribution and hunts what the glossary pass structurally cannot
see: ordinary-word mishearings and residual proper-noun garbles. Four detector
classes (each contributed by a real catch, 318 Russell St 7.3, 2026-07-18):

1. proper-noun-garble    — unknown names/terms rendered as phonetic English
2. semantic-absurdity    — a word this speaker would never say here, with a
                           phonetically-near context-appropriate alternative
                           ("picture requests" -> "feature requests")
3. polarity-flip         — negation followed by an elaboration that AFFIRMS
                           the negated thing's definition; a confusable
                           non-negated alternative resolves the contradiction
                           ("It's not a prenup, there's an agreement ahead of
                           time" -> "It's like a prenup, ...")
4. grammar-artifact      — subject-verb mismatch flags an ASR boundary
                           artifact; the repair is the PHONETICALLY-nearest
                           token change, not the grammar-checker fix
                           ("borrow checkers certainly has" -> "borrow checker
                           certainly has": dropped-H liaison manufactured the S)

Plus intelligent-verbatim EDIT proposals (scope=edit): false starts and
dangling conjunctions that a readable rendering would drop — these only ever
affect transcript_edited.html, never the canonical verbatim outputs.

Everything is emitted as status=proposed into corrections.json and summarized
in repair_report.md. NOTHING is applied here — review the report, flip entries
to "approved" (or ask your agent to), then apply + rebuild:
    run.sh --apply <workdir> <speakers.json>

Reads  $TRANSCRIBE_WORK/turns_named.json + $TRANSCRIBE_CONFIG
Writes $TRANSCRIBE_WORK/corrections.json (merge; never clobbers approved)
       $TRANSCRIBE_WORK/repair_report.md
"""
import json
import os
import re
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

WORK = Path(os.environ["TRANSCRIBE_WORK"])
CONFIG = json.loads(Path(os.environ["TRANSCRIBE_CONFIG"]).read_text()) \
    if os.environ.get("TRANSCRIBE_CONFIG") else {}
MODEL = "sonnet"
CHUNK = 120
CONTEXT = 4
WORKERS = 6
FAST = ["--disallowedTools", "*", "--mcp-config", '{"mcpServers":{}}',
        "--strict-mcp-config"]

VOCAB = [t["term"] if isinstance(t, dict) else t
         for t in (CONFIG.get("vocabulary") or CONFIG.get("glossary") or [])]
CTX = CONFIG.get("context") or ""

BRIEF = f"""You are a transcript REPAIR reviewer for an ASR transcript of a real
conversation.{' Context: ' + CTX if CTX else ''}
Known domain vocabulary (already mostly corrected upstream): {', '.join(VOCAB) if VOCAB else '(none)'}

Hunt ONLY these defect classes in the numbered turns below. Be CONSERVATIVE:
when you'd have to guess, don't flag. Verbatim speech is messy — disfluency,
restarts and odd grammar are NORMAL and are not defects. The literature on LLM
transcript correction is unambiguous: models do the MOST damage to transcripts
that are already accurate (measured 3-12% hallucinated words, meaning flips,
rare->common word substitutions). An empty findings list is a GOOD outcome;
every proposal must carry evidence you could defend to the speaker.

CLASS proper-noun-garble: a name/term rendered as phonetically-similar English
  that doesn't fit the context (tell: same unknown thing spelled differently at
  different spots). If it maps to a known vocabulary term, propose that exact
  spelling; if unknown, propose your best reconstruction and say UNKNOWN.
CLASS semantic-absurdity: an everyday word this speaker would never say here,
  where a PHONETICALLY-NEAR alternative fits perfectly (feature/picture,
  cache/cash). BOTH conditions required.
CLASS polarity-flip: a negation immediately followed by an elaboration that
  AFFIRMS the negated thing's own definition (after "not X" people
  differentiate from X; after "like X" they match it) AND a phonetically
  confusable non-negated alternative (like/not, can/can't) resolves the
  contradiction. Genuine contrastive rhetoric (elaboration DISTINGUISHES) must
  NOT be flagged. Highest stakes: these invert meaning.
CLASS grammar-artifact: syntactic ill-formedness caused by a bound-morpheme
  ASR artifact — an added or dropped suffix (-s, -ing, -ed, -'s). Two subtypes:
  agreement ("borrow checkers certainly has" = "checker has" with a liaison-
  manufactured S — repair the NOUN, not the verb) and truncation ("Worry about
  this is basically done" = elided -ing, "Worrying about this is..."). Propose
  the PHONETICALLY-NEAREST morpheme restoration, tie-broken by how the speaker
  uses the word elsewhere. NEVER propose the naive grammar-checker fix if it
  moves the text away from the audio; note some dialects genuinely drop
  -ed/-s — the minimal repair must match the speaker's own usage.
CLASS edit (scope=edit): intelligent-verbatim suggestions ONLY — a false start
  or dangling turn-initial/mid conjunction whose removal improves readability
  without losing meaning. A trailing-off "and..." at an interruption is
  information: keep it. These affect only the optional edited rendering.

Return ONLY a JSON array (no prose, no fences). One object per finding:
[{{"i": <turn index>, "class": "<class>", "verbatim": "<exact substring from the
turn, minimal but unique>", "proposed": "<replacement text>",
"evidence": "<one sentence>", "scope": "correction"}}]
Use "scope": "edit" for CLASS edit. If a chunk has no findings, return []."""


def call_claude(prompt):
    r = subprocess.run(["claude", "-p", prompt, "--model", MODEL,
                        "--output-format", "text", *FAST],
                       capture_output=True, text=True, timeout=240)
    if r.returncode != 0:
        raise RuntimeError(r.stderr[:300])
    return r.stdout.strip()


def parse_json_array(s):
    s = re.sub(r"^```(?:json)?\s*", "", s.strip())
    s = re.sub(r"\s*```$", "", s)
    a, b = s.find("["), s.rfind("]")
    if a == -1 or b == -1:
        raise ValueError("no JSON array")
    return json.loads(s[a:b + 1])


def review_chunk(args):
    start, chunk, turns = args
    ctx_turns = turns[max(0, start - CONTEXT):start]
    ctx = ""
    if ctx_turns:
        ctx = ("Preceding turns for context only:\n" +
               "\n".join(f'  ({t.get("speaker", "?")}) {t["text"][:90]}'
                         for t in ctx_turns) + "\n\n")
    lines = "\n".join(f'[{start+k}] ({t.get("speaker", "?")}) {t["text"]}'
                      for k, t in enumerate(chunk))
    prompt = f"{BRIEF}\n\n{ctx}Turns {start}..{start+len(chunk)-1}:\n{lines}"
    for attempt in range(3):
        try:
            findings = parse_json_array(call_claude(prompt))
            # keep only findings whose verbatim actually occurs in the named turn
            good = []
            for f in findings:
                i = f.get("i")
                if (isinstance(i, int) and start <= i < start + len(chunk)
                        and f.get("verbatim") and f.get("proposed") is not None
                        and f["verbatim"] in turns[i]["text"]):
                    good.append(f)
            return good
        except Exception as e:
            print(f"  repair chunk@{start} attempt {attempt+1}: {e}", flush=True)
    return []


def fmt_ts(t):
    return f"{int(t//3600):02d}:{int(t%3600//60):02d}:{int(t%60):02d}"


def derive_scope(f):
    """scope closed to {correction, edit}; a CLASS edit (case-folded) forces
    scope=edit so a readability change can never bake into the canonical
    verbatim. Any other value collapses to correction."""
    if str(f.get("class", "")).strip().lower() == "edit" \
            or str(f.get("scope", "")).strip().lower() == "edit":
        return "edit"
    return "correction"


def main():
    src = WORK / "turns_named.json"
    if not src.exists():
        src = WORK / "turns.json"
    turns = json.loads(src.read_text())
    jobs = [(i, turns[i:i + CHUNK], turns) for i in range(0, len(turns), CHUNK)]
    print(f"  repair pass: {len(turns)} turns -> {len(jobs)} chunks", flush=True)

    findings = []
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for got in ex.map(review_chunk, jobs):
            findings.extend(got)

    # merge into corrections.json as proposed entries (never touch approved)
    cpath = WORK / "corrections.json"
    existing = []
    if cpath.exists():
        data = json.loads(cpath.read_text())
        # tolerant: {"corrections": [...]} or a bare list (isinstance BEFORE .get).
        existing = (data.get("corrections", []) if isinstance(data, dict)
                    else data if isinstance(data, list) else [])
    # dedup key includes scope so an identical-text correction and edit don't
    # collapse into one entry (they render/apply differently).
    known = {(c.get("pattern"), c.get("replacement"), c.get("turn"), c.get("scope"))
             for c in existing}
    added = 0
    for f in findings:
        scope = derive_scope(f)
        # "turn" anchors the fix to the turn the EVIDENCE came from: the
        # applier only touches that turn, so a short verbatim like "the list"
        # can never rewrite innocent occurrences elsewhere in the transcript.
        entry = {"pattern": re.escape(f["verbatim"]),
                 "replacement": f["proposed"],
                 "turn": f["i"],
                 "scope": scope,
                 "status": "proposed",
                 "class": f.get("class", "?"),
                 "note": f.get("evidence", "")}
        key = (entry["pattern"], entry["replacement"], entry["turn"], entry["scope"])
        if key not in known:
            existing.append(entry)
            known.add(key)
            added += 1
    cpath.write_text(json.dumps({"corrections": existing}, indent=1,
                                ensure_ascii=False))

    # human-readable report
    lines = [f"# Repair report — {len(findings)} findings "
             f"({added} new proposals)\n"]
    for f in findings:
        t = turns[f["i"]]
        lines.append(f"- [{fmt_ts(t['start'])}] {t.get('speaker', '?')} "
                     f"**{f.get('class', '?')}** ({derive_scope(f)}): "
                     f"“{f['verbatim']}” → “{f['proposed']}”"
                     f" — {f.get('evidence', '')}")
    unknowns = [f for f in findings if "UNKNOWN" in f.get("evidence", "").upper()]
    if unknowns:
        lines.append("\n## Unknown referents — web-search these before approving; "
                     "add resolved spellings to the roster glossary")
    (WORK / "repair_report.md").write_text("\n".join(lines) + "\n")
    print(f"  repair: {len(findings)} findings, {added} new proposals -> "
          f"corrections.json (status=proposed) + repair_report.md", flush=True)
    if added:
        print("  review repair_report.md, approve entries in corrections.json, "
              "then: run.sh --apply <workdir> <speakers.json>", flush=True)


if __name__ == "__main__":
    main()
