#!/usr/bin/env bash
# normalize-memory-frontmatter.sh — regularize ONE memory file's frontmatter to the
# canonical YAML block. CLI front-end over memory_frontmatter.py (this dir) — the same
# module validate-memory-frontmatter.sh and heal-memory-dir.sh use, so normalize can't
# drift from the schema it repairs toward (issue #883, dir-id 9b3d).
#
# Canonical target:
#   ---
#   name: <human-readable title>
#   description: <one-line retrieval cue>
#   metadata:
#     type: <filename prefix — an OPEN descriptive tag; an existing type is PRESERVED,
#           an absent one is DERIVED as the prefix>
#     scope: repo | universal | meta
#   ---
#
# DESIGN — preserve-first, not generate-first (issue #859; logic now in the module):
#   - PREFIX accepted via a map covering the whole corpus (typo / non-memory-file GATE).
#   - TYPE preserve-first: an existing non-empty metadata.type kept verbatim; absent ->
#     derived as the prefix. No tool branches on the value (it is an OPEN tag).
#   - SCOPE read then default: existing universal/meta never downgraded; absent/invalid
#     -> repo. A bulk run never PROMOTES (can't invent universal/meta) — that stays the
#     graduation pipeline's job.
#   - name + description PRESERVED verbatim. The headless-`claude` fill fires ONLY when a
#     field is genuinely missing/empty — zero LLM calls on a clean corpus.
#   - body preserved BYTE-FOR-BYTE (an unfenced file gets one synthesized blank line).
#   - apply-time the rebuilt block is certified against the SAME schema (mf.schema_reasons,
#     in-process) before the atomic temp is mv'd into place; a rejected rebuild is
#     discarded and the original never replaced.
#
# Usage:
#   normalize-memory-frontmatter.sh <file>            # DRY RUN: print proposed frontmatter
#   normalize-memory-frontmatter.sh --apply <file>    # rewrite the file in place
#
# Exit 0 on success; non-zero (and no write) on failure, so a driver can skip:
#   1 = bad args / no file / unknown prefix
#   2 = a field is missing AND the LLM fallback could not fill it
#   3 = the rebuilt frontmatter is INVALID per the canonical schema (temp discarded)
#   4 = reserved (toolchain failure: missing PyYAML)
set -euo pipefail

# Resolve this script's real dir (following a symlink install) to import the module.
SRC="${BASH_SOURCE[0]}"
while [ -L "$SRC" ]; do
  DIR="$(cd "$(dirname "$SRC")" && pwd)"; SRC="$(readlink "$SRC")"
  [ "${SRC#/}" = "$SRC" ] && SRC="$DIR/$SRC"
done
HERE="$(cd "$(dirname "$SRC")" && pwd)"

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; shift; fi
FILE="${1:?usage: normalize-memory-frontmatter.sh [--apply] <file>}"
[ -f "$FILE" ] || { echo "ERROR: no such file: $FILE" >&2; exit 1; }

PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" APPLY="$APPLY" python3 - "$FILE" <<'PY'
import sys, os

try:
    import memory_frontmatter as mf
except ImportError as e:
    sys.stderr.write(f"ERROR: cannot import memory_frontmatter ({e}); run install-symlinks.sh\n")
    sys.exit(4)

try:
    import yaml  # noqa: F401
except ImportError:
    sys.stderr.write("ERROR: PyYAML required (pip install pyyaml)\n")
    sys.exit(4)

FILE = sys.argv[1]
APPLY = os.environ.get("APPLY", "0") == "1"

try:
    if not APPLY:
        # DRY RUN: compute and print the canonical frontmatter block, no write.
        result = mf.compute_canonical(FILE)
        new_fm = result.split("\n---", 1)[0] + "\n---"  # the leading ---fenced block
        print(f"### {FILE}")
        print(new_fm)
        sys.exit(0)
    # skip_if_valid=False: always run the prefix gate, so an unknown-prefix file exits 1
    # and writes nothing even if it is otherwise schema-valid (the documented contract).
    mf.apply_canonical(FILE, skip_if_valid=False)
    print(f"normalized: {FILE}")
    sys.exit(0)
except mf.RepairError as e:
    sys.stderr.write(f"ERROR: {e}\n")
    sys.exit(e.code)
PY
