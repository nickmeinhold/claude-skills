#!/usr/bin/env python3
"""Assemble final deliverables: transcript.html / .txt / .srt.

Reads turns_named.json if present (named speakers), else turns.json (anonymous
clusters rendered as "Speaker 0/1/..."). Drops orphan-echo duplicate turns,
coalesces consecutive same-speaker turns, auto-discovers however many speakers
in first-appearance order, assigns a stable colour per speaker.

If corrections.json contains APPROVED scope=edit entries (intelligent-verbatim
suggestions from repair.py), additionally renders transcript_edited.html with
those edits applied. The canonical verbatim outputs are never touched by edits.
"""
import json
import os
import re
from pathlib import Path
from html import escape

WORK = Path(os.environ["TRANSCRIBE_WORK"])
TITLE = os.environ.get("TRANSCRIBE_TITLE", "Transcript")

# glossary links: {"term": ..., "url": ...} entries in the config's
# vocabulary/glossary become hyperlinks in the HTML (first occurrence per term)
LINKS = {}
_cfg_path = os.environ.get("TRANSCRIBE_CONFIG")
if _cfg_path and Path(_cfg_path).exists():
    _cfg = json.loads(Path(_cfg_path).read_text())
    for _t in (_cfg.get("vocabulary") or _cfg.get("glossary") or []):
        if isinstance(_t, dict) and _t.get("url"):
            LINKS[_t["term"]] = _t["url"]

_patterns = sorted(LINKS, key=len, reverse=True)  # longest first: "aiko chat" before "aiko"


def linkify(escaped_text, linked):
    """Wrap the FIRST occurrence (per document) of each linked term in <a>."""
    for term in _patterns:
        if term in linked:
            continue
        m = re.search(rf"\b{re.escape(escape(term))}\b", escaped_text, re.I)
        if m:
            url = escape(LINKS[term], quote=True)
            escaped_text = (escaped_text[:m.start()]
                            + f'<a href="{url}">{m.group(0)}</a>'
                            + escaped_text[m.end():])
            linked.add(term)
    return escaped_text


named = WORK / "turns_named.json"
src = named if named.exists() else WORK / "turns.json"
turns = json.loads(src.read_text())
KEY = "speaker" if named.exists() else "cluster"


def is_orphan_echo(t, prev):
    """A diarization double-count: a short utterance assigned BOTH to the tail
    of the previous turn and to a stray UNATTRIBUTED turn of its own ("nick has
    as well" duplicated as SPEAKER_01 in a named transcript, 7.3 session).

    Fires ONLY in named mode, ONLY on turns attribution left as a raw
    SPEAKER_nn label. A speaker-change echo ("...yeah" followed by another
    speaker's "yeah") is REAL backchannel speech — the first version of this
    heuristic dropped 8 such turns on the 7.3 session, which is why the gate
    is this tight. Every drop is logged."""
    if KEY != "speaker":
        return False  # anonymous mode: every label is SPEAKER_nn; never fire
    if not re.match(r"SPEAKER_\d+$", str(t.get(KEY, ""))):
        return False  # attribution assigned a real name: never drop
    txt = t.get("text", "").strip()
    if not txt or len(txt) > 40 or prev is None:
        return False
    if not prev.get("text", "").strip().lower().endswith(txt.lower()):
        return False
    return t["start"] - prev["end"] <= 3.0


_kept, _prev = [], None
for _t in turns:
    if is_orphan_echo(_t, _prev):
        print(f'  dedupe: dropped orphan echo at {_t["start"]:.1f}s '
              f'({_t.get(KEY)}): "{_t["text"][:40]}"', flush=True)
        continue
    _kept.append(_t)
    _prev = _t
turns = _kept

# intelligent-verbatim: approved scope=edit corrections drive a SECOND rendering
EDITS = []
_cpath = WORK / "corrections.json"
if _cpath.exists():
    _cdata = json.loads(_cpath.read_text())
    EDITS = [c for c in _cdata.get("corrections", [])
             if c.get("scope") == "edit"
             and c.get("status", "approved") == "approved"]

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


