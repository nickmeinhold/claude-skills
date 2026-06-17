#!/usr/bin/env bats
# tests/validate-frontmatter/validate-frontmatter.bats — contract tests for
# scripts/validate-memory-frontmatter.sh, the CANONICAL memory-frontmatter schema
# (issue #883). These tests ARE the executable spec's spec: they pin each schema
# rule (A–F in the script header) so a future edit can't silently loosen the gate
# that /consolidate step 2a and the normalizer both delegate to.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/validate-memory-frontmatter.sh"
  SANDBOX="$(mktemp -d)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# Write a fully-canonical fixture; callers mutate it to test each rule.
canonical() {
  cat > "$1" <<'EOF'
---
name: "A Title"
description: "one-line retrieval cue"
metadata:
  type: feedback
  scope: repo
---
body text
EOF
}

# --- happy path ------------------------------------------------------------
@test "a canonical file passes (exit 0, no output)" {
  canonical "$SANDBOX/feedback_ok.md"
  run bash "$SCRIPT" "$SANDBOX/feedback_ok.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "each valid scope value passes" {
  for s in repo universal meta; do
    canonical "$SANDBOX/f.md"
    # swap the scope line
    sed -i.bak "s/  scope: repo/  scope: $s/" "$SANDBOX/f.md" && rm -f "$SANDBOX/f.md.bak"
    run bash "$SCRIPT" "$SANDBOX/f.md"
    [ "$status" -eq 0 ]
  done
}

# --- (A) top-level key allowlist -------------------------------------------
@test "a forbidden top-level key (node_type) fails and is named" {
  canonical "$SANDBOX/feedback_bad.md"
  # insert a banned provenance key after the fence
  sed -i.bak '1a\
node_type: episode' "$SANDBOX/feedback_bad.md" && rm -f "$SANDBOX/feedback_bad.md.bak"
  run bash "$SCRIPT" "$SANDBOX/feedback_bad.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"node_type"* ]]
  [[ "$output" == *"forbidden top-level keys"* ]]
}

# --- (B) metadata key allowlist --------------------------------------------
@test "a forbidden metadata key (originSessionId) fails and is named" {
  canonical "$SANDBOX/feedback_bad.md"
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: feedback' '  scope: repo' '  originSessionId: abc123' '---' 'body' > "$SANDBOX/feedback_bad.md"
  run bash "$SCRIPT" "$SANDBOX/feedback_bad.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"originSessionId"* ]]
  [[ "$output" == *"forbidden metadata keys"* ]]
}

# --- (C) required name/description ------------------------------------------
@test "an empty name fails" {
  printf '%s\n' '---' 'name: ""' 'description: "cue"' 'metadata:' '  type: feedback' '  scope: repo' '---' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing/empty name"* ]]
}

@test "a missing description fails" {
  printf '%s\n' '---' 'name: "A Title"' 'metadata:' '  type: feedback' '  scope: repo' '---' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing/empty description"* ]]
}

# --- (D) required, non-empty metadata.type (open tag — value not enum-checked)
@test "a missing metadata.type fails" {
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  scope: repo' '---' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing/empty metadata.type"* ]]
}

@test "an unusual but non-empty type passes (type is an OPEN tag, not an enum)" {
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: architecture' '  scope: repo' '---' 'body' > "$SANDBOX/architecture_x.md"
  run bash "$SCRIPT" "$SANDBOX/architecture_x.md"
  [ "$status" -eq 0 ]
}

# --- (E) closed scope enum -------------------------------------------------
@test "an out-of-enum scope fails and is named" {
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: feedback' '  scope: galaxy' '---' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scope"* ]]
  [[ "$output" == *"galaxy"* ]]
}

@test "a missing scope fails" {
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: feedback' '---' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"scope"* ]]
}

# --- (F) parseability ------------------------------------------------------
@test "a file with no frontmatter fence fails" {
  printf '%s\n' 'just a body, no fence' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ---fenced frontmatter"* ]]
}

@test "a malformed closing fence (---garbage) is NOT accepted as a fence" {
  # The closing fence must be exactly '---' on its own line. A body line like
  # '---garbage' must not be mistaken for the closing fence and let a truncated
  # prefix validate. (Carnot finding, PR #883 cage-match.)
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: feedback' '  scope: repo' '---garbage' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ---fenced frontmatter"* ]]
}

@test "a clean closing fence with trailing whitespace is still accepted" {
  printf '%s\n' '---' 'name: "A Title"' 'description: "cue"' 'metadata:' '  type: feedback' '  scope: repo' '---  ' 'body' > "$SANDBOX/f.md"
  run bash "$SCRIPT" "$SANDBOX/f.md"
  [ "$status" -eq 0 ]
}

# --- multi-file semantics --------------------------------------------------
@test "all-valid batch exits 0; one bad file in the batch exits 1 and names only it" {
  canonical "$SANDBOX/good1.md"
  canonical "$SANDBOX/good2.md"
  printf '%s\n' '---' 'name: "x"' 'description: "y"' 'metadata:' '  type: feedback' '  scope: nope' '---' 'b' > "$SANDBOX/bad.md"
  run bash "$SCRIPT" "$SANDBOX/good1.md" "$SANDBOX/good2.md" "$SANDBOX/bad.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad.md"* ]]
  [[ "$output" != *"good1.md"* ]]
  [[ "$output" != *"good2.md"* ]]
}

# --- usage -----------------------------------------------------------------
@test "no arguments is a usage error (exit 2)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}
