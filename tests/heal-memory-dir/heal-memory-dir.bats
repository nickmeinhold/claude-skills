#!/usr/bin/env bats
# tests/heal-memory-dir/heal-memory-dir.bats — contract tests for
# scripts/heal-memory-dir.sh, the ONE-PASS self-heal+validate driver that replaces
# the memory-writer's hand-rolled detect→normalize→validate loop (one agent round-trip
# instead of ~9-12). These pin: clean dirs are no-ops, drift is healed preserve-first,
# non-memory artifacts are skipped (issue #936), the --written fast path is scoped, and
# heal's verdict can never disagree with the canonical validator (shared module).

load ../helpers

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  HEAL="${REPO_ROOT}/scripts/heal-memory-dir.sh"
  VALIDATE="${REPO_ROOT}/scripts/validate-memory-frontmatter.sh"
  SANDBOX="$(mktemp -d)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

canonical() {  # $1 = path
  cat > "$1" <<'EOF'
---
name: "A Title"
description: "one-line retrieval cue"
metadata:
  type: feedback
  scope: repo
---

# A Title

body text preserved verbatim.
EOF
}

drifted() {  # $1 = path, $2 = scope (to prove preserve-first)
  cat > "$1" <<EOF
---
name: "Drift"
description: "harness re-stamped this"
metadata:
  type: feedback
  scope: ${2:-repo}
  node_type: memory
  originSessionId: sess-abc-123
---

# Drift

body that must survive byte-for-byte.
EOF
}

# --- clean dir is a no-op ---------------------------------------------------
@test "a fully-clean dir heals nothing and exits 0" {
  canonical "$SANDBOX/feedback_a.md"
  canonical "$SANDBOX/concept_b.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"healed=0"* ]] || fail "output=$output"
}

@test "a clean file is left byte-for-byte untouched (no spurious rewrite)" {
  canonical "$SANDBOX/feedback_a.md"
  before="$(cat "$SANDBOX/feedback_a.md")"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(cat "$SANDBOX/feedback_a.md")" = "$before" ] || fail
}

# --- drift is healed, preserve-first ---------------------------------------
@test "banned provenance is stripped and the file becomes valid" {
  drifted "$SANDBOX/feedback_a.md" repo
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"healed=1"* ]] || fail "output=$output"
  run bash "$VALIDATE" "$SANDBOX/feedback_a.md"
  [ "$status" -eq 0 ] || fail "status=$status"
  ! grep -q 'node_type\|originSessionId' "$SANDBOX/feedback_a.md" || fail
}

@test "scope: universal is preserved through a heal, never clobbered to repo" {
  drifted "$SANDBOX/feedback_a.md" universal
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  grep -q 'scope: universal' "$SANDBOX/feedback_a.md"
}

@test "the body survives a heal byte-for-byte" {
  drifted "$SANDBOX/feedback_a.md" repo
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  grep -q 'body that must survive byte-for-byte.' "$SANDBOX/feedback_a.md"
}

@test "heal is idempotent — a second pass heals nothing" {
  drifted "$SANDBOX/feedback_a.md" meta
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  first="$(cat "$SANDBOX/feedback_a.md")"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"healed=0"* ]] || fail "output=$output"
  [ "$(cat "$SANDBOX/feedback_a.md")" = "$first" ] || fail
}

# --- issue #936: non-memory artifacts are skipped, never flagged ------------
@test "a non-memory-prefix artifact (claude-md-candidates.md) is skipped, not flagged" {
  canonical "$SANDBOX/feedback_a.md"
  printf -- '- a graduation candidate line\n' > "$SANDBOX/claude-md-candidates.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"skipped=1"* ]] || fail "output=$output"
  [[ "$output" != *"INVALID"* ]] || fail "output=$output"
}

@test "index files (MEMORY.md / MEMORY.*.md) are skipped" {
  canonical "$SANDBOX/feedback_a.md"
  printf '# MEMORY index\n' > "$SANDBOX/MEMORY.md"
  printf '# feedback shard\n' > "$SANDBOX/MEMORY.feedback.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"skipped=2"* ]] || fail "output=$output"
}

