#!/usr/bin/env bash
# heal-memory-dir.sh — ONE-PASS self-heal + validate for a memory directory.
#
# This is the merged form of what the /consolidate memory-writer used to hand-roll
# across ~9-12 separate Bash tool calls (detect-scan → normalize-per-file → find-the-
# script → re-normalize → validate → re-validate). Each of those was an agent round-trip
# that re-billed ~51K tokens of context. This tool does the WHOLE sweep in one process,
# so the agent pays exactly ONE round-trip: it globs the dir, parses each file once,
# validates in-memory, repairs the drifted ones in-memory (preserve-first), certifies
# the rebuild against the SAME schema, writes only what changed, and reports a summary.
#
# Single source of truth: all schema + repair logic is in memory_frontmatter.py (this
# dir). validate-/normalize-memory-frontmatter.sh import the same module, so this tool
# cannot drift from the canonical schema (issue #883, dir-id 9b3d).
#
# It does NOT cache: the script's own wall-clock is sub-second (python startup dominates),
# and a validity cache would be a correctness hazard on a tool whose whole job is the
# gate — the harness re-injects banned provenance out-of-band, exactly the mtime-decoupled
# write a cache cannot safely trust. The cheap scope lever is --written instead (below).
#
# Usage:
#   heal-memory-dir.sh <MEMORY_DIR>                       # full-dir sweep  (O(N))
#   heal-memory-dir.sh <MEMORY_DIR> --written F [F ...]   # only these files (O(W) fast path)
#   heal-memory-dir.sh <MEMORY_DIR> --no-llm              # never shell to `claude` to fill
#                                                         #   missing name/description
#
#   --written: the files this session wrote — the ONLY files the harness can have
#     re-injected into. The per-run fast path; pass the same list step 2a validates.
#     Paths may be basenames (resolved against MEMORY_DIR) or absolute, BUT any path
#     resolving OUTSIDE MEMORY_DIR is REFUSED (exit 1) — the SKILL "within this repo
#     only" guardrail, enforced fail-closed so a stray path can never mutate another
#     project's memory dir (Carnot, PR #80). Non-memory-prefix files and index files
#     (MEMORY*.md) are skipped with a note, never flagged (issue #936).
#   --no-llm: skip the conditional headless-`claude` fill (unattended / test runs). A
#     file genuinely missing name/description then fails as unfixable instead of calling
#     the model.
#
# Exit 0 iff every processed memory file is schema-valid after the pass.
# Exit 1 if any file remains INVALID (unfixable) — one `INVALID <name>: <why>` line each.
# Exit 2 on usage error / missing PyYAML.
set -euo pipefail

# Resolve this script's real directory (following a symlink install) so the python
# heredoc can import the sibling memory_frontmatter.py module.
SRC="${BASH_SOURCE[0]}"
_hops=0
while [ -L "$SRC" ]; do
  _hops=$((_hops + 1)); [ "$_hops" -gt 40 ] && { echo "ERROR: symlink cycle resolving $0" >&2; exit 2; }
  DIR="$(cd "$(dirname "$SRC")" && pwd)"
  SRC="$(readlink "$SRC")"
  [ "${SRC#/}" = "$SRC" ] && SRC="$DIR/$SRC"  # relative symlink -> resolve against DIR
done
HERE="$(cd "$(dirname "$SRC")" && pwd)"

if [ "$#" -lt 1 ]; then
  echo "usage: heal-memory-dir.sh <MEMORY_DIR> [--written F ...] [--no-llm]" >&2
  exit 2
fi

MEMORY_DIR="$1"; shift
if [ ! -d "$MEMORY_DIR" ]; then
  echo "ERROR: not a directory: $MEMORY_DIR" >&2
  exit 2
fi

MODE="sweep"
ALLOW_LLM=1
WRITTEN=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --written) MODE="written"; shift
               while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do WRITTEN+=("$1"); shift; done ;;
    --no-llm)  ALLOW_LLM=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}" \
MEMORY_DIR="$MEMORY_DIR" MODE="$MODE" ALLOW_LLM="$ALLOW_LLM" \
python3 - "${WRITTEN[@]+"${WRITTEN[@]}"}" <<'PY'
import sys, os, glob

try:
    import memory_frontmatter as mf
except ImportError as e:
    sys.stderr.write(f"ERROR: cannot import memory_frontmatter ({e}); run install-symlinks.sh\n")
    sys.exit(2)

try:
    import yaml  # noqa: F401  (fail fast with the same exit-2 contract as the validator)
except ImportError:
    sys.stderr.write("ERROR: PyYAML required (pip install pyyaml)\n")
    sys.exit(2)

MEMORY_DIR = os.environ["MEMORY_DIR"]
MODE = os.environ["MODE"]
ALLOW_LLM = os.environ.get("ALLOW_LLM", "1") == "1"
MEM_REAL = os.path.realpath(MEMORY_DIR)


def _inside_memory_dir(path):
    """Fail-closed containment: the resolved path must live under MEMORY_DIR. realpath
    on both sides resolves symlinks (so a file symlinked OUT is caught) and commonpath
    avoids the /a/memory vs /a/memoryX prefix trap a startswith check would miss."""
    real = os.path.realpath(path)
    try:
        return os.path.commonpath([real, MEM_REAL]) == MEM_REAL and real != MEM_REAL
    except ValueError:  # different drives (not on POSIX) — treat as outside
        return False


# Build the candidate file list.
if MODE == "written":
    raw = sys.argv[1:]
    candidates = [f if os.path.isabs(f) else os.path.join(MEMORY_DIR, f) for f in raw]
else:
    candidates = sorted(glob.glob(os.path.join(MEMORY_DIR, "*.md")))

scanned = clean = healed = skipped = 0
failures = []   # (path, why)
healed_files = []

for path in candidates:
    base = os.path.basename(path)
    if not mf.is_memory_file(base):
        skipped += 1
        if MODE == "written":  # be explicit when the caller named it
            print(f"skip (not a memory file): {base}")
        continue
    if not _inside_memory_dir(path):
        # Fail-closed: never mutate a file outside MEMORY_DIR (Carnot PR #80 finding 2).
        failures.append((path, f"refused: resolves outside MEMORY_DIR ({MEM_REAL})"))
        continue
    if not os.path.isfile(path):
        failures.append((path, "no such file"))
        continue

    scanned += 1
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as e:
        failures.append((path, f"unreadable: {e}"))
        continue

    if mf.is_valid(text):
        clean += 1
        continue

    # drifted -> repair in-memory, certify, write iff changed
    try:
        status = mf.apply_canonical(path, allow_llm=ALLOW_LLM)
    except mf.RepairError as e:
        failures.append((path, str(e)))
        continue
    if status == "normalized":
        healed += 1
        healed_files.append(base)

for path, why in failures:
    print(f"INVALID {os.path.basename(path)}: {why}")

summary = f"heal-memory-dir: scanned={scanned} clean={clean} healed={healed}"
if skipped:
    summary += f" skipped={skipped}"
if failures:
    summary += f" FAILED={len(failures)}"
if healed_files:
    summary += "  healed: " + ", ".join(healed_files)
print(summary)

sys.exit(1 if failures else 0)
PY
