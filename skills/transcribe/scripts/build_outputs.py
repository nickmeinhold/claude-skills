#!/usr/bin/env python3
"""Assemble final deliverables: transcript.html / .txt / .srt.

Reads turns_named.json if present (named speakers), else turns.json (anonymous
clusters rendered as "Speaker 0/1/..."). Coalesces consecutive same-speaker turns,
auto-discovers however many speakers in first-appearance order, assigns a stable
colour per speaker.
"""
import json
import os
import re
from pathlib import Path
from html import escape

WORK = Path(os.environ["TRANSCRIBE_WORK"])
TITLE = os.environ.get("TRANSCRIBE_TITLE", "Transcript")

named = WORK / "turns_named.json"
src = named if named.exists() else WORK / "turns.json"
turns = json.loads(src.read_text())
KEY = "speaker" if named.exists() else "cluster"

PALETTE = ["#2563eb", "#dc2626", "#059669", "#d97706", "#7c3aed",
           "#0891b2", "#db2777", "#65a30d", "#9333ea", "#0d9488"]


def nice(label):
    m = re.match(r"SPEAKER_0*(\d+)$", label)
    return f"Speaker {int(m.group(1))}" if m else label


def fmt_ts(t):
    return f"{int(t//3600):02d}:{int(t%3600//60):02d}:{t%60:06.3f}"


def fmt_srt(t):
    return f"{int(t//3600):02d}:{int(t%3600//60):02d}:{int(t%60):02d},{int((t-int(t))*1000):03d}"


# coalesce consecutive same-speaker turns
blocks = []
for t in turns:
    spk = nice(t[KEY])
    if blocks and blocks[-1]["spk"] == spk:
        blocks[-1]["text"] += " " + t["text"]
        blocks[-1]["end"] = t["end"]
    else:
        blocks.append({"spk": spk, "text": t["text"], "start": t["start"], "end": t["end"]})

# discover speakers in first-appearance order
seen = []
for b in blocks:
    if b["spk"] not in seen:
        seen.append(b["spk"])
color = {s: PALETTE[i % len(PALETTE)] for i, s in enumerate(seen)}

# txt
(WORK / "transcript_speakers.txt").write_text(
    "\n".join(f'[{fmt_ts(b["start"])}] {b["spk"]}:\n{b["text"]}\n' for b in blocks))

# srt (per turn, tight timing)
(WORK / "transcript_speakers.srt").write_text(
    "\n".join(f'{i}\n{fmt_srt(t["start"])} --> {fmt_srt(t["end"])}\n[{nice(t[KEY])}] {t["text"]}\n'
              for i, t in enumerate(turns, 1)))

# html
rows = "\n".join(
    f'<div class="turn"><div class="meta"><span class="spk" style="color:{color[b["spk"]]}">'
    f'{escape(b["spk"])}</span><span class="ts">{fmt_ts(b["start"])[:8]}</span></div>'
    f'<div class="text" style="border-left:3px solid {color[b["spk"]]}">{escape(b["text"])}</div></div>'
    for b in blocks)
legend = " &nbsp;&nbsp; ".join(
    f'<span><span class="dot" style="background:{color[s]}"></span>{escape(s)}</span>' for s in seen)
last = fmt_ts(blocks[-1]["end"])[:8] if blocks else "00:00:00"
mode = "named (LLM attribution)" if named.exists() else "anonymous diarization"
html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(TITLE)} — Transcript</title>
<style>
 body{{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:0 auto;padding:2rem 1.25rem;line-height:1.55;color:#1a1a1a}}
 h1{{font-size:1.5rem;margin-bottom:.25rem}} .sub{{color:#666;font-size:.9rem;margin-bottom:1rem}}
 .turn{{margin-bottom:1.1rem}} .meta{{display:flex;gap:.6rem;align-items:baseline;font-size:.8rem;margin-bottom:.2rem}}
 .spk{{font-weight:700}} .ts{{color:#999;font-variant-numeric:tabular-nums}} .text{{padding-left:.75rem}}
 .legend{{font-size:.85rem;color:#555;margin-bottom:1.5rem}}
 .dot{{display:inline-block;width:.7rem;height:.7rem;border-radius:50%;margin-right:.3rem;vertical-align:middle}}
</style></head><body>
<h1>{escape(TITLE)}</h1>
<div class="sub">Parakeet-1.1b + pyannote (local, Apple Silicon) · {mode} · ends {last} · {len(seen)} speakers · {len(blocks)} turns</div>
<div class="legend">{legend}</div>
{rows}
</body></html>'''
(WORK / "transcript.html").write_text(html)
print(f"  transcript.html / .txt / .srt -> {len(blocks)} turns, {len(seen)} speakers: {seen}", flush=True)
