#!/usr/bin/env bash
# transcribe — orchestrate local speaker-attributed transcription.
# Usage: run.sh <audio-or-video-file> [speakers.json]
#        run.sh --reattribute <workdir> <speakers.json>   # re-run name attribution only
#        run.sh --repair <workdir> <speakers.json>        # re-run repair pass only
#        run.sh --review <workdir> <speakers.json>        # interactive review: OK applies + rebuilds
#        run.sh --apply <workdir> [speakers.json]         # apply approved corrections + rebuild
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAKEET_PY="$HOME/.local/share/uv/tools/parakeet-mlx/bin/python"   # stdlib + json
PYANNOTE_PY="$HOME/.local/share/uv/tools/pyannote-audio/bin/python" # torch + pyannote
PARAKEET="$HOME/.local/bin/parakeet-mlx"

# --check-updates: just report tool/model freshness and exit
if [ "${1:-}" = "--check-updates" ]; then
  bash "$DIR/check_updates.sh"
  exit 0
fi

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
  echo "[re-attribute] re-applying approved corrections (corrections.json)"
  "$PARAKEET_PY" "$DIR/apply_corrections.py"
  "$PARAKEET_PY" "$DIR/make_review.py"
  echo "[re-attribute] building outputs"
  "$PARAKEET_PY" "$DIR/build_outputs.py"
  echo "Done -> $WORK/transcript.html"
  command -v open >/dev/null && open "$WORK/transcript.html" || true
  exit 0
fi

# --repair: (re-)run the propose-only repair pass on an EXISTING work dir, then
# apply whatever is approved and rebuild. Proposals land in corrections.json as
# status=proposed with a human-readable repair_report.md.
if [ "${1:-}" = "--repair" ]; then
  WORK="${2:?usage: run.sh --repair <workdir> <speakers.json>}"
  CONFIG="${3:?usage: run.sh --repair <workdir> <speakers.json>}"
  [ -f "$WORK/turns_named.json" ] || [ -f "$WORK/turns.json" ] || { echo "no turns in $WORK" >&2; exit 1; }
  export TRANSCRIBE_WORK="$WORK" TRANSCRIBE_CONFIG="$CONFIG"
  export TRANSCRIBE_TITLE="${TRANSCRIBE_TITLE:-$("$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title") or "")' "$CONFIG")}"
  echo "[repair] LLM repair pass (propose-only)"
  "$PARAKEET_PY" "$DIR/repair.py"
  "$PARAKEET_PY" "$DIR/apply_corrections.py"
  "$PARAKEET_PY" "$DIR/make_review.py"
  "$PARAKEET_PY" "$DIR/build_outputs.py"
  echo "Done -> $WORK/transcript.html (review $WORK/repair_review.html)"
  command -v open >/dev/null && open "$WORK/repair_review.html" || true
  exit 0
fi

# --review: serve the review page from a local server so the OK button APPLIES
# approved proposals and rebuilds, no export/file dance. Blocks until the
# reviewer clicks the final OK (or ^C).
if [ "${1:-}" = "--review" ]; then
  WORK="${2:?usage: run.sh --review <workdir> <speakers.json>}"
  CONFIG="${3:-}"
  export TRANSCRIBE_WORK="$WORK" TRANSCRIBE_CONFIG="$CONFIG"
  export TRANSCRIBE_TITLE="${TRANSCRIBE_TITLE:-$([ -n "$CONFIG" ] && "$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title") or "")' "$CONFIG" || echo "")}"
  "$PARAKEET_PY" "$DIR/make_review.py"
  exec "$PARAKEET_PY" "$DIR/review_server.py"
fi

# --apply: apply approved corrections.json entries + rebuild (no LLM calls).
# Use after reviewing repair_report.md and flipping proposals to approved.
if [ "${1:-}" = "--apply" ]; then
  WORK="${2:?usage: run.sh --apply <workdir> [speakers.json]}"
  CONFIG="${3:-}"
  export TRANSCRIBE_WORK="$WORK" TRANSCRIBE_CONFIG="$CONFIG"
  export TRANSCRIBE_TITLE="${TRANSCRIBE_TITLE:-$([ -n "$CONFIG" ] && "$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("title") or "")' "$CONFIG" || echo "")}"
  "$PARAKEET_PY" "$DIR/apply_corrections.py"
  "$PARAKEET_PY" "$DIR/make_review.py"   # refresh: applied proposals leave the page
  "$PARAKEET_PY" "$DIR/build_outputs.py"
  echo "Done -> $WORK/transcript.html"
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
TITLE="${TITLE:-$base}"

# Stamp the recording date into the title: embedded creation_time tag (UTC ->
# local) if present, else the file's mtime. Skip if the title already has a year.
if ! printf '%s' "$TITLE" | grep -qE '(19|20)[0-9]{2}'; then
  ctime="$(ffprobe -v quiet -show_entries format_tags=creation_time -of default=nw=1:nk=1 "$AUDIO" 2>/dev/null | head -1)"
  if [ -n "$ctime" ]; then
    REC_DATE="$(python3 -c 'import sys,datetime as dt; print(dt.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")).astimezone().strftime("%-d %B %Y"))' "$ctime" 2>/dev/null || true)"
  else
    REC_DATE="$(stat -f '%Sm' -t '%-d %B %Y' "$AUDIO" 2>/dev/null || true)"
  fi
  [ -n "${REC_DATE:-}" ] && TITLE="$TITLE — $REC_DATE"
fi
export TRANSCRIBE_TITLE="$TITLE"

NUM=""
if [ -n "$CONFIG" ]; then
  NUM="$("$PARAKEET_PY" -c 'import json,sys;print(json.load(open(sys.argv[1])).get("num_speakers") or "")' "$CONFIG")"
fi
export TRANSCRIBE_NUM_SPEAKERS="$NUM"

# Advisory freshness check (never blocks; skip with TRANSCRIBE_SKIP_UPDATE_CHECK=1)
[ "${TRANSCRIBE_SKIP_UPDATE_CHECK:-}" = "1" ] || bash "$DIR/check_updates.sh" || true

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
  echo "[5/7] LLM identity attribution (headless Claude)"
  "$PARAKEET_PY" "$DIR/attribute.py"
else
  echo "[5/7] no speakers.json -> anonymous speakers (skipping attribution)"
fi

# Repair pass: propose-only hunt for residual garbles + ordinary-word slips
# (semantic absurdity, polarity flips, grammar artifacts) + edit suggestions.
# Proposals go to corrections.json/repair_report.md for human review — nothing
# is auto-applied. Skip with TRANSCRIBE_SKIP_REPAIR=1.
if [ -n "$CONFIG" ] && [ "${TRANSCRIBE_SKIP_REPAIR:-}" != "1" ]; then
  echo "[6/7] LLM repair pass (propose-only)"
  "$PARAKEET_PY" "$DIR/repair.py" || echo "  repair pass failed (non-fatal); continuing"
else
  echo "[6/7] repair pass skipped"
fi
"$PARAKEET_PY" "$DIR/apply_corrections.py"
"$PARAKEET_PY" "$DIR/make_review.py"

echo "[7/7] building outputs"
"$PARAKEET_PY" "$DIR/build_outputs.py"

echo "Done -> $WORK/transcript.html"
command -v open >/dev/null && open "$WORK/transcript.html" || true
