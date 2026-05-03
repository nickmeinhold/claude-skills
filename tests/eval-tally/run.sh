#!/usr/bin/env bash
# tests/eval-tally/run.sh — golden-file regression test for scripts/eval-tally.sh.
#
# Runs the script against the synthetic cohort under fixtures/, strips the
# `_Generated <timestamp>_` line (the only non-deterministic output), and
# diffs against expected/tally.md. Exits 0 on match, 1 on diff.
#
# Critically exercises the zero-unique-findings path (PR-2 fixture): both
# sets share all source_lines, which would have aborted under set -euo
# pipefail before PR #29's grep|wc → awk swap. This test ensures that path
# stays covered.

set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${TEST_DIR}/../.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/eval-tally.sh"
FIXTURES="${TEST_DIR}/fixtures"
EXPECTED="${TEST_DIR}/expected/tally.md"

[ -x "$SCRIPT" ] || chmod +x "$SCRIPT"

# Clean up the tally.md the script writes into EVAL_ROOT on exit so the
# fixture tree stays pristine between runs.
trap 'rm -f "${FIXTURES}/tally.md"' EXIT

# Strip the only non-deterministic line in the script's output before
# diffing. Defined once so expected and actual go through the same filter
# (was duplicated previously — DRY violation). The script's "Wrote ..."
# status line is now on stderr (eval-tally.sh), so it doesn't appear here.
strip_nondeterminism() { grep -v '^_Generated '; }

# Run the script against the fixture cohort and capture stdout. The script
# also writes its tally to $EVAL_ROOT_OVERRIDE/tally.md; we ignore that
# file for the diff (cleaned up by the trap above).
actual=$(EVAL_ROOT_OVERRIDE="$FIXTURES" "$SCRIPT" 2>/dev/null | strip_nondeterminism)

if diff -u <(strip_nondeterminism < "$EXPECTED") <(echo "$actual"); then
  echo "PASS: tests/eval-tally output matches golden."
  exit 0
else
  echo "FAIL: tests/eval-tally output differs from golden." >&2
  exit 1
fi
