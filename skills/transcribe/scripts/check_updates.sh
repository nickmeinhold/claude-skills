#!/usr/bin/env bash
# check_updates.sh — advisory freshness check for everything the transcribe skill uses.
# Never fails the run: offline / timeout / missing tool all degrade to a note.
# Standalone:  bash check_updates.sh
# From run.sh: sourced automatically before a full pass (skip with TRANSCRIBE_SKIP_UPDATE_CHECK=1)
set -uo pipefail

CURL="curl -fsS -m 5"
updates=0

note()   { printf '  %s\n' "$1"; }
stale()  { printf '  \033[33m%s\033[0m\n' "$1"; updates=$((updates+1)); }

echo "[update check]"

# --- uv tools (PyPI) ---------------------------------------------------------
for pkg in parakeet-mlx pyannote-audio; do
  installed="$(uv tool list 2>/dev/null | awk -v p="$pkg" '$1==p {gsub(/^v/,"",$2); print $2}')"
  latest="$($CURL "https://pypi.org/pypi/$pkg/json" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])' 2>/dev/null)"
  if [ -z "$installed" ]; then
    note "$pkg: not installed as a uv tool?"
  elif [ -z "$latest" ]; then
    note "$pkg: $installed installed (PyPI unreachable, skipped)"
  elif [ "$installed" = "$latest" ]; then
    note "$pkg: $installed (latest)"
  else
    stale "$pkg: $installed installed, $latest on PyPI -> uv tool upgrade $pkg"
  fi
done

# --- Hugging Face models (compare cached ref sha vs remote main) -------------
for repo in mlx-community/parakeet-tdt-1.1b pyannote/speaker-diarization-community-1; do
  cache_dir="$HOME/.cache/huggingface/hub/models--${repo//\//--}"
  local_sha="$(cat "$cache_dir/refs/main" 2>/dev/null)"
  remote_sha="$($CURL "https://huggingface.co/api/models/$repo" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null)"
  if [ -z "$local_sha" ]; then
    note "$repo: not cached yet (first run will download it)"
  elif [ -z "$remote_sha" ]; then
    note "$repo: cached (HF API unreachable, skipped)"
  elif [ "$local_sha" = "$remote_sha" ]; then
    note "$repo: cached revision is latest"
  else
    stale "$repo: newer revision on HF -> hf download $repo (or delete $cache_dir to refetch)"
  fi
done

# --- ffmpeg (Homebrew) --------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  if out="$(brew outdated ffmpeg 2>/dev/null)" && [ -n "$out" ]; then
    stale "ffmpeg: outdated ($out) -> brew upgrade ffmpeg"
  else
    note "ffmpeg: $(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}') (latest per brew)"
  fi
fi

if [ "$updates" -gt 0 ]; then
  echo "  -> $updates update(s) available (advisory only; run continues)"
else
  echo "  all up to date"
fi
exit 0
