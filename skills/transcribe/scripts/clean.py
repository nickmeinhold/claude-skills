#!/usr/bin/env python3
"""Editorial cleanup stage (zero-cost headless Claude).

A layer ON TOP of the faithful transcript: removes stutters / false starts /
repetition / fillers and normalises ASR garbles to an optional PROJECT glossary,
while preserving meaning and each speaker's voice. Never summarises or invents.

Operates in the JSON pipeline so `build` stays the single renderer:
  Reads  the corrected transcript $TRANSCRIBE_WORK/turns_named.json (derived by
         apply_corrections) if present, else raw turns.json. named vs anonymous
         is inferred from the data (a "speaker" key on each turn), not the
         filename, so this stage needs no separate mode signal.
  Writes $TRANSCRIBE_WORK/turns_clean.json  (coalesced blocks, cleaned text)

Glossary + context are read from $TRANSCRIBE_CONFIG (speakers.json), optional keys
  "glossary": ["aiko", "ChatServer", ...]   and   "context": "..."
so the skill stays domain-agnostic — the vocabulary lives with the cast.

Calls run in PARALLEL with tools/MCP disabled (same rationale as attribute.py).
"""
import json, os, re, subprocess, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

WORK = Path(os.environ["TRANSCRIBE_WORK"])
MODEL = os.environ.get("TRANSCRIBE_MODEL", "sonnet")
CHUNK = 18
WORKERS = 6
FAST = ["--disallowedTools", "*", "--mcp-config", '{"mcpServers":{}}',
        "--strict-mcp-config"]

CONFIG = {}
cfg_path = os.environ.get("TRANSCRIBE_CONFIG") or ""
if cfg_path and Path(cfg_path).exists():
    CONFIG = json.loads(Path(cfg_path).read_text())
GLOSSARY = ", ".join(CONFIG.get("glossary", []))
CONTEXT = CONFIG.get("context", "")

_gloss = (f"\n2. Fix CLEAR speech-recognition errors, normalising domain terms to this "
          f"PROJECT GLOSSARY (match its capitalisation exactly): {GLOSSARY}"
          if GLOSSARY else
          "\n2. Fix CLEAR speech-recognition errors (garbled words/names).")

RULES = f"""You are an expert transcript editor. You are given numbered turns from a
verbatim speech-to-text transcript.{(' Context: ' + CONTEXT) if CONTEXT else ''}

For EACH numbered turn, return a CLEANED version of the text that:
1. Removes filler words (um, uh, er, and vestigial "you know / like / sort of / kind
   of"), false starts, stutters, and repetition. Example:
   "but when you when you're when you're working" -> "but when you're working".{_gloss}
3. Adds sentence capitalisation and punctuation for readability.
4. PRESERVES meaning and the speaker's own wording and voice. Do NOT summarise,
   paraphrase heavily, add content, or drop substantive points. This is cleanup,
   not rewriting. A pure back-channel ("yep", "okay", "yeah") stays as is.
5. If a turn is already clean, return it unchanged.

Return ONLY a JSON array in input order, one object per turn:
[{{"i": <index>, "text": "<cleaned text>"}}]
No prose, no markdown fences."""


def coalesce(turns):
    """Merge consecutive same-speaker turns (same logic build uses) so the LLM
    sees connected prose with cross-turn context — better than per-fragment."""
    key = "speaker" if turns and "speaker" in turns[0] else "cluster"
    blocks = []
    for t in turns:
        if blocks and blocks[-1][key] == t[key]:
            blocks[-1]["text"] += " " + t["text"]
            blocks[-1]["end"] = t["end"]
        else:
            blocks.append({key: t[key], "text": t["text"],
                           "start": t["start"], "end": t["end"]})
    return blocks, key


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


def edit_chunk(args):
    start, chunk, key = args
    numbered = "\n".join(f'{start+i}: [{b[key]}] {b["text"]}'
                         for i, b in enumerate(chunk))
    prompt = RULES + "\n\nTURNS:\n" + numbered
    for attempt in range(3):
        try:
            arr = parse_json_array(call_claude(prompt))
            by_i = {o["i"]: o["text"] for o in arr if "i" in o and "text" in o}
            return [(start + i, by_i.get(start + i, chunk[i]["text"]))
                    for i in range(len(chunk))]
        except Exception as e:
            if attempt == 2:
                print(f"  chunk @{start} failed ({e}); keeping verbatim", file=sys.stderr)
                return [(start + i, chunk[i]["text"]) for i in range(len(chunk))]


def main():
    named = WORK / "turns_named.json"
    src = named if named.exists() else WORK / "turns.json"
    turns = json.loads(src.read_text())
    blocks, key = coalesce(turns)
    print(f"  {len(turns)} turns -> {len(blocks)} blocks; cleaning"
          + (f" with glossary ({len(CONFIG.get('glossary', []))} terms)" if GLOSSARY else ""),
          flush=True)
    jobs = [(i, blocks[i:i + CHUNK], key) for i in range(0, len(blocks), CHUNK)]
    cleaned = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        for res in ex.map(edit_chunk, jobs):
            for i, text in res:
                cleaned[i] = text
    for i, b in enumerate(blocks):
        b["text"] = cleaned.get(i, b["text"])
    (WORK / "turns_clean.json").write_text(json.dumps(blocks, ensure_ascii=False, indent=1))
    print(f"  wrote turns_clean.json ({len(blocks)} blocks)", flush=True)


if __name__ == "__main__":
    main()
