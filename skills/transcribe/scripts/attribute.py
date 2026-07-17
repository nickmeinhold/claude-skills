#!/usr/bin/env python3
"""LLM speaker-identity attribution via headless Claude Code (Max plan, $0).

Reads a speakers.json config (cast profiles + optional ground-truth anchor lines)
and labels each turn with a real name, using speech-pattern matching, conversational
flow, and the diarization cluster as a soft hint. Can split an under-clustered turn
into two speakers. Lightly fixes obvious ASR errors without inventing content.

Calls run in PARALLEL with tools/MCP disabled -- otherwise each headless call pays
the full session-startup tax (MCP server dial-out) and can hang past any timeout.

Reads  $TRANSCRIBE_WORK/turns.json + $TRANSCRIBE_CONFIG
Writes $TRANSCRIBE_WORK/turns_named.json
"""
import json
import os
import re
import subprocess
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

WORK = Path(os.environ["TRANSCRIBE_WORK"])
CONFIG = json.loads(Path(os.environ["TRANSCRIBE_CONFIG"]).read_text())
MODEL = "sonnet"
CHUNK = 100
CONTEXT = 8
WORKERS = 6
FAST = ["--disallowedTools", "*", "--mcp-config", '{"mcpServers":{}}',
        "--strict-mcp-config"]

SPEAKERS = CONFIG.get("speakers") or []
NAMED = bool(SPEAKERS)
if not NAMED:
    # vocabulary-only config: keep anonymous diarization clusters as the "cast"
    _clusters = sorted({t["cluster"]
                        for t in json.loads((WORK / "turns.json").read_text())})
    SPEAKERS = [{"name": c} for c in _clusters]
NAMES = [s["name"] for s in SPEAKERS]


def build_cast():
    lines = []
    ctx = CONFIG.get("context")
    if not NAMED:
        lines.append("Speakers are anonymous diarization clusters "
                     f"({', '.join(NAMES)}); keep each turn's cluster as its "
                     "speaker unless conversational flow clearly shows a mis-split."
                     + (f" Context: {ctx}" if ctx else ""))
        return "\n".join(lines)
    lines.append(f"The conversation has EXACTLY {len(SPEAKERS)} participants."
                 + (f" Context: {ctx}" if ctx else "") + " Profiles:\n")
    for s in SPEAKERS:
        bits = [f"- {s['name']}:"]
        if s.get("profile"):
            bits.append(s["profile"].rstrip("."))
        line = " ".join(bits) + "."
        if s.get("anchor"):
            line += f' GROUND TRUTH: {s["name"]} says "{s["anchor"]}"'
        lines.append(line)
    return "\n".join(lines)


CAST = build_cast()
VOCAB = CONFIG.get("vocabulary") or []
VOCAB_BLOCK = ""
if VOCAB:
    VOCAB_BLOCK = (
        "\nDOMAIN VOCABULARY -- these exact terms appear in this conversation. The ASR "
        "does not know them and renders them as phonetically-similar English (often "
        "several different spellings for one term). When a word is phonetically close "
        "to one of these, correct it to this exact spelling: "
        + ", ".join(VOCAB) + "\n")
RULES = f"""\
{VOCAB_BLOCK}
For EACH numbered turn, decide who is speaking. Use, in priority order:
1. Any GROUND TRUTH lines above (those exact turns are fixed).
2. Content & speech-pattern matching against the profiles.
3. Conversational flow (a question from A is usually answered by someone else).
4. The "cluster" tag is a HINT from automatic diarization: same cluster is OFTEN
   the same person, but it's wrong at fast exchanges -- OVERRIDE it when content
   clearly indicates otherwise.

Also fix CLEAR speech-recognition errors (garbled domain terms or names) but
preserve the speaker's wording and NEVER invent or remove content. If a turn's
text is already fine, copy it verbatim.

If a SINGLE turn clearly contains TWO speakers, SPLIT it: emit multiple objects
with the SAME "i", in spoken order, each with its own speaker and slice of text.

Return ONLY a JSON array, in input order. Normally one object per turn; more only
when you split a turn:
[{{"i": <index>, "speaker": "<{'|'.join(NAMES)}>", "text": "<cleaned text>"}}]
No prose, no markdown fences."""


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


def try_chunk(start, chunk, turns):
    """One attribution attempt for a span. Returns {i: [obj,...]} or None on failure."""
    ctx_turns = turns[max(0, start - CONTEXT):start]
    ctx = ""
    if ctx_turns:
        ctx = ("Preceding turns for context (do NOT relabel):\n" +
               "\n".join(f'  ({t["cluster"]}) {t["text"][:90]}' for t in ctx_turns) + "\n\n")
    lines = "\n".join(f'[{start+k}] (cluster {t["cluster"]}) {t["text"]}'
                      for k, t in enumerate(chunk))
    prompt = (f"{CAST}\n{RULES}\n\n{ctx}Transcript turns to label "
              f"(indices {start}..{start+len(chunk)-1}):\n{lines}")
    for attempt in range(3):
        try:
            arr = parse_json_array(call_claude(prompt))
            by_i = {}
            for o in arr:
                if "i" in o:
                    by_i.setdefault(o["i"], []).append(o)
            if len(by_i) >= len(chunk) * 0.8:
                return by_i
        except Exception as e:
            print(f"  chunk@{start} (n={len(chunk)}) attempt {attempt+1}: {e}", flush=True)
    return None


def label_chunk(args):
    """Attribute a span; on hard failure, split in half and recurse so one bad
    turn costs <=5 turns instead of sinking the whole 100-turn chunk to anonymous."""
    start, chunk, turns = args
    by_i = try_chunk(start, chunk, turns)
    if by_i is not None:
        return start, by_i
    if len(chunk) <= 5:
        return start, {}  # give up on this small span -> cluster-id fallback
    mid = len(chunk) // 2
    print(f"  chunk@{start} failed -> splitting ({len(chunk)} -> {mid}+{len(chunk)-mid})", flush=True)
    _, left = label_chunk((start, chunk[:mid], turns))
    _, right = label_chunk((start + mid, chunk[mid:], turns))
    return start, {**left, **right}


def main():
    turns = json.loads((WORK / "turns.json").read_text())
    jobs = [(i, turns[i:i + CHUNK], turns) for i in range(0, len(turns), CHUNK)]
    print(f"  {len(turns)} turns -> {len(jobs)} chunks, {WORKERS} parallel", flush=True)

    results = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for start, by_i in ex.map(label_chunk, jobs):
            results[start] = by_i

    assigned = []
    for start, chunk, _ in jobs:
        by_i = results.get(start, {})
        for k, t in enumerate(chunk):
            for o in (by_i.get(start + k) or [{}]):
                assigned.append({"start": t["start"], "end": t["end"],
                                 "cluster": t["cluster"],
                                 "speaker": o.get("speaker") or t["cluster"],
                                 "text": o.get("text") or t["text"],
                                 "orig": t["text"]})

    (WORK / "turns_named.json").write_text(json.dumps(assigned, indent=1, ensure_ascii=False))
    from collections import Counter
    unl = sum(1 for t in assigned if t["speaker"] not in NAMES)
    print(f"  {len(assigned)} turns labelled "
          f"({dict(Counter(t['speaker'] for t in assigned))}); {unl} unresolved", flush=True)
    if unl:
        print("  NOTE: some turns stayed anonymous. Add ground-truth `anchor` lines to "
              "speakers.json (one verbatim line each speaker said) and re-run with:\n"
              "    run.sh --reattribute <workdir> <speakers.json>", flush=True)


if __name__ == "__main__":
    main()
