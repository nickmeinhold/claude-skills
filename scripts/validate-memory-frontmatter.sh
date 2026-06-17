#!/usr/bin/env bash
# validate-memory-frontmatter.sh — THE canonical memory-frontmatter schema.
#
# This script is the SINGLE SOURCE OF TRUTH for what a valid memory-file
# frontmatter block looks like. Everything else REFERENCES it instead of
# restating the rule:
#   - /consolidate SKILL.md step 2a (the post-write gate) calls this script.
#   - scripts/normalize-memory-frontmatter.sh calls this script as its
#     apply-time gate (it builds the block, then this validates the result).
#   - SKILL.md step 1 / step 0 prose point here for the authoritative rule.
# Before this script existed those sites each stated the schema independently
# and DRIFTED (the metadata.type three-way divergence that drove PR #68; the
# step-2a gate checked the key allowlist but not the scope enum, the normalizer
# checked the scope enum but not the key allowlist). One executable definition
# can't drift from itself — that is the whole point (issue #883).
#
# THE SCHEMA (exhaustive — this comment + the code below ARE the spec):
#   A memory file MUST open with a `---`-fenced YAML block parsing to a mapping:
#     ---
#     name: <non-empty string>           # human-readable title / retrieval handle
#     description: <non-empty string>    # one-line retrieval cue
#     metadata:
#       type: <non-empty string>         # OPEN descriptive tag (usually the filename
#                                        #   prefix). NO enum — no tool branches on it.
#       scope: repo | universal | meta   # CLOSED enum — graduation/eviction branch on it.
#     ---
#   Rules enforced:
#     (A) top-level keys ⊆ {name, description, metadata}      — no extra/provenance keys
#     (B) metadata keys  ⊆ {type, scope}                      — no extra/provenance keys
#     (C) name, description present and non-empty strings
#     (D) metadata.type present and non-empty                 — value NOT enum-checked (open tag)
#     (E) metadata.scope ∈ {repo, universal, meta}            — the one load-bearing enum
#     (F) the frontmatter parses as a YAML mapping at all     — unparseable == the silent-drop bug
#
# Usage:
#   validate-memory-frontmatter.sh <file> [<file> ...]
# Exit 0 iff EVERY file passes; exit 1 (and print one `INVALID <name>: <why>`
# line per offender) if any fail; exit 2 on a usage error / missing PyYAML.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: validate-memory-frontmatter.sh <file> [<file> ...]" >&2
  exit 2
fi

python3 - "$@" <<'PY'
import sys, re, os

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML required (pip install pyyaml)\n")
    sys.exit(2)

TOP_ALLOWED  = {"name", "description", "metadata"}
META_ALLOWED = {"type", "scope"}
VALID_SCOPES = {"repo", "universal", "meta"}

bad = []  # (path, reason)

for f in sys.argv[1:]:
    try:
        text = open(f, encoding="utf-8").read()
    except OSError as e:
        bad.append((f, f"unreadable: {e}")); continue

    # (F) must open with a ---fenced block that parses to a mapping.
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    if not m:
        bad.append((f, "no ---fenced frontmatter block")); continue
    try:
        fm = yaml.safe_load(m.group(1))
    except Exception as e:
        bad.append((f, f"UNPARSEABLE: {e}")); continue
    if not isinstance(fm, dict):
        bad.append((f, "frontmatter is not a YAML mapping")); continue

    reasons = []

    # (A) top-level key allowlist
    extra_top = set(fm) - TOP_ALLOWED
    if extra_top:
        reasons.append(f"forbidden top-level keys {sorted(extra_top)}")

    # (B) metadata key allowlist (metadata itself must be a mapping)
    meta = fm.get("metadata")
    if meta is None:
        reasons.append("missing metadata")
        meta = {}
    elif not isinstance(meta, dict):
        reasons.append("metadata is not a mapping")
        meta = {}
    else:
        extra_meta = set(meta) - META_ALLOWED
        if extra_meta:
            reasons.append(f"forbidden metadata keys {sorted(extra_meta)}")

    # (C) name + description present and non-empty
    for k in ("name", "description"):
        v = fm.get(k)
        if not (isinstance(v, str) and v.strip()):
            reasons.append(f"missing/empty {k}")

    # (D) metadata.type present and non-empty (open tag — value not checked)
    t = meta.get("type")
    if not (isinstance(t, str) and t.strip()):
        reasons.append("missing/empty metadata.type")

    # (E) metadata.scope is the closed enum
    s = meta.get("scope")
    if s not in VALID_SCOPES:
        reasons.append(f"metadata.scope {s!r} not in {sorted(VALID_SCOPES)}")

    if reasons:
        bad.append((f, "; ".join(reasons)))

for f, why in bad:
    print(f"INVALID {os.path.basename(f)}: {why}")

sys.exit(1 if bad else 0)
PY
