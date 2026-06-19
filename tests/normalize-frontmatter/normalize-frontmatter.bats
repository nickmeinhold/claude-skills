#!/usr/bin/env bats
# tests/normalize-frontmatter/normalize-frontmatter.bats — contract tests for
# scripts/normalize-memory-frontmatter.sh.
#
# Pins the behaviours established across PRs #66 / #67 / #68 so a future refactor
# can't silently re-introduce the scope/type clobber or body mutation those PRs
# fixed. Every test runs the REAL script under a per-test mktemp sandbox; the
# headless-`claude` fallback is mocked via PATH so no network call (and no cost)
# is incurred.

load ../helpers

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/normalize-memory-frontmatter.sh"

  SANDBOX="$(mktemp -d)"

  # Mock `claude` so the unfenced/empty-field fallback path is exercised
  # deterministically and offline. The real script invokes
  # `claude -p --output-format text` and parses NAME:/DESCRIPTION: lines.
  MOCKBIN="$SANDBOX/bin"
  mkdir -p "$MOCKBIN"
  cat > "$MOCKBIN/claude" <<'MOCK'
#!/usr/bin/env bash
# Mock claude CLI: ignore args/stdin, emit the two lines the script parses.
cat >/dev/null 2>&1 || true
printf 'NAME: Mocked Title\nDESCRIPTION: Mocked retrieval cue for a fixture with no frontmatter.\n'
MOCK
  chmod +x "$MOCKBIN/claude"
  PATH="$MOCKBIN:$PATH"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# Helper: extract the value of a metadata field (type/scope) from a file/string.
meta_field() { grep -E "^[[:space:]]*$1:" | head -1 | sed -E "s/^[[:space:]]*$1:[[:space:]]*//"; }

# ---------------------------------------------------------------------------
# Scope preservation (PR #66) — the field that drives graduation/eviction.
# ---------------------------------------------------------------------------

@test "scope: universal is preserved, never clobbered to repo" {
  f="$SANDBOX/feedback_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  type: feedback\n  scope: universal\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(echo "$output" | meta_field scope)" = "universal" ] || fail "output=$output"
}

@test "scope: meta is preserved" {
  f="$SANDBOX/feedback_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  type: feedback\n  scope: meta\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(echo "$output" | meta_field scope)" = "meta" ] || fail "output=$output"
}

@test "absent scope defaults to repo; an invalid scope also falls back to repo" {
  f="$SANDBOX/feedback_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  scope: bogus\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(echo "$output" | meta_field scope)" = "repo" ] || fail "output=$output"
}

# ---------------------------------------------------------------------------
# Type: open descriptive tag, preserve-first, derive = prefix (PR #68).
# ---------------------------------------------------------------------------

@test "existing curated type is preserved (type: user stays user)" {
  f="$SANDBOX/user_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  type: user\n  scope: repo\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(echo "$output" | meta_field type)" = "user" ] || fail "output=$output"
}

@test "absent type is derived as the prefix itself (user_ -> user)" {
  f="$SANDBOX/user_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  scope: repo\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(echo "$output" | meta_field type)" = "user" ] || fail "output=$output"
}

@test "type derivation is prefix-faithful across prefixes (session/technical/architecture)" {
  for p in session technical architecture; do
    f="$SANDBOX/${p}_x.md"
    printf -- '---\nname: x\ndescription: d\nmetadata:\n  scope: repo\n---\n\n# B\n' > "$f"
    run bash "$SCRIPT" "$f"
    [ "$status" -eq 0 ] || fail "status=$status"
    [ "$(echo "$output" | meta_field type)" = "$p" ] || fail "output=$output"
  done
}

@test "unknown prefix exits 1 and writes nothing" {
  f="$SANDBOX/bogusprefix_x.md"
  printf -- '---\nname: x\ndescription: d\nmetadata:\n  type: feedback\n  scope: repo\n---\n\n# B\n' > "$f"
  before="$(cat "$f")"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 1 ] || fail "status=$status"
  [ "$(cat "$f")" = "$before" ] || fail
}

# ---------------------------------------------------------------------------
# Body preservation (PR #66/#68) — byte-for-byte after the closing fence.
# ---------------------------------------------------------------------------

@test "body is preserved byte-for-byte; no blank line injected after the fence" {
  f="$SANDBOX/feedback_noblank.md"
  printf -- '---\nname: x\ndescription: y\nmetadata:\n  type: feedback\n  scope: repo\n---\nNOBLANK body line\n' > "$f"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  # The line immediately after the closing fence is the body, with no blank line.
  [ "$(awk '/^---$/{n++} n==2 && !/^---$/{print; exit}' "$f")" = "NOBLANK body line" ] || fail "first body line wrong"
}

@test "apply is idempotent (second apply yields a byte-identical file)" {
  f="$SANDBOX/feedback_idem.md"
  printf -- '---\nname: "n"\ndescription: "d"\nmetadata:\n  type: feedback\n  scope: repo\n---\n\n# Heading\n\nsome body\n' > "$f"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  once="$(cat "$f")"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(cat "$f")" = "$once" ] || fail
}

# ---------------------------------------------------------------------------
# Repair behaviours: banned-field strip, YAML-safe re-quote, LLM fallback.
# ---------------------------------------------------------------------------

@test "banned provenance fields (node_type/originSessionId) are dropped on re-emit" {
  f="$SANDBOX/feedback_banned.md"
  printf -- '---\nname: n\ndescription: d\nmetadata:\n  type: feedback\n  scope: repo\n  node_type: memory\n  originSessionId: abc123\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  ! grep -q "node_type" "$f" || fail
  ! grep -q "originSessionId" "$f" || fail
}

@test "a description containing a colon is re-quoted to valid YAML" {
  f="$SANDBOX/feedback_colon.md"
  printf -- '---\nname: n\ndescription: a desc with a colon: it breaks bare YAML\nmetadata:\n  type: feedback\n  scope: repo\n---\n\n# B\n' > "$f"
  run bash "$SCRIPT" --apply "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  # Result must parse as YAML and keep the full description.
  run python3 -c "import sys,yaml; d=yaml.safe_load(open('$f').read().split('---')[1]); assert 'colon' in d['description']; print('ok')"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$output" = "ok" ] || fail "output=$output"
}

@test "an unfenced file (no frontmatter) triggers the mocked claude fallback" {
  f="$SANDBOX/concept_unfenced.md"
  printf -- '# Some Concept\n\nNo frontmatter here at all.\n' > "$f"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  # Mock claude supplied the name/description; type derived from the prefix.
  [[ "$output" == *"Mocked Title"* ]] || fail "output=$output"
  [[ "$output" == *"Mocked retrieval cue"* ]] || fail "output=$output"
  [ "$(echo "$output" | meta_field type)" = "concept" ] || fail "output=$output"
}

@test "dry-run prints the proposed frontmatter and does NOT modify the file" {
  f="$SANDBOX/feedback_dry.md"
  printf -- '---\nname: keep\ndescription: keep me\nmetadata:\n  type: feedback\n  scope: meta\n---\n\n# B\n' > "$f"
  before="$(cat "$f")"
  run bash "$SCRIPT" "$f"
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"name:"* ]] || fail "output=$output"
  [[ "$output" == *"scope: meta"* ]] || fail "output=$output"
  [ "$(cat "$f")" = "$before" ] || fail
}
