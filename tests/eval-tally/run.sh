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

# Run the script against the fixture cohort. Strip the timestamp line so
# the diff is deterministic. Capture stdout (script also writes to
# $EVAL_DIR_OVERRIDE/tally.md, which we ignore for the diff).
actual=$(EVAL_DIR_OVERRIDE="$FIXTURES" "$SCRIPT" \
  | grep -v '^_Generated ' \
  | grep -v '^Wrote ')

if diff -u <(grep -v '^_Generated ' "$EXPECTED") <(echo "$actual"); then
  echo "PASS: tests/eval-tally output matches golden."
  exit 0
else
  echo "FAIL: tests/eval-tally output differs from golden." >&2
  exit 1
fi
