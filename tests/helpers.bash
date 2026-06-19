#!/usr/bin/env bash
# tests/helpers.bash — shared assertion helpers for the bats suites.
#
# WHY THIS EXISTS
# ---------------
# bats runs each @test body under `set -eET`, so MOST failing commands abort the
# test. But the conditional-test KEYWORD `[[ ... ]]` is exempt: bats installs a
# DEBUG trap (via `set -T`, for stack traces) that consumes the non-zero exit of
# a `[[` before errexit can see it. So a false `[[ ... ]]` in the MIDDLE of a
# test body is silently swallowed — the test only fails if that `[[` happens to
# be the body's last command. `!`-inverted commands (`! grep ...`) are swallowed
# the same way (bash exempts `!` lists from errexit). The `[` builtin and bare
# external commands (`grep`, `diff`, ...) DO abort correctly under errexit.
#
# Net effect: a bare `[[ ... ]]` assertion that isn't the last line is a lie —
# it can be false and the test still reports green. This masked a real off-by-one
# that only CI caught (PR #83). Verified empirically against bats 1.13 / bash 5.3.
#
# THE FIX: route every assertion through a function call that returns non-zero.
# bats DOES catch a failing function call wherever it sits in the body. So:
#
#     [[ cond ]] || fail "message"
#
# fails the test fast, anywhere in the body, with a readable message. A CI lint
# (scripts/lint-bats-assertions.sh) enforces that every `[`/`[[`/`!` assertion
# carries a `|| fail` (or `|| return`/`|| skip`) guard, so the footgun cannot
# re-enter the suites.

# fail MESSAGE...
#   Print a diagnostic to stderr and return 1. Use as: <assertion> || fail "..."
#   bats also prints the failing source line, so a terse message is fine.
fail() {
  echo "assertion failed: $*" >&2
  return 1
}
