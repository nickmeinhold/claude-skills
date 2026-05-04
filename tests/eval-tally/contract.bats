#!/usr/bin/env bats
# tests/eval-tally/contract.bats — writer/reader contract test for the
# persona-eval cohort dir naming.
#
# The fixture-based golden test in run.sh can't catch writer/reader drift:
# fixtures and reader move together, so renaming one without the other
# leaves both green. PR #38 (2026-05-04) was caused by exactly that —
# PR #30 renamed cohort dirs from `claude-skills-PR-` to
# `nickmeinhold__claude-skills-PR-` in the writer (cage-match-eval.md) and
# in `ship.md`'s gate, but `scripts/eval-tally.sh`'s COHORT_PREFIX kept the
# old shape. The script silently returned "no PRs complete" against
# production for days because nobody ran it and the fixture-based test
# kept passing.
#
# This file closes that surface. Both tests source-grep the writer's
# EVAL_DIR formula straight out of cage-match-eval.md and `eval` it. If
# the writer formula changes, the test executes the new shape and the
# reader either finds it (test passes — both updated together) or doesn't
# (test fails — drift detected at CI, not in production).

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/eval-tally.sh"
  EVAL_ROOT="$(mktemp -d)"
}

teardown() {
  if [[ -n "${EVAL_ROOT:-}" && -d "$EVAL_ROOT" ]]; then
    rm -rf "$EVAL_ROOT"
  fi
}

# Construct an EVAL_DIR using the writer formula from cage-match-eval.md,
# substituting our isolated $EVAL_ROOT for the literal `~/.claude/persona-eval`.
# Sets EVAL_DIR in the caller's scope.
construct_eval_dir() {
  local repo="$1"
  local pr="$2"
  REPO="$repo"
  PR="$pr"
  local writer_lines
  writer_lines=$(grep -E '^(REPO_SLUG=|EVAL_DIR=)' "${REPO_ROOT}/cage-match-eval.md")
  [ -n "$writer_lines" ] || return 1
  writer_lines=${writer_lines//\~\/.claude\/persona-eval/$EVAL_ROOT}
  eval "$writer_lines"
  [ -n "$EVAL_DIR" ] || return 1
}

# Drop a minimal valid (mapping.json, outcomes.json) pair into $EVAL_DIR
# so the reader treats it as a complete cohort entry.
write_minimal_fixtures() {
  local pr="$1"
  cat > "$EVAL_DIR/mapping.json" <<EOF
{"pr": ${pr}, "findings": [
  {"id": 1, "set": "a", "reviewer": "test-a", "source_line": "f.sh:1"},
  {"id": 2, "set": "b", "reviewer": "test-b", "source_line": "f.sh:2"}
]}
EOF
  cat > "$EVAL_DIR/outcomes.json" <<EOF
{"pr": ${pr}, "findings": [
  {"id": 1, "action": "inline", "notes": "x"},
  {"id": 2, "action": "inline", "notes": "y"}
]}
EOF
}

@test "reader picks up dirs the writer creates for the canonical experiment repo" {
  construct_eval_dir "nickmeinhold/claude-skills" "999"
  mkdir -p "$EVAL_DIR"
  write_minimal_fixtures "999"

  run env EVAL_ROOT_OVERRIDE="$EVAL_ROOT" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Complete: 1 — 999"* ]]
}

@test "reader EXCLUDES dirs the writer creates for non-canonical (cross-fork) repos" {
  # The original PR-30 motivation: a fork named otherorg/claude-skills
  # invoking cage-match-eval must not pollute the canonical cohort.
  # Reader's COHORT_PREFIX is owner-prefixed for exactly this reason.
  construct_eval_dir "otherorg/claude-skills" "999"
  mkdir -p "$EVAL_DIR"
  write_minimal_fixtures "999"

  run env EVAL_ROOT_OVERRIDE="$EVAL_ROOT" bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"None complete yet."* ]]
  [[ "$output" != *"Complete:"*"999"* ]]
}
