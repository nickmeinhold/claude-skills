#!/usr/bin/env bats
# tests/install-symlinks/install-symlinks.bats — bats integration tests for
# scripts/install-symlinks.sh.
#
# Each test gets a fresh $HOME under mktemp so the real ~/.claude/ is never
# touched. The script reads its own dirname to find the repo root, so the
# tests invoke it via its real path inside the repo (not a copy) and rely
# on $HOME to redirect target paths.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/install-symlinks.sh"
  EVAL_TALLY_SRC="${REPO_ROOT}/scripts/eval-tally.sh"

  # Per-test sandbox $HOME so tests stay isolated and the real ~/.claude/
  # is never touched.
  TEST_HOME="$(mktemp -d)"
  export HOME="$TEST_HOME"
  TARGET="$TEST_HOME/.claude/persona-eval/eval-tally.sh"
}

teardown() {
  if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
    rm -rf "$TEST_HOME"
  fi
}

@test "fresh install creates the expected symlink" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -L "$TARGET" ]
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ]
  [[ "$output" == *"$TARGET -> $EVAL_TALLY_SRC"* ]]
}

@test "second invocation is idempotent and reports already linked" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already linked"* ]]
  [ -L "$TARGET" ]
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ]
}

@test "regular file at target without --force refuses and exits non-zero" {
  mkdir -p "$(dirname "$TARGET")"
  echo "stale local copy" > "$TARGET"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-run with --force"* ]]
  # File is untouched, no symlink created.
  [ ! -L "$TARGET" ]
  [ -f "$TARGET" ]
  [ "$(cat "$TARGET")" = "stale local copy" ]
}

@test "regular file at target with --force is moved to .bak and replaced with symlink" {
  mkdir -p "$(dirname "$TARGET")"
  echo "stale local copy" > "$TARGET"

  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ -L "$TARGET" ]
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ]
  [ -f "$TARGET.bak" ]
  [ "$(cat "$TARGET.bak")" = "stale local copy" ]
}

@test "stale symlink without --force refuses" {
  mkdir -p "$(dirname "$TARGET")"
  ln -s "/nonexistent/elsewhere.sh" "$TARGET"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected"* ]]
  # Stale symlink unchanged.
  [ "$(readlink "$TARGET")" = "/nonexistent/elsewhere.sh" ]
}

@test "stale symlink with --force is moved aside and replaced" {
  mkdir -p "$(dirname "$TARGET")"
  ln -s "/nonexistent/elsewhere.sh" "$TARGET"

  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ -L "$TARGET" ]
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ]
  # Old symlink moved to .bak
  [ -L "$TARGET.bak" ]
  [ "$(readlink "$TARGET.bak")" = "/nonexistent/elsewhere.sh" ]
}

@test "dangling source guard refuses to create symlink when source is missing" {
  # Stage a fake repo whose scripts/install-symlinks.sh points to a
  # nonexistent source. Easiest way to exercise the guard without mutating
  # the real repo: copy the real script into a tempdir and let it resolve
  # REPO_ROOT relative to that copy (so $REPO_ROOT/scripts/eval-tally.sh
  # genuinely doesn't exist).
  FAKE_REPO="$(mktemp -d)"
  mkdir -p "$FAKE_REPO/scripts"
  cp "$SCRIPT" "$FAKE_REPO/scripts/install-symlinks.sh"
  # Deliberately do NOT create $FAKE_REPO/scripts/eval-tally.sh.

  run bash "$FAKE_REPO/scripts/install-symlinks.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source missing"* ]]
  [[ "$output" == *"refusing to create a dangling symlink"* ]]
  [ ! -e "$TARGET" ]
  [ ! -L "$TARGET" ]

  rm -rf "$FAKE_REPO"
}

@test "repeated --force runs do not clobber prior backups" {
  mkdir -p "$(dirname "$TARGET")"
  echo "first" > "$TARGET"
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  [ -f "$TARGET.bak" ]
  [ "$(cat "$TARGET.bak")" = "first" ]

  # Replace symlink with a regular file again, then force a second time.
  rm "$TARGET"
  echo "second" > "$TARGET"
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ]
  # First .bak preserved; new backup chosen at .bak.1
  [ "$(cat "$TARGET.bak")" = "first" ]
  [ -f "$TARGET.bak.1" ]
  [ "$(cat "$TARGET.bak.1")" = "second" ]
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown flag exits with code 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown arg"* ]]
}