def render_html(blocks_, mode_note, out_name):
    linked = set()
    rows = "\n".join(
        f'<div class="turn" id="t{int(b["start"])}"><div class="meta"><span class="spk" style="color:{color[b["spk"]]}">'
        f'{escape(b["spk"])}</span><a class="ts" href="#t{int(b["start"])}">{fmt_ts(b["start"])[:8]}</a></div>'
        f'<div class="text" style="border-left:3px solid {color[b["spk"]]}">{linkify(escape(b["text"]), linked)}</div></div>'
        for b in blocks_)
    refs = ""
    if linked:
        items = "".join(f'<li><a href="{escape(LINKS[t], quote=True)}">{escape(t)}</a></li>'
                        for t in sorted(linked, key=str.lower))
        refs = f'<div class="refs"><h2>References</h2><ul>{items}</ul></div>'
    legend = " &nbsp;&nbsp; ".join(
        f'<span><span class="dot" style="background:{color[s]}"></span>{escape(s)}</span>' for s in seen)
    last = fmt_ts(blocks_[-1]["end"])[:8] if blocks_ else "00:00:00"
    html = f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{escape(TITLE)} — Transcript</title>
<style>
 body{{font-family:-apple-system,system-ui,sans-serif;max-width:760px;margin:0 auto;padding:2rem 1.25rem;line-height:1.55;color:#1a1a1a}}
 h1{{font-size:1.5rem;margin-bottom:.25rem}} .sub{{color:#666;font-size:.9rem;margin-bottom:1rem}}
 .turn{{margin-bottom:1.1rem}} .meta{{display:flex;gap:.6rem;align-items:baseline;font-size:.8rem;margin-bottom:.2rem}}
 .spk{{font-weight:700}} .ts{{color:#999;font-variant-numeric:tabular-nums;text-decoration:none}} .ts:hover{{color:#555}} .text{{padding-left:.75rem}}
 .turn:target .text{{background:#fffbe6;border-radius:4px}}
 .legend{{font-size:.85rem;color:#555;margin-bottom:1.5rem}}
 .dot{{display:inline-block;width:.7rem;height:.7rem;border-radius:50%;margin-right:.3rem;vertical-align:middle}}
 .text a{{color:inherit;text-decoration:underline dotted #888;text-underline-offset:2px}}
 .refs{{margin-top:2rem;border-top:1px solid #ddd;padding-top:1rem;font-size:.9rem}}
 .refs h2{{font-size:1rem;margin-bottom:.4rem}} .refs ul{{columns:2;list-style:none;padding:0}} .refs li{{margin-bottom:.2rem}}
</style></head><body>
<h1>{escape(TITLE)}</h1>
<div class="sub">Parakeet-1.1b + pyannote (local, Apple Silicon) · {mode_note} · ends {last} · {len(seen)} speakers · {len(blocks_)} turns</div>
<div class="legend">{legend}</div>
{rows}
{refs}
</body></html>'''
    (WORK / out_name).write_text(html)


mode = "named (LLM attribution)" if named.exists() else "anonymous diarization"
render_html(blocks, mode, "transcript.html")

if EDITS:
    import copy
    eblocks = copy.deepcopy(blocks)
    n_edits = 0
    for b in eblocks:
        for c in EDITS:
            flags = re.I if "i" in c.get("flags", "") else 0
            b["text"], k = re.subn(c["pattern"], c["replacement"], b["text"], flags=flags)
            n_edits += k
        # tidy double spaces edits leave behind
        b["text"] = re.sub(r"\s{2,}", " ", b["text"]).strip()
    render_html(eblocks, mode + " · intelligent verbatim (edited)", "transcript_edited.html")
    print(f"  transcript_edited.html -> {n_edits} edits applied "
          f"({len(EDITS)} approved edit entries)", flush=True)

print(f"  transcript.html / .txt / .srt -> {len(blocks)} turns, {len(seen)} speakers: {seen}", flush=True)
