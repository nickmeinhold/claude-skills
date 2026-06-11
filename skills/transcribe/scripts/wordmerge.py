#!/usr/bin/env python3
"""Word-level fusion of Parakeet tokens with pyannote turns.

Assign each TOKEN to the diarization turn containing its midpoint, then group
consecutive same-speaker tokens into turns -- splitting on a >0.6s silence gap
even within one speaker. A sentence spanning a speaker change splits at the word
where the voice changes. Text is filler/repeat-cleaned.

Reads  $TRANSCRIBE_WORK/audio.json + diarization.rttm
Writes $TRANSCRIBE_WORK/turns.json  [{start,end,cluster,text}]
"""
import json
import os
from pathlib import Path
from clean_text import clean

WORK = Path(os.environ["TRANSCRIBE_WORK"])
GAP_SPLIT = 0.6


def load_rttm(path):
    turns = []
    for line in path.read_text().splitlines():
        p = line.split()
        if p and p[0] == "SPEAKER":
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            turns.append((start, start + dur, spk))
    turns.sort()
    return turns


def speaker_at(t, turns):
    best, bestgap = None, 2.0
    for ts, te, spk in turns:
        if ts <= t <= te:
            return spk
        gap = ts - t if t < ts else t - te
        if gap < bestgap:
            best, bestgap = spk, gap
    return best


def load_tokens(path):
    data = json.loads(path.read_text())
    segs = data.get("sentences") or data.get("segments") or []
    toks = []
    for s in segs:
        for tk in s.get("tokens", []):
            if tk["text"].strip():
                mid = (float(tk["start"]) + float(tk["end"])) / 2
                toks.append((float(tk["start"]), float(tk["end"]), mid, tk["text"]))
    return toks


def main():
    turns = load_rttm(WORK / "diarization.rttm")
    toks = load_tokens(WORK / "audio.json")

    grouped = []  # [start, end, cluster, [token_texts]]
    for s, e, mid, txt in toks:
        spk = speaker_at(mid, turns) or "UNKNOWN"
        same = grouped and grouped[-1][2] == spk
        gap_ok = grouped and (s - grouped[-1][1]) <= GAP_SPLIT
        if same and gap_ok:
            grouped[-1][1] = e
            grouped[-1][3].append(txt)
        else:
            grouped.append([s, e, spk, [txt]])

    out = []
    for s, e, spk, parts in grouped:
        txt = clean("".join(parts).strip())
        if txt:
            out.append({"start": round(s, 2), "end": round(e, 2),
                        "cluster": spk, "text": txt})
    (WORK / "turns.json").write_text(json.dumps(out, indent=1, ensure_ascii=False))

    from collections import Counter
    print(f"  {len(toks)} tokens -> {len(out)} turns "
          f"({dict(Counter(t['cluster'] for t in out))})", flush=True)


if __name__ == "__main__":
    main()
