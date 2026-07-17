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

### Re-attribute (fix names without re-transcribing)

After a first pass you've READ the transcript — so you can add **ground-truth
`anchor` lines** (one verbatim-ish line you KNOW each speaker said: a
self-introduction, a host's opener, the expert's distinctive technical line) and
re-run JUST the attribution + build steps against the existing `turns.json`:

```bash
bash ~/.claude/skills/transcribe/scripts/run.sh --reattribute <workdir> <speakers.json>
```

This skips the slow diarize/transcribe steps (~60–90s, not the full pipeline).
Anchors are the single biggest accuracy lever — strictly better than the first
pass, which had none to seed from. Use this when a misattribution slips through,
or to upgrade a profile-only first pass. (Attribution self-heals failed chunks by
recursive split, so wholesale anonymous blocks are now rare — but anchors still
beat profiles for same-gender / low-dialogue speakers.)

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
- `vocabulary` (optional but HIGH VALUE): proper nouns and domain terms likely to be
  spoken — project names, product names, people, jargon. The ASR is blind to
  out-of-vocabulary words and renders them as phonetically-similar English, often
  inconsistently (a real call rendered "aiko" as archo/archa/icoservices). The
  attribution pass corrects garbled words to these exact spellings.

### Rosters + vocabulary mining (instruction to the invoking agent — DO THIS EVERY RUN)

1. **Check `rosters/` FIRST.** `~/.claude/skills/transcribe/rosters/*.json` holds
   standing cast configs for recurring calls (e.g. `aiko.json` for Nick+Andy aiko
   calls, `makelabs.json`). If one matches the recording's likely context, use it
   as the speakers.json (copy it into the work dir; tweak title/num_speakers
   per-recording). Rosters carry a `glossary` — the accumulated correct spellings
   of every term the ASR has ever garbled for that crew.
2. **No matching roster?** Spend 60 seconds assembling `vocabulary` from what you
   already know: the project's `MEMORY.md`/memory dir, repo and package names in
   the working directory, people in the session context, the user's own words when
   asking. Write a speakers.json even when speaker names are unknown — the LLM
   pass then runs with anonymous cluster labels but still corrects vocabulary.
   (No speakers.json → no LLM pass → no correction.)
3. **Close the growth loop AFTER the run.** Skim the output for garbled proper
   nouns (the tell: one unknown word rendered as several different
   plausible-English spellings). Fix the transcript, then append the CORRECT
   spellings to the matching roster's `glossary` (or create a roster if this crew
   will recur). Each mishearing should ever be caught only once.

`vocabulary` (per-recording speakers.json) and `glossary` (standing roster) are
the same thing to the pipeline — either key works. Entries are plain strings, or
`{"term": "OpenSpec", "url": "https://github.com/Fission-AI/OpenSpec"}` objects:
url-bearing terms become hyperlinks in transcript.html (first occurrence per term,
plus a References section at the bottom).

**Unknown terms → focused web search.** When a garble can't be resolved from
memory/context (you can hear the shape but don't know the thing — "open spec?",
"gips tech?"), run ONE focused web search to pin the canonical spelling AND grab
its canonical URL while you're there; store both in the glossary as a url-bearing
entry. Never guess a spelling into a roster — a wrong "correction" propagates to
every future transcript.

## Pipeline (what run.sh does)

1. **Condition audio** — ffmpeg loudness-normalise (EBU R128) + 70 Hz high-pass → 16 kHz mono WAV. Lifts quiet speakers.
2. **Diarize** — `pyannote/speaker-diarization-community-1`, pinned to `num_speakers` if provided (`diarize.py`).
3. **Transcribe** — `parakeet-tdt-1.1b` with word-level timestamps.
4. **Fuse + clean** — assign each WORD to its speaker turn by midpoint, split on >0.6s silence gaps, strip fillers (um/uh/…) and immediate word-repeats (`wordmerge.py` + `clean_text.py`).
5. **Attribute** *(only if speakers.json)* — headless Claude labels each turn by speech pattern + flow, anchored on the ground-truth lines, split-aware, with light ASR fixups (`attribute.py`). Tools/MCP disabled so calls don't hang.
6. **Build** — `build_outputs.py` → html/txt/srt; auto-discovers however many speakers, stable colour per name.

## Keeping it fresh

Every full run starts with an advisory update check (`check_updates.sh`): installed
`uv` tool versions vs PyPI (parakeet-mlx, pyannote-audio), cached HF model revisions
vs the hub (parakeet-tdt-1.1b, speaker-diarization-community-1), and ffmpeg vs brew.
It prints upgrade commands but never blocks or fails the run (offline → skipped).

- Standalone: `bash ~/.claude/skills/transcribe/scripts/run.sh --check-updates`
- Skip it: `TRANSCRIBE_SKIP_UPDATE_CHECK=1`
- Don't upgrade the uv tools while a transcription is mid-run — the pipeline is
  executing out of those tool venvs.

## Notes / failure modes

- First run downloads the models (~2 GB) into the HF cache; subsequent runs are offline.
- Speed: ~real-time-×30 ASR, diarization is the bottleneck (~10 min for 2 h).
- Attribution is probabilistic — speakers with the least dialogue and no `anchor`
  are the likeliest misattributions; add an anchor for anyone who matters.
- Video files work (ffmpeg pulls the audio track).
- The recording date is stamped into the title automatically (embedded
  `creation_time` metadata, else file mtime) unless the title already contains a year.
