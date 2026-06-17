#!/usr/bin/env bash
# validate-scorecard.sh — THE canonical /consolidate scorecard schema.
#
# Sibling of validate-memory-frontmatter.sh, same principle (issue #885, #883):
# the scorecard schema must have ONE executable definition that every consumer
# references, never N prose restatements that drift. The memory-writer agent
# (Sonnet) writes $SD/scorecard.json by reproducing the schema from SKILL.md
# prose — and on the 2026-06-17 run it DRIFTED (wrote predictions[] = {id, claim,
# verifiable_by} and top-level {project, session_label, scores, ...}), the exact
# instrument-rotting failure the skill warns about. The next-session readtime
# grader reads predictions[].text + memories_written/memories_updated; with the
# drift those are absent/null and the grader silently fails to grade — the rot
# the loop exists to prevent. This script is the gate that catches it.
#
# THE SCHEMA (the CODE below is authoritative; this comment only describes it):
#   A scorecard is a JSON object with EXACTLY these 10 top-level keys — no more,
#   no aliases, no extras (overflow goes in `notes`, never a new key):
#     schema_version          int
#     session_date            string
#     memory_dir              string
#     memories_written        array of strings (absolute paths)
#     memories_updated        array of strings (absolute paths)
#     index_edits             int
#     errors_triaged          int
#     memory_index_over_budget bool
#     predictions             array of objects, each EXACTLY {text, basis, confidence}
#                               text   = non-empty string (the grader reads this)
#                               basis  = string
#                               confidence = number
#     notes                   string (may be empty)
#
# Usage:
#   validate-scorecard.sh <scorecard.json> [<more.json> ...]
# Exit 0 iff EVERY file is a valid scorecard; exit 1 (and print one
# `INVALID <name>: <why>` line per offender) otherwise; exit 2 on usage error.
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: validate-scorecard.sh <scorecard.json> [<scorecard.json> ...]" >&2
  exit 2
fi

python3 - "$@" <<'PY'
import sys, os, json, numbers

TOP_REQUIRED = {
    "schema_version", "session_date", "memory_dir",
    "memories_written", "memories_updated", "index_edits",
    "errors_triaged", "memory_index_over_budget", "predictions", "notes",
}
PRED_REQUIRED = {"text", "basis", "confidence"}

def is_str(x):  return isinstance(x, str)
def is_int(x):  return isinstance(x, int) and not isinstance(x, bool)
def is_num(x):  return isinstance(x, numbers.Number) and not isinstance(x, bool)
def is_strlist(x): return isinstance(x, list) and all(isinstance(i, str) for i in x)

bad = []  # (path, reason)

for f in sys.argv[1:]:
    try:
        data = json.load(open(f, encoding="utf-8"))
    except FileNotFoundError:
        bad.append((f, "file not found")); continue
    except json.JSONDecodeError as e:
        bad.append((f, f"not valid JSON: {e}")); continue
    if not isinstance(data, dict):
        bad.append((f, "top level is not a JSON object")); continue

    reasons = []

    # exact top-level key set — no missing, no extra/alias keys
    keys = set(data)
    missing = TOP_REQUIRED - keys
    extra   = keys - TOP_REQUIRED
    if missing:
        reasons.append(f"missing top-level keys {sorted(missing)}")
    if extra:
        reasons.append(f"forbidden top-level keys {sorted(extra)}")

    # scalar/array types (only check keys that are present)
    checks = [
        ("schema_version", is_int, "int"),
        ("session_date",   is_str, "string"),
        ("memory_dir",     is_str, "string"),
        ("memories_written", is_strlist, "array of strings"),
        ("memories_updated", is_strlist, "array of strings"),
        ("index_edits",    is_int, "int"),
        ("errors_triaged", is_int, "int"),
        ("memory_index_over_budget", lambda x: isinstance(x, bool), "bool"),
        ("notes",          is_str, "string"),
    ]
    for key, pred, want in checks:
        if key in data and not pred(data[key]):
            reasons.append(f"{key} must be {want}")

    # predictions: array of {text, basis, confidence} — text non-empty
    preds = data.get("predictions")
    if "predictions" in data:
        if not isinstance(preds, list):
            reasons.append("predictions must be an array")
        else:
            for i, p in enumerate(preds):
                if not isinstance(p, dict):
                    reasons.append(f"predictions[{i}] is not an object"); continue
                pk = set(p)
                pmiss = PRED_REQUIRED - pk
                pextra = pk - PRED_REQUIRED
                if pmiss:
                    reasons.append(f"predictions[{i}] missing {sorted(pmiss)}")
                if pextra:
                    reasons.append(f"predictions[{i}] forbidden keys {sorted(pextra)}")
                if "text" in p and not (is_str(p["text"]) and p["text"].strip()):
                    reasons.append(f"predictions[{i}].text must be a non-empty string")
                if "basis" in p and not is_str(p["basis"]):
                    reasons.append(f"predictions[{i}].basis must be a string")
                if "confidence" in p and not is_num(p["confidence"]):
                    reasons.append(f"predictions[{i}].confidence must be a number")

    if reasons:
        bad.append((f, "; ".join(reasons)))

for f, why in bad:
    print(f"INVALID {os.path.basename(f)}: {why}")

sys.exit(1 if bad else 0)
PY
