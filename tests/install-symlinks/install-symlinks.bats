#!/usr/bin/env bats
# tests/install-symlinks/install-symlinks.bats — bats integration tests for
# scripts/install-symlinks.sh.
#
# Each test gets a fresh $HOME under mktemp so the real ~/.claude/ is never
# touched. The script reads its own dirname to find the repo root, so the
# tests invoke it via its real path inside the repo (not a copy) and rely
# on $HOME to redirect target paths.

load ../helpers

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
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -L "$TARGET" ] || fail
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ] || fail
  [[ "$output" == *"$TARGET -> $EVAL_TALLY_SRC"* ]] || fail "output=$output"
}

@test "second invocation is idempotent and reports already linked" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "status=$status"

  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"already linked"* ]] || fail "output=$output"
  [ -L "$TARGET" ] || fail
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ] || fail
}

@test "regular file at target without --force refuses and exits non-zero" {
  mkdir -p "$(dirname "$TARGET")"
  echo "stale local copy" > "$TARGET"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "status=$status"
  [[ "$output" == *"re-run with --force"* ]] || fail "output=$output"
  # File is untouched, no symlink created.
  [ ! -L "$TARGET" ] || fail
  [ -f "$TARGET" ] || fail
  [ "$(cat "$TARGET")" = "stale local copy" ] || fail
}

@test "regular file at target with --force is moved to .bak and replaced with symlink" {
  mkdir -p "$(dirname "$TARGET")"
  echo "stale local copy" > "$TARGET"

  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -L "$TARGET" ] || fail
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ] || fail
  [ -f "$TARGET.bak" ] || fail
  [ "$(cat "$TARGET.bak")" = "stale local copy" ] || fail
}

@test "stale symlink without --force refuses" {
  mkdir -p "$(dirname "$TARGET")"
  ln -s "/nonexistent/elsewhere.sh" "$TARGET"

  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "status=$status"
  [[ "$output" == *"expected"* ]] || fail "output=$output"
  # Stale symlink unchanged.
  [ "$(readlink "$TARGET")" = "/nonexistent/elsewhere.sh" ] || fail
}

@test "stale symlink with --force is moved aside and replaced" {
  mkdir -p "$(dirname "$TARGET")"
  ln -s "/nonexistent/elsewhere.sh" "$TARGET"

  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -L "$TARGET" ] || fail
  [ "$(readlink "$TARGET")" = "$EVAL_TALLY_SRC" ] || fail
  # Old symlink moved to .bak
  [ -L "$TARGET.bak" ] || fail
  [ "$(readlink "$TARGET.bak")" = "/nonexistent/elsewhere.sh" ] || fail
}

@test "dangling source guard refuses to create symlink when source is missing" {
  # Stage a fake repo whose scripts/install-symlinks.sh points to a
  # nonexistent source. Easiest way to exercise the guard without mutating
  # the real repo: copy the real script into a tempdir and let it resolve
  # REPO_ROOT relative to that copy (so $REPO_ROOT/scripts/eval-tally.sh
  # genuinely doesn't exist).
  #
  # Rooted under $TEST_HOME so teardown's `rm -rf "$TEST_HOME"` always
  # cleans it up, even if an assertion below fails before we reach the
  # explicit rm at end-of-test.
  FAKE_REPO="$(mktemp -d "$TEST_HOME/fakerepo.XXXXXX")"
  mkdir -p "$FAKE_REPO/scripts"
  cp "$SCRIPT" "$FAKE_REPO/scripts/install-symlinks.sh"
  # Deliberately do NOT create $FAKE_REPO/scripts/eval-tally.sh.

  run bash "$FAKE_REPO/scripts/install-symlinks.sh"
  [ "$status" -ne 0 ] || fail "status=$status"
  [[ "$output" == *"source missing"* ]] || fail "output=$output"
  [[ "$output" == *"refusing to create a dangling symlink"* ]] || fail "output=$output"
  [ ! -e "$TARGET" ] || fail
  [ ! -L "$TARGET" ] || fail
}

@test "repeated --force runs do not clobber prior backups" {
  mkdir -p "$(dirname "$TARGET")"
  echo "first" > "$TARGET"
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -f "$TARGET.bak" ] || fail
  [ "$(cat "$TARGET.bak")" = "first" ] || fail

  # Replace symlink with a regular file again, then force a second time.
  rm "$TARGET"
  echo "second" > "$TARGET"
  run bash "$SCRIPT" --force
  [ "$status" -eq 0 ] || fail "status=$status"
  # First .bak preserved; new backup chosen at .bak.1
  [ "$(cat "$TARGET.bak")" = "first" ] || fail
  [ -f "$TARGET.bak.1" ] || fail
  [ "$(cat "$TARGET.bak.1")" = "second" ] || fail
}

@test "--help prints usage and exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"Usage:"* ]] || fail "output=$output"
}

@test "unknown flag exits with code 2" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ] || fail "status=$status"
  [[ "$output" == *"unknown arg"* ]] || fail "output=$output"
}
