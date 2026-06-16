#!/usr/bin/env bash
# normalize-memory-frontmatter.sh — regularize a memory file's frontmatter to
# the canonical YAML block the /consolidate memory-writer and the self-maintaining
# tooling (write-suppression #739, eviction #740) parse with a YAML reader.
#
# Canonical target:
#   ---
#   name: <human-readable title>
#   description: <one-line retrieval cue>
#   metadata:
#     type: feedback | concept
#     scope: repo | universal | meta
#   ---
#
# Handles two drift shapes found in the corpus (2026-06-16 survey):
#   1. UNFENCED  — file opens straight into `# Title`, no frontmatter at all.
#   2. DEGENERATE — a `---` block with `name: ""`, no description/type/scope, and
#      forbidden provenance fields (originSessionId / node_type — see PR #57).
#
# type  = from filename prefix (feedback_ / concept_), mechanical.
# scope = HARDCODED `repo`. A bulk format sweep must not make promotion judgments:
#   letting the model assign universal/meta manufactures spurious graduation
#   candidates (observed in the 2026-06-16 dry-run — a GitHub-mute technique got
#   tagged `meta`). Promotion is the graduation pipeline's job on a genuine future
#   recurrence, never a side effect of reformatting. The sweep regularizes FORMAT.
# name + description = one headless-Claude read per file (zero marginal cost on
#   Nick's Max plan; --output-format text). name is model-generated because the
#   drifted files have no usable name (empty name:"" or a `# filename`-as-heading).
#
# Usage:
#   normalize-memory-frontmatter.sh <file>            # DRY RUN: print proposed frontmatter to stdout
#   normalize-memory-frontmatter.sh --apply <file>    # rewrite the file in place
#
# Exit 0 on success; non-zero (and no write) on any failure, so a driver can skip.
set -euo pipefail

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
FILE="${1:?usage: normalize-memory-frontmatter.sh [--apply] <file>}"
[ -f "$FILE" ] || { echo "ERROR: no such file: $FILE" >&2; exit 1; }

base="$(basename "$FILE")"
case "$base" in
  feedback_*) TYPE=feedback ;;
  concept_*)  TYPE=concept ;;
  *) echo "ERROR: unexpected prefix (want feedback_/concept_): $base" >&2; exit 1 ;;
esac

# --- Split existing frontmatter (if any) from the body ----------------------
first_line="$(head -1 "$FILE")"
if [ "$first_line" = "---" ]; then
  # Degenerate-fenced: body is everything after the second '---'.
  body="$(awk 'f>=2{print} /^---[[:space:]]*$/{f++}' "$FILE")"
  existing_name="$(awk 'NR>1 && /^---/{exit} /^name:/{sub(/^name:[[:space:]]*/,""); gsub(/^"|"$/,""); print}' "$FILE")"
else
  body="$(cat "$FILE")"
  existing_name=""
fi

# Mechanical name fallbacks (used only if the model omits NAME): a real `# Title`
# heading that isn't just the filename-as-heading, else the existing name:, else
# the de-slugged filename.
slug="$(printf '%s' "$base" | sed -E 's/^(feedback|concept)_//; s/\.md$//')"
title="$(printf '%s\n' "$body" | grep -m1 -E '^#[[:space:]]+' | sed -E 's/^#+[[:space:]]*//' || true)"
title_slug="$(printf '%s' "$title" | tr '[:upper:] ' '[:lower:]_')"
if [ -n "$title" ] && [ "$title_slug" != "$slug" ] && [ "$title" != "$base" ]; then
  FALLBACK_NAME="$title"                       # a genuine human title
elif [ -n "$existing_name" ]; then
  FALLBACK_NAME="$existing_name"
else
  FALLBACK_NAME="$(printf '%s' "$slug" | sed -E 's/_/ /g')"
fi

# scope is HARDCODED — the sweep regularizes format, it does not promote.
SCOPE=repo

# --- name + description: one headless-Claude read --------------------------
PROMPT="You are normalizing a memory file's frontmatter. Read the file content below and output EXACTLY two lines, nothing else, no preamble, no markdown, no code fence:
NAME: <a short human-readable title under 60 chars. Reuse the file's existing top '# heading' if it is a real title; do NOT output the bare filename or slug. No surrounding quotes.>
DESCRIPTION: <one sentence under 160 chars naming the SITUATION this memory is retrieved for — the trigger/cue, not a restatement of the title. No surrounding quotes.>

File content:
$body"

RAW="$(printf '%s' "$PROMPT" | claude -p --output-format text 2>/dev/null || true)"
NAME="$(printf '%s\n' "$RAW" | grep -m1 -E '^NAME:' | sed -E 's/^NAME:[[:space:]]*//; s/^"//; s/"$//' || true)"
DESCRIPTION="$(printf '%s\n' "$RAW" | grep -m1 -E '^DESCRIPTION:' | sed -E 's/^DESCRIPTION:[[:space:]]*//; s/^"//; s/"$//' || true)"

# A model NAME equal to the bare slug/filename is junk — fall back.
if [ -z "$NAME" ] || [ "$NAME" = "$slug" ] || [ "$NAME" = "$base" ]; then NAME="$FALLBACK_NAME"; fi
# Refuse to write garbage.
[ -n "$DESCRIPTION" ] || { echo "ERROR: empty DESCRIPTION from model for $FILE" >&2; exit 2; }
[ -n "$NAME" ] || { echo "ERROR: empty NAME (and no fallback) for $FILE" >&2; exit 2; }

# --- emit canonical frontmatter --------------------------------------------
# Quote name/description defensively (they may contain ':' which breaks bare YAML).
yaml_escape() { printf '%s' "$1" | sed -E 's/\\/\\\\/g; s/"/\\"/g'; }
NEW_FM="$(cat <<EOF
---
name: "$(yaml_escape "$NAME")"
description: "$(yaml_escape "$DESCRIPTION")"
metadata:
  type: $TYPE
  scope: $SCOPE
---
EOF
)"

if [ "$APPLY" -eq 0 ]; then
  echo "### $FILE  [type=$TYPE]"
  printf '%s\n' "$NEW_FM"
  exit 0
fi

# Apply: new frontmatter + blank line + body. Write atomically via temp file.
tmp="$(mktemp)"
{ printf '%s\n\n' "$NEW_FM"; printf '%s\n' "$body"; } > "$tmp"

# Verify the result's frontmatter parses as YAML before replacing the original.
python3 - "$tmp" <<'PY' || { echo "ERROR: result frontmatter failed yaml.safe_load: $FILE" >&2; rm -f "$tmp"; exit 3; }
import sys, yaml
txt = open(sys.argv[1]).read()
assert txt.startswith('---\n'), "no opening fence"
fm = txt.split('---\n', 2)[1]
d = yaml.safe_load(fm)
for k in ('name', 'description'):
    assert d.get(k), f"missing/empty {k}"
assert d.get('metadata', {}).get('type'), "missing metadata.type"
assert d.get('metadata', {}).get('scope') in ('repo','universal','meta'), "bad scope"
PY

mv "$tmp" "$FILE"
echo "normalized: $FILE  [type=$TYPE scope=$SCOPE]"
