#!/usr/bin/env bats
# tests/heal-memory-dir/heal-memory-dir.bats — contract tests for
# scripts/heal-memory-dir.sh, the ONE-PASS self-heal+validate driver that replaces
# the memory-writer's hand-rolled detect→normalize→validate loop (one agent round-trip
# instead of ~9-12). These pin: clean dirs are no-ops, drift is healed preserve-first,
# non-memory artifacts are skipped (issue #936), the --written fast path is scoped, and
# heal's verdict can never disagree with the canonical validator (shared module).

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
  [ "$status" -eq 0 ]
  [[ "$output" == *"healed=0"* ]]
}

@test "a clean file is left byte-for-byte untouched (no spurious rewrite)" {
  canonical "$SANDBOX/feedback_a.md"
  before="$(cat "$SANDBOX/feedback_a.md")"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/feedback_a.md")" = "$before" ]
}

# --- drift is healed, preserve-first ---------------------------------------
@test "banned provenance is stripped and the file becomes valid" {
  drifted "$SANDBOX/feedback_a.md" repo
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"healed=1"* ]]
  run bash "$VALIDATE" "$SANDBOX/feedback_a.md"
  [ "$status" -eq 0 ]
  ! grep -q 'node_type\|originSessionId' "$SANDBOX/feedback_a.md"
}

@test "scope: universal is preserved through a heal, never clobbered to repo" {
  drifted "$SANDBOX/feedback_a.md" universal
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  grep -q 'scope: universal' "$SANDBOX/feedback_a.md"
}

@test "the body survives a heal byte-for-byte" {
  drifted "$SANDBOX/feedback_a.md" repo
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  grep -q 'body that must survive byte-for-byte.' "$SANDBOX/feedback_a.md"
}

@test "heal is idempotent — a second pass heals nothing" {
  drifted "$SANDBOX/feedback_a.md" meta
  run bash "$HEAL" "$SANDBOX" --no-llm; [ "$status" -eq 0 ]
  first="$(cat "$SANDBOX/feedback_a.md")"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"healed=0"* ]]
  [ "$(cat "$SANDBOX/feedback_a.md")" = "$first" ]
}

# --- issue #936: non-memory artifacts are skipped, never flagged ------------
@test "a non-memory-prefix artifact (claude-md-candidates.md) is skipped, not flagged" {
  canonical "$SANDBOX/feedback_a.md"
  printf -- '- a graduation candidate line\n' > "$SANDBOX/claude-md-candidates.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped=1"* ]]
  [[ "$output" != *"INVALID"* ]]
}

@test "index files (MEMORY.md / MEMORY.*.md) are skipped" {
  canonical "$SANDBOX/feedback_a.md"
  printf '# MEMORY index\n' > "$SANDBOX/MEMORY.md"
  printf '# feedback shard\n' > "$SANDBOX/MEMORY.feedback.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped=2"* ]]
}

# --- --written fast path ----------------------------------------------------
@test "--written processes only the named files" {
  drifted "$SANDBOX/feedback_a.md" repo
  drifted "$SANDBOX/concept_b.md" repo
  run bash "$HEAL" "$SANDBOX" --written feedback_a.md --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"scanned=1"* ]]
  # concept_b.md was NOT named, so it stays drifted
  grep -q 'node_type' "$SANDBOX/concept_b.md"
}

@test "--written naming a non-memory file skips it without flagging" {
  printf 'not a memory file\n' > "$SANDBOX/notes.md"
  run bash "$HEAL" "$SANDBOX" --written notes.md --no-llm
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip (not a memory file): notes.md"* ]]
}

# --- unfixable files surface as INVALID, exit 1 ----------------------------
@test "an unfixable file (missing description, --no-llm) is INVALID and exits 1" {
  printf -- '---\nname: "Has Name"\nmetadata:\n  type: concept\n  scope: repo\n---\n# x\nbody\n' > "$SANDBOX/concept_x.md"
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID concept_x.md"* ]]
  [[ "$output" == *"FAILED=1"* ]]
}

# --- equivalence: heal's post-pass state always validates ------------------
@test "after heal, the whole dir passes the canonical validator" {
  canonical "$SANDBOX/feedback_a.md"
  drifted "$SANDBOX/concept_b.md" universal
  drifted "$SANDBOX/user_c.md" meta
  run bash "$HEAL" "$SANDBOX" --no-llm
  [ "$status" -eq 0 ]
  run bash "$VALIDATE" "$SANDBOX"/*.md
  [ "$status" -eq 0 ]
}

# --- usage -----------------------------------------------------------------
@test "a missing directory is a usage error (exit 2)" {
  run bash "$HEAL" "$SANDBOX/does-not-exist"
  [ "$status" -eq 2 ]
}

@test "no arguments is a usage error (exit 2)" {
  run bash "$HEAL"
  [ "$status" -eq 2 ]
}
