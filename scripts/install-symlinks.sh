#!/usr/bin/env bash
# install-symlinks.sh — idempotent post-merge symlink setup.
#
# Some files in ~/.claude/ are intentionally symlinks back into this repo so
# that edits flow through git review rather than silently drifting on a single
# machine. On a fresh clone a hand-created local copy would silently go stale,
# exactly the failure mode this script exists to prevent.
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
# The canonical memory-frontmatter schema. /consolidate's memory-writer runs in
# arbitrary repos and reaches it by this stable path (the repo path is unknown
# from another project's session); SKILL.md step 2a calls it as the post-write gate.
link "$HOME/.claude/scripts/validate-memory-frontmatter.sh" "$REPO_ROOT/scripts/validate-memory-frontmatter.sh"
# The canonical /consolidate scorecard schema — sibling of the above. memory-writer
# (and the Wrap-up gate) reach it by this stable path from any repo's session;
# SKILL.md step 4 calls it after writing scorecard.json so a drifted scorecard
# (which silently breaks the next-session readtime grader) fails loudly instead.
link "$HOME/.claude/scripts/validate-scorecard.sh" "$REPO_ROOT/scripts/validate-scorecard.sh"
# The /consolidate immune response (task #4) — proactive health check the Wrap-up
# step runs to self-report a threshold breach (scorecard noise, directive-layer
# over budget, agent-phase wall-clock drift) instead of waiting for Nick to notice.
# Reached by this stable path from any repo's session.
link "$HOME/.claude/scripts/consolidate-health-check.sh" "$REPO_ROOT/scripts/consolidate-health-check.sh"
# The shared frontmatter module — THE single definition of the schema + preserve-first
# repair. validate / normalize / heal all import it (so their verdicts can't drift —
# issue #883). Linked alongside them so the import resolves whether a tool is invoked
# via its symlink (which resolves back to the repo) or copied.
link "$HOME/.claude/scripts/memory_frontmatter.py" "$REPO_ROOT/scripts/memory_frontmatter.py"
# The single-file normalizer (bulk / manual repair) and the one-pass dir healer that
# /consolidate step 0 calls. Both reached by this stable path from any repo's session.
link "$HOME/.claude/scripts/normalize-memory-frontmatter.sh" "$REPO_ROOT/scripts/normalize-memory-frontmatter.sh"
link "$HOME/.claude/scripts/heal-memory-dir.sh" "$REPO_ROOT/scripts/heal-memory-dir.sh"
# The GitHub App token minter — cage-match / ship / pr-review / review-respond /
# ship-major-feature call it by this stable path to mint Maxwell/Kelvin/Carnot
# installation tokens for the review+merge gate. Moved here from the legacy
# ~/.claude-skills/github-app-token.sh location (2026-06-19) so all script entry
# points live under ~/.claude/scripts and the ~/.claude-skills dir can be retired
# (its secrets moved to ~/.claude/.env).
link "$HOME/.claude/scripts/github-app-token.sh" "$REPO_ROOT/scripts/github-app-token.sh"
