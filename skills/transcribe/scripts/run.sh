#!/usr/bin/env bash
# transcribe — orchestrate local speaker-attributed transcription.
# Usage: run.sh <audio-or-video-file> [speakers.json]
#        run.sh --reattribute <workdir> <speakers.json>   # re-run name attribution only
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAKEET_PY="$HOME/.local/share/uv/tools/parakeet-mlx/bin/python"   # stdlib + json
PYANNOTE_PY="$HOME/.local/share/uv/tools/pyannote-audio/bin/python" # torch + pyannote
PARAKEET="$HOME/.local/bin/parakeet-mlx"

# --reattribute: redo identity attribution + outputs against an EXISTING work dir
# (reuses turns.json — skips the slow diarize/transcribe steps). Use after editing
# speakers.json to add ground-truth `anchor` lines drawn from a first-pass transcript.
if [ "${1:-}" = "--reattribute" ]; then
  WORK="${2:?usage: run.sh --reattribute <workdir> <speakers.json>}"
  CONFIG="${3:?usage: run.sh --reattribute <workdir> <speakers.json>}"
  [ -f "$WORK/turns.json" ] || { echo "no turns.json in $WORK (run a full pass first)" >&2; exit 1; }
  [ -f "$CONFIG" ] || { echo "no such config: $CONFIG" >&2; exit 1; }
  export TRANSCRIBE_WORK="$WORK"
  export TRANSCRIBE_CONFIG="$CONFIG"
  export TRANSCRIBE_TITLE="${TRANSCRIBE_TITLE:-$("$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title") or "")' "$CONFIG")}"
  echo "[re-attribute] LLM identity attribution on $WORK"
  "$PARAKEET_PY" "$DIR/attribute.py"
  echo "[re-attribute] building outputs"
  "$PARAKEET_PY" "$DIR/build_outputs.py"
  echo "Done -> $WORK/transcript.html"
  command -v open >/dev/null && open "$WORK/transcript.html" || true
  exit 0
fi

AUDIO="${1:?usage: run.sh <audio-or-video-file> [speakers.json]}"
CONFIG="${2:-}"
[ -f "$AUDIO" ] || { echo "no such file: $AUDIO" >&2; exit 1; }
[ -n "$CONFIG" ] && [ ! -f "$CONFIG" ] && { echo "no such config: $CONFIG" >&2; exit 1; }

base="$(basename "${AUDIO%.*}")"
# Default work dir under ~/git (NOT ~/Downloads — macOS TCC). Override via env.
WORK="${TRANSCRIBE_WORK:-$HOME/git/transcribe-$base}"
mkdir -p "$WORK"
export TRANSCRIBE_WORK="$WORK"
export TRANSCRIBE_CONFIG="$CONFIG"

# Title: explicit env > config.title > filename
TITLE="${TRANSCRIBE_TITLE:-}"
if [ -z "$TITLE" ] && [ -n "$CONFIG" ]; then
  TITLE="$("$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title") or "")' "$CONFIG")"
fi
export TRANSCRIBE_TITLE="${TITLE:-$base}"

NUM=""
if [ -n "$CONFIG" ]; then
  NUM="$("$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("num_speakers") or "")' "$CONFIG")"
fi
export TRANSCRIBE_NUM_SPEAKERS="$NUM"

echo "[1/6] conditioning audio -> $WORK/audio.wav"
ffmpeg -y -loglevel error -i "$AUDIO" \
  -af "highpass=f=70,loudnorm=I=-16:TP=-1.5:LRA=11" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/audio.wav"

echo "[2/6] diarizing (num_speakers=${NUM:-auto})"
"$PYANNOTE_PY" "$DIR/diarize.py"

echo "[3/6] transcribing (parakeet-tdt-1.1b)"
"$PARAKEET" "$WORK/audio.wav" --model mlx-community/parakeet-tdt-1.1b \
  --output-format json --output-dir "$WORK" >/dev/null

echo "[4/6] word-level fusion + cleanup"
"$PARAKEET_PY" "$DIR/wordmerge.py"

if [ -n "$CONFIG" ]; then
  echo "[5/6] LLM identity attribution (headless Claude)"
  "$PARAKEET_PY" "$DIR/attribute.py"
else
  echo "[5/6] no speakers.json -> anonymous speakers (skipping attribution)"
fi

echo "[6/6] building outputs"
"$PARAKEET_PY" "$DIR/build_outputs.py"

echo "Done -> $WORK/transcript.html"
command -v open >/dev/null && open "$WORK/transcript.html" || true