# --- --written fast path ----------------------------------------------------
@test "--written processes only the named files" {
  drifted "$SANDBOX/feedback_a.md" repo
  drifted "$SANDBOX/concept_b.md" repo
  run bash "$HEAL" "$SANDBOX" --written feedback_a.md --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"scanned=1"* ]] || fail "output=$output"
  # concept_b.md was NOT named, so it stays drifted
  grep -q 'node_type' "$SANDBOX/concept_b.md"
}

@test "--written naming a non-memory file skips it without flagging" {
  printf 'not a memory file\n' > "$SANDBOX/notes.md"
  run bash "$HEAL" "$SANDBOX" --written notes.md --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"skip (not a memory file): notes.md"* ]] || fail "output=$output"
}

# --- unfixable files surface as INVALID, exit 1 ----------------------------
@test "an unfixable file (missing description, --no-llm) is INVALID and exits 1" {
  printf -- '---\nname: "Has Name"\nmetadata:\n  type: concept\n  scope: repo\n---\n# x\nbody\n' > "$SANDBOX/concept_x.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 1 ] || fail "status=$status"
  [[ "$output" == *"INVALID concept_x.md"* ]] || fail "output=$output"
  [[ "$output" == *"FAILED=1"* ]] || fail "output=$output"
}

# --- equivalence: heal's post-pass state always validates ------------------
@test "after heal, the whole dir passes the canonical validator" {
  canonical "$SANDBOX/feedback_a.md"
  drifted "$SANDBOX/concept_b.md" universal
  drifted "$SANDBOX/user_c.md" meta
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  run bash "$VALIDATE" "$SANDBOX"/*.md
  [ "$status" -eq 0 ] || fail "status=$status"
}

# --- Carnot PR #80 findings ------------------------------------------------
@test "agent_* is treated as a memory file and healed (KNOWN_PREFIXES gap, finding 1)" {
  drifted "$SANDBOX/agent_x.md" repo
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"healed=1"* ]] || fail "output=$output"   # not skipped as a non-memory file
  ! grep -q 'node_type' "$SANDBOX/agent_x.md" || fail
}

@test "a YAML-sensitive metadata.type survives a heal as a quoted scalar (finding 3)" {
  # A VALID file carrying a quoted reserved-word type ("yes") plus drift (node_type).
  # The rebuild must re-quote the type, not emit bare `type: yes` (which re-parses to a
  # boolean and fails certification). If the emitter quoted it wrong, heal would exit 1.
  printf -- '---\nname: "T"\ndescription: "d"\nmetadata:\n  type: "yes"\n  scope: repo\n  node_type: memory\n---\nbody\n' > "$SANDBOX/feedback_y.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"healed=1"* ]] || fail "output=$output"
  run bash "$VALIDATE" "$SANDBOX/feedback_y.md"
  [ "$status" -eq 0 ] || fail "status=$status"
  grep -q 'type: "yes"' "$SANDBOX/feedback_y.md"
}

@test "empty --written is a no-op (scanned=0, exit 0)" {
  canonical "$SANDBOX/feedback_a.md"
  run bash "$HEAL" "$SANDBOX" --written --no-llm
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"scanned=0"* ]] || fail "output=$output"
}

@test "--written a path OUTSIDE MEMORY_DIR is refused, exit 1 (finding 2, fail-closed)" {
  OUTSIDE="$(mktemp -d)"
  drifted "$OUTSIDE/feedback_evil.md" repo
  run bash "$HEAL" "$SANDBOX" --written "$OUTSIDE/feedback_evil.md" --no-llm
  [ "$status" -eq 1 ] || fail "status=$status"
  [[ "$output" == *"refused"* ]] || fail "output=$output"
  # the outside file was NOT mutated
  grep -q 'node_type' "$OUTSIDE/feedback_evil.md"
  rm -rf "$OUTSIDE"
}

# --- usage -----------------------------------------------------------------
@test "a missing directory is a usage error (exit 2)" {
  run bash "$HEAL" "$SANDBOX/does-not-exist"
  [ "$status" -eq 2 ] || fail "status=$status"
}

@test "no arguments is a usage error (exit 2)" {
  run bash "$HEAL"
  [ "$status" -eq 2 ] || fail "status=$status"
}
