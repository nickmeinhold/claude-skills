#!/usr/bin/env bats
# Contract tests for scripts/lint-bats-assertions.sh — the lint that keeps the
# `|| fail` idiom from regressing. The lint is itself a seam-parser (it reads
# shell that the author wrote), so these tests hammer its edge cases the same way
# the cage-match would: heredocs, `[[` inside `run`, comments, `;`-joins, quoted
# metacharacters, and control-flow chains that must NOT be flagged.
#
# Dogfooding: every assertion here uses the `|| fail` idiom under test.

load ../helpers

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  LINT="${REPO_ROOT}/scripts/lint-bats-assertions.sh"
  SANDBOX="$(mktemp -d)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# Write a one-test .bats file whose body is the passed line(s).
mkbats() {  # $1 = body
  printf '#!/usr/bin/env bats\n@test "x" {\n  %s\n}\n' "$1" > "$SANDBOX/t.bats"
}

# --- the footgun forms must be FLAGGED (exit 1) -----------------------------
@test "bare [[ ]] is flagged" {
  mkbats '[[ 1 -eq 2 ]]'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
  [[ "$output" == *"bare assertion"* ]] || fail "output=$output"
}

@test "bare single-bracket [ ] is flagged (uniform idiom, not just [[ )" {
  mkbats '[ "$x" = "y" ]'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
}

@test "bare !-inverted command is flagged" {
  mkbats '! grep -q foo bar'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
}

@test "a bare assertion followed by run on ; is flagged (second segment)" {
  mkbats 'run echo hi; [ "$status" -eq 0 ]'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
}

@test "a trailing comment cannot smuggle a fake guard past the lint" {
  # The '|| fail' lives in a COMMENT, not in code — must still be flagged.
  mkbats '[[ 1 -eq 2 ]]   # we should || fail here someday'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
}

# --- the guarded / control-flow forms must be CLEAN (exit 0) ----------------
@test "[[ ]] || fail is clean" {
  mkbats '[[ 1 -eq 1 ]] || fail "msg"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "|| return and || skip also satisfy the guard" {
  mkbats '[ -n "$x" ] || return 1'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
  mkbats '[ -n "$x" ] || skip "n/a"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a teardown && chain ending in an action is control flow, not flagged" {
  mkbats '[ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a [ ] || printf loop guard is control flow, not flagged" {
  mkbats '[ "$first" -eq 1 ] || printf ", "'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "! grep ... || fail is clean" {
  mkbats '! grep -q foo bar || fail "foo should be absent"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

# --- the parser edge cases the cage-match attacks ---------------------------
@test "a [-leading line inside a heredoc body is NOT flagged" {
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  cat > /tmp/fixture <<'EOF'
[ this is JSON-ish fixture data, not a shell assertion ]
[[ neither is this ]]
EOF
  [ -f /tmp/fixture ] || fail "fixture missing"
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a commented-out assertion line is NOT flagged" {
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  # [[ 1 -eq 2 ]]
  true
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a guarded assertion with ; inside a quoted glob is NOT flagged" {
  # The ; lives inside the quoted glob; quote-masking must keep the [[ joined
  # to its || fail so the ;-split never separates them.
  mkbats '[[ "$out" == *"a;b"* ]] || fail "output=$out"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a BARE assertion with ; inside a quoted glob is still flagged" {
  mkbats '[[ "$out" == *"a;b"* ]]'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
}

@test "[[ inside a run argument is NOT a standalone assertion" {
  # `run` captures status; the [[ is an argument to bash -c, not an assertion.
  mkbats 'run bash -c "[[ 1 -eq 2 ]]"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a \\-continuation does not desync line tracking" {
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  echo one \
    two three
  [[ 1 -eq 2 ]]
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "output=$output"
  [[ "$output" == *":5:"* ]] || fail "expected the violation on line 5, got: $output"
}

# --- Carnot PR #84 findings: parser must be conservative at its seams -------
@test "a guarded assertion with an ESCAPED quote + ; in a glob is NOT flagged" {
  # mask() must not let \" toggle quote-state; the ; stays masked, the [[ stays
  # joined to its || fail. (Carnot finding 2 — backslash-escape in mask.)
  mkbats '[[ "$out" == *"a\";b"* ]] || fail "output=$out"'
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

@test "a QUOTED string that looks like a heredoc opener does not desync state" {
  # `printf "<<EOF"` must NOT enter heredoc mode and swallow the real bare
  # assertion below it. (Carnot finding 1 — heredoc detected on raw text.)
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  printf '%s\n' "<<EOF"
  [[ 1 -eq 2 ]]
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "expected the bare [[ ]] to still be flagged: $output"
}

@test "a commented heredoc-looking token does not desync state" {
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  # here is a <<EOF in a comment
  [[ 1 -eq 2 ]]
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "expected the bare [[ ]] to still be flagged: $output"
}

@test "a plain <<EOF does not close on an INDENTED terminator inside fixture text" {
  # Only <<- permits a tab-indented terminator. A space/tab-indented EOF inside
  # a plain <<EOF body is fixture content, not the terminator — the heredoc must
  # stay open so the trailing bare assertion is still caught. (Carnot finding 3.)
  printf '#!/usr/bin/env bats\n@test "x" {\n  cat > /tmp/f <<EOF\nreal body\n\tEOF\n[ this is still fixture ]\nEOF\n  [[ 1 -eq 2 ]]\n}\n' > "$SANDBOX/t.bats"
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 1 ] || fail "expected the bare [[ ]] after the heredoc to be flagged: $output"
}

@test "a quoted-delimiter heredoc <<'EOF' still tracks its real terminator" {
  # Regression guard: masking must not corrupt the delimiter word. The body
  # (including a [-leading fixture line) must be skipped, and the real EOF closes.
  cat > "$SANDBOX/t.bats" <<'BATS'
#!/usr/bin/env bats
@test "x" {
  cat > /tmp/f <<'EOF'
[ fixture line, not an assertion ]
EOF
  [ -f /tmp/f ] || fail "missing"
}
BATS
  run bash "$LINT" "$SANDBOX/t.bats"
  [ "$status" -eq 0 ] || fail "output=$output"
}

# --- the real suites must pass the lint -------------------------------------
@test "all repo suites are lint-clean" {
  run bash "$LINT" "${REPO_ROOT}/tests"
  [ "$status" -eq 0 ] || fail "output=$output"
}
