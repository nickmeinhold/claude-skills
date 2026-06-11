---
argument-hint: <audio-or-video-file> [speakers.json]
description: Transcribe an audio/video file locally on Apple Silicon (Parakeet + pyannote, no API) into a speaker-attributed HTML/txt/srt transcript. Optional speakers.json (cast profiles + ground-truth anchor lines) unlocks LLM identity attribution so turns are labelled with real names instead of anonymous Speaker 0/1/2. Use when Nick wants a meeting/call/podcast recording transcribed with who-said-what.
---

# transcribe — local speaker-attributed transcription

Turns a recording into a readable, speaker-labelled transcript entirely on-device
(zero API cost): NVIDIA Parakeet (MLX) for words, pyannote for voices, and an
optional headless-Claude pass for real-name attribution.

## Run it

```bash
bash ~/.claude/skills/transcribe/scripts/run.sh <audio-or-video-file> [speakers.json]
```

- **No second arg** → anonymous speakers (`Speaker 0`, `Speaker 1`, …). Good enough when you only need who-said-what separation, not names.
- **With `speakers.json`** → the LLM attribution pass labels every turn with real
  names, seeded by per-person profiles and ground-truth anchor lines, and can
  split a turn when the diarizer merged two fast speakers.

Outputs land in `~/git/transcribe-<basename>/`: `transcript.html` (open this),
`transcript_speakers.txt`, `transcript_speakers.srt`, plus the intermediates
(`audio.json`, `diarization.rttm`, `turns.json`, `turns_named.json`).

> Work dir defaults to `~/git/...`, NOT `~/Downloads` — the latter is macOS
> TCC-protected and the auto-updating `claude` binary loses access to it (see
> memory `reference-downloads-tcc-treadmill`). Override with `TRANSCRIBE_WORK=...`.

## speakers.json

Copy `speakers.example.json` and fill in what you know. Everything except `name`
is optional, but a `profile` and especially an `anchor` (one line you KNOW that
person said, verbatim-ish) dramatically improve attribution accuracy.

```json
{
  "title": "Team sync",
  "context": "A small product team planning meeting.",
  "num_speakers": 3,
  "speakers": [
    {"name": "Avery", "profile": "team lead; drives the agenda, talks roadmap & priorities", "anchor": "let's lock the scope before we touch any code"},
    {"name": "Blake", "profile": "engineer; implementation detail and trade-offs."},
    {"name": "Casey", "profile": "joins partway through, mostly listens."}
  ]
}
```

- `num_speakers` (optional): if you know the headcount, it's passed to pyannote
  (`num_speakers=N`) and sharply reduces over/under-clustering. Omit to auto-detect.

## Pipeline (what run.sh does)

1. **Condition audio** — ffmpeg loudness-normalise (EBU R128) + 70 Hz high-pass → 16 kHz mono WAV. Lifts quiet speakers.
2. **Diarize** — `pyannote/speaker-diarization-community-1`, pinned to `num_speakers` if provided (`diarize.py`).
3. **Transcribe** — `parakeet-tdt-1.1b` with word-level timestamps.
4. **Fuse + clean** — assign each WORD to its speaker turn by midpoint, split on >0.6s silence gaps, strip fillers (um/uh/…) and immediate word-repeats (`wordmerge.py` + `clean_text.py`).
5. **Attribute** *(only if speakers.json)* — headless Claude labels each turn by speech pattern + flow, anchored on the ground-truth lines, split-aware, with light ASR fixups (`attribute.py`). Tools/MCP disabled so calls don't hang.
6. **Build** — `build_outputs.py` → html/txt/srt; auto-discovers however many speakers, stable colour per name.

## Notes / failure modes

- First run downloads the models (~2 GB) into the HF cache; subsequent runs are offline.
- Speed: ~real-time-×30 ASR, diarization is the bottleneck (~10 min for 2 h).
- Attribution is probabilistic — speakers with the least dialogue and no `anchor`
  are the likeliest misattributions; add an anchor for anyone who matters.
- Video files work (ffmpeg pulls the audio track).
