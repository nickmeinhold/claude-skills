#!/usr/bin/env bash
# install-symlinks.sh — idempotent post-merge symlink setup.
#
# Some files in ~/.claude/ are intentionally symlinks back into this repo so
# that edits flow through git review rather than silently drifting on a single
# machine. After PR #24 (eval-tally consolidation), the symlink at
# ~/.claude/persona-eval/eval-tally.sh was created manually — fine on the
# machine where the merge happened, but on a fresh clone the local file would
# silently go stale, exactly the failure mode PR #24 exists to prevent.
#
# This script makes that setup reproducible. It's safe to re-run: existing
# correct symlinks are left alone, and regular files won't be clobbered
# without --force (which moves the existing file aside to .bak).
#
# Usage:
#   bash scripts/install-symlinks.sh           # idempotent install
#   bash scripts/install-symlinks.sh --force   # replace conflicting files (.bak)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# link <target> <source>
#   target: absolute path where the symlink should live (may contain ~)
#   source: absolute path inside the repo that target should point to
# Move an existing file/symlink aside to a non-clobbering backup path.
# Picks the first available `.bak`, `.bak.1`, `.bak.2`, ... so repeated
# --force runs don't lose previous backups.
move_aside() {
  local path="$1" backup="$1.bak" n=1
  while [[ -e "$backup" || -L "$backup" ]]; do
    backup="$1.bak.$n"
    n=$((n + 1))
  done
  mv "$path" "$backup"
  echo "$backup"
}

link() {
  local target source target_expanded parent
  target="$1"
  source="$2"
  # expand leading ~ without invoking eval
  target_expanded="${target/#\~/$HOME}"
  parent="$(dirname "$target_expanded")"

  # Refuse to install a dangling symlink — the whole point of this script is
  # preventing silently-stale local state, which a broken symlink would be.
  if [[ ! -e "$source" ]]; then
    echo "✗ source missing: $source" >&2
    echo "  refusing to create a dangling symlink at $target" >&2
    return 1
  fi

  mkdir -p "$parent"

  if [[ -L "$target_expanded" ]]; then
    local current
    current="$(readlink "$target_expanded")"
    if [[ "$current" == "$source" ]]; then
      echo "✓ $target (already linked)"
      return 0
    fi
    if [[ "$FORCE" -eq 1 ]]; then
      local moved
      moved="$(move_aside "$target_expanded")"
      echo "  moved stale symlink -> $moved"
    else
      echo "✗ $target is a symlink to '$current' (expected '$source')" >&2
      echo "  re-run with --force to replace (existing file moved aside)" >&2
      return 1
    fi
  elif [[ -e "$target_expanded" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      local moved
      moved="$(move_aside "$target_expanded")"
      echo "  moved existing file -> $moved"
    else
      echo "✗ $target exists (not a symlink to expected source)" >&2
      echo "  re-run with --force to replace (existing file moved aside)" >&2
      return 1
    fi
  fi

  ln -sfn "$source" "$target_expanded"
  echo "✓ $target -> $source"
}

# --- symlinks to install ----------------------------------------------------
# Add new entries here; one `link` call per symlink.
link "$HOME/.claude/persona-eval/eval-tally.sh" "$REPO_ROOT/scripts/eval-tally.sh"
