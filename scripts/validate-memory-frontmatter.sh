#!/usr/bin/env bash
# validate-memory-frontmatter.sh — THE canonical memory-frontmatter schema (CLI).
#
# The schema RULES now live in memory_frontmatter.py (this dir) as the single
# definition; this script is the CLI front-end over `mf.schema_reasons`. Everything
# else REFERENCES that one module instead of restating the rule:
#   - /consolidate SKILL.md step 2a (the post-write gate) calls this script.
#   - scripts/normalize-memory-frontmatter.sh + scripts/heal-memory-dir.sh import
#     the same module, so a validate / normalize / heal verdict cannot disagree.
# Before the module existed these sites each stated the schema independently and
# DRIFTED (the metadata.type three-way divergence that drove PR #68). One executable
# definition can't drift from itself — that is the whole point (issue #883).
#
# THE SCHEMA (described in memory_frontmatter.py; the CODE there is authoritative):
#     ---
#     name: <non-empty string>
#     description: <non-empty string>
#     metadata:
#       type: <non-empty string>         # OPEN tag — no enum
#       scope: repo | universal | meta   # CLOSED enum
#     ---
#   Rules A-F: top-level keys ⊆ {name,description,metadata}; metadata keys ⊆ {type,scope};
#   name+description non-empty; metadata.type non-empty; metadata.scope in the enum;
#   the block parses as a YAML mapping.
#
# SKIPS (out of schema scope, exit-0-clean, never flagged):
#   - index files ONLY: MEMORY.md and MEMORY.*.md (no frontmatter by design).
#   When you HAND this validator a file, it validates that file — filtering non-memory
#   artifacts (claude-md-candidates.md, notes) by prefix is the GLOBBER's job, done in
#   heal-memory-dir.sh, NOT here. (issue #936 is fixed at the sweep layer; the per-file
#   contract — flag any schema-violating file you're given — is the executable spec the
#   validate bats suite pins, and must not be loosened by a name filter.)
#
# Usage:
#   validate-memory-frontmatter.sh <file> [<file> ...]
# Exit 0 iff EVERY non-skipped file passes; exit 1 (and print one `INVALID <name>: <why>`
# line per offender) if any fail; exit 2 on a usage error / missing PyYAML.
set -euo pipefail

# Resolve this script's real dir (following a symlink install) to import the module.
SRC="${BASH_SOURCE[0]}"
while [ -L "$SRC" ]; do
  DIR="$(cd "$(dirname "$SRC")" && pwd)"; SRC="$(readlink "$SRC")"
  [ "${SRC#/}" = "$SRC" ] && SRC="$DIR/$SRC"
done
HERE="$(cd "$(dirname "$SRC")" && pwd)"

if [ "$#" -lt 1 ]; then
  echo "usage: validate-memory-frontmatter.sh <file> [<file> ...]" >&2
  exit 2
fi

PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" python3 - "$@" <<'PY'
import sys, os

try:
    import memory_frontmatter as mf
except ImportError as e:
    sys.stderr.write(f"ERROR: cannot import memory_frontmatter ({e}); run install-symlinks.sh\n")
    sys.exit(2)

try:
    import yaml  # noqa: F401
except ImportError:
    sys.stderr.write("ERROR: PyYAML required (pip install pyyaml)\n")
    sys.exit(2)

bad = []  # (path, reason)

for f in sys.argv[1:]:
    base = os.path.basename(f)
    # Skip ONLY index files (no frontmatter by design). Prefix-filtering of non-memory
    # artifacts is the globber's job (heal-memory-dir.sh), not this per-file gate.
    if mf.is_index_file(base):
        continue
    try:
        text = open(f, encoding="utf-8").read()
    except OSError as e:
        bad.append((f, f"unreadable: {e}")); continue
    reasons = mf.schema_reasons(text)
    if reasons:
        bad.append((f, "; ".join(reasons)))

for f, why in bad:
    print(f"INVALID {os.path.basename(f)}: {why}")

sys.exit(1 if bad else 0)
PY
