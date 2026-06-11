#!/usr/bin/env python3
"""Diarize WORK/audio.wav -> WORK/diarization.rttm.

Uses the pyannote Python pipeline (not the CLI) so we can pass num_speakers when
the headcount is known -- this sharply cuts over/under-clustering at fast
speaker changes. Set TRANSCRIBE_NUM_SPEAKERS to pin it; leave empty to auto-detect.
"""
import os
from pathlib import Path
from pyannote.audio import Pipeline
import torch

WORK = Path(os.environ["TRANSCRIBE_WORK"])
num = os.environ.get("TRANSCRIBE_NUM_SPEAKERS") or ""
num_speakers = int(num) if num.strip().isdigit() else None

pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1")
device = "mps" if torch.backends.mps.is_available() else "cpu"
pipeline.to(torch.device(device))
print(f"  pyannote on {device}, num_speakers={num_speakers or 'auto'}", flush=True)

out = pipeline(str(WORK / "audio.wav"), num_speakers=num_speakers)
diar = getattr(out, "speaker_diarization", out)  # pyannote 4 DiarizeOutput or Annotation

with open(WORK / "diarization.rttm", "w") as f:
    diar.write_rttm(f)

speakers = sorted({lbl for *_, lbl in diar.itertracks(yield_label=True)})
print(f"  wrote diarization.rttm ({len(speakers)} speakers)", flush=True)
