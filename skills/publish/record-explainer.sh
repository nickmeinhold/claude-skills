#!/usr/bin/env bash
#
# record-explainer.sh — capture a screen + webcam-PiP + mic "explaining the work"
# video on macOS via ffmpeg/AVFoundation. Output is a web-ready 1080p H.264 mp4
# with faststart, ready to transcribe (→ source the post) and self-host.
#
# INTERACTIVE: this must be run by Nick at the keyboard (start talking, then
# press `q` to stop). From a Claude session, suggest running it with the
# `! <command>` prefix so the recording happens in the real TTY.
#
# One-time macOS setup (System Settings → Privacy & Security):
#   • Screen & System Audio Recording → enable your terminal app
#   • Camera → enable your terminal app
#   • Microphone → enable your terminal app
# Without these, ffmpeg silently captures black frames / no audio.
#
# Usage:
#   ./record-explainer.sh --devices              # list AVFoundation devices + exit
#   ./record-explainer.sh [out.mp4]              # record (auto-detect devices)
#   AVF_SCREEN=3 AVF_CAM=0 AVF_MIC=0 ./record-explainer.sh out.mp4   # explicit
#
# Device indices differ per machine — run --devices once, then export the three
# AVF_* vars (or pass them inline) so future runs skip auto-detect.

set -euo pipefail

command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

list_devices() {
  echo "── AVFoundation devices (video then audio) ─────────────────────"
  # AVFoundation prints the device list to stderr and then errors (no real
  # input) — that non-zero exit is expected, so don't let set -e kill us.
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | \
    grep -E '\[AVFoundation|\[[0-9]+\]' || true
  echo "────────────────────────────────────────────────────────────────"
}

if [[ "${1:-}" == "--devices" ]]; then
  list_devices
  echo "Set AVF_SCREEN / AVF_CAM / AVF_MIC to the bracketed indices above."
  exit 0
fi

OUT="${1:-explainer-$(date +%Y%m%d-%H%M%S).mp4}"

# ── auto-detect device indices if not provided ──────────────────────────
DEV_LIST="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 || true)"
pick() { # $1 = regex over the device label → prints the matching [index]
  echo "$DEV_LIST" | grep -iE "\] .*($1)" | head -1 | sed -E 's/.*\[([0-9]+)\].*/\1/'
}

SCREEN="${AVF_SCREEN:-$(pick 'capture screen 0')}"
CAM="${AVF_CAM:-$(pick 'facetime|camera|webcam')}"
MIC="${AVF_MIC:-$(pick 'microphone|mic|built-in')}"

if [[ -z "${SCREEN}" || -z "${CAM}" || -z "${MIC}" ]]; then
  echo "Could not auto-detect all devices (screen='${SCREEN}' cam='${CAM}' mic='${MIC}')."
  list_devices
  echo "Re-run with explicit indices, e.g.:  AVF_SCREEN=3 AVF_CAM=0 AVF_MIC=0 $0 ${OUT}"
  exit 1
fi

echo "Recording  screen=[${SCREEN}]  cam=[${CAM}]  mic=[${MIC}]  →  ${OUT}"
echo "Talk through the work. Press  q  (then Enter) to stop."
echo

# Screen (main video) + mic (audio) come from one AVFoundation input; the webcam
# is a second video input, scaled to a 320px-wide bubble and overlaid bottom-
# right with a 24px margin. Whole composite is capped at 1080p to keep the file
# small; H.264 + yuv420p + faststart = plays everywhere and streams on the web.
ffmpeg -y \
  -f avfoundation -capture_cursor 1 -framerate 30 -i "${SCREEN}:${MIC}" \
  -f avfoundation -framerate 30 -i "${CAM}:none" \
  -filter_complex "\
    [0:v]scale='min(1920,iw)':-2[scr];\
    [1:v]scale=320:-1[cam];\
    [scr][cam]overlay=W-w-24:H-h-24[v]" \
  -map "[v]" -map 0:a \
  -c:v libx264 -preset veryfast -crf 21 -pix_fmt yuv420p -movflags +faststart \
  -c:a aac -b:a 128k \
  "${OUT}"

echo
echo "Saved ${OUT}  ($(du -h "${OUT}" | cut -f1))"
echo "Next: /transcribe ${OUT}  →  draft the post from the transcript."
