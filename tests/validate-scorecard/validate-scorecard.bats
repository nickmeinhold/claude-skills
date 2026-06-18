#!/usr/bin/env bats
# tests/validate-scorecard/validate-scorecard.bats — contract tests for
# scripts/validate-scorecard.sh, the CANONICAL /consolidate scorecard schema
# (issue #885). Pins each schema rule so a future edit can't silently loosen the
# gate that consolidate step 4a + Wrap-up both delegate to. The drift these tests
# guard against is the real 2026-06-17 failure: predictions[]={id,claim,
# verifiable_by} + top-level {project,session_label,scores,...}.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/validate-scorecard.sh"
  SANDBOX="$(mktemp -d)"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# A fully-canonical scorecard; callers mutate it to test each rule.
canonical() {
  cat > "$1" <<'EOF'
{
  "schema_version": 2,
  "session_date": "2026-06-17",
  "memory_dir": "/Users/x/memory",
  "memories_written": ["/Users/x/memory/feedback_a.md"],
  "memories_updated": [],
  "index_edits": 1,
  "errors_triaged": 0,
  "memory_index_over_budget": false,
  "predictions": [
    {"text": "X will happen", "basis": "evidence"}
  ],
  "notes": ""
}
EOF
}

# --- happy path ------------------------------------------------------------
@test "a canonical scorecard passes (exit 0, no output)" {
  canonical "$SANDBOX/scorecard.json"
  run bash "$SCRIPT" "$SANDBOX/scorecard.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the real 2026-06-17 drift ---------------------------------------------
@test "the real 2026-06-17 drift is caught (wrong top-level + wrong prediction keys)" {
  cat > "$SANDBOX/scorecard.json" <<'EOF'
{
  "project": "claude-skills",
  "session_label": "x",
  "scores": {"impact": 5},
  "score_notes": "n",
  "verified_files": [],
  "predictions": [{"id": 1, "claim": "y", "verifiable_by": "z", "confidence": 0.8}]
}
EOF
  run bash "$SCRIPT" "$SANDBOX/scorecard.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"forbidden top-level keys"* ]]
  [[ "$output" == *"project"* ]]
  [[ "$output" == *"predictions[0] forbidden keys"* ]]
  [[ "$output" == *"claim"* ]]
}

# --- (top-level) exact key set ---------------------------------------------
@test "an extra top-level key is forbidden" {
  canonical "$SANDBOX/s.json"
  # inject an alias key
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_label"]="x"; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"forbidden top-level keys"* ]]
  [[ "$output" == *"session_label"* ]]
}

@test "a missing required top-level key is caught" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["memories_written"]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing top-level keys"* ]]
  [[ "$output" == *"memories_written"* ]]
}

# --- predictions[] shape ---------------------------------------------------
@test "a prediction missing text is caught (the grader reads text)" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["predictions"]=[{"basis":"b"}]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"predictions[0] missing"* ]]
  [[ "$output" == *"text"* ]]
}

@test "an empty-string prediction text is caught" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["predictions"]=[{"text":"  ","basis":"b"}]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"text must be a non-empty string"* ]]
}

# --- predictions[] narrowing (2026-06-18): confidence removed, capped at 2 ---
@test "a confidence key is now a forbidden extra (removed 2026-06-18)" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["predictions"]=[{"text":"x","basis":"b","confidence":0.5}]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"predictions[0] forbidden keys"* ]]
  [[ "$output" == *"confidence"* ]]
}

@test "more than 2 predictions is caught (narrowed to same-session-verifiable bets)" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["predictions"]=[{"text":"a","basis":"b"},{"text":"c","basis":"d"},{"text":"e","basis":"f"}]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most 2 allowed"* ]]
}

@test "exactly 2 predictions passes (the cap boundary)" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["predictions"]=[{"text":"a","basis":"b"},{"text":"c","basis":"d"}]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 0 ]
}

@test "notes is OPTIONAL — a scorecard without notes still passes" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); del d["notes"]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 0 ]
}

@test "a non-string notes (when present) is caught" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["notes"]=123; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"notes must be string"* ]]
}

# --- scalar types ----------------------------------------------------------
@test "a non-bool memory_index_over_budget is caught" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["memory_index_over_budget"]="false"; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"memory_index_over_budget must be bool"* ]]
}

@test "memories_written containing a non-string is caught" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["memories_written"]=[123]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"memories_written must be array of absolute-path strings"* ]]
}

@test "a relative path in memories_written is caught (absolute paths required)" {
  canonical "$SANDBOX/s.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["memories_written"]=["relative.md"]; json.dump(d,open(sys.argv[1],"w"))' "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"memories_written must be array of absolute-path strings"* ]]
}

# --- malformed input -------------------------------------------------------
@test "invalid JSON is caught, not crashed on" {
  printf '%s' '{not json' > "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not valid JSON"* ]]
}

@test "a JSON array (not object) at top level is caught" {
  printf '%s' '[]' > "$SANDBOX/s.json"
  run bash "$SCRIPT" "$SANDBOX/s.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a JSON object"* ]]
}

# --- usage -----------------------------------------------------------------
@test "no arguments is a usage error (exit 2)" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}
