#!/usr/bin/env bats
# tests/consolidate-health-check/consolidate-health-check.bats — contract tests
# for scripts/consolidate-health-check.sh, the /consolidate IMMUNE RESPONSE
# (task #4 / issue #953). Pins the load-bearing behaviours so a future edit can't
# silently break the self-reporting discipline:
#   - SILENT unless a real breach (the graduation/eviction model — no nagging)
#   - exit 10 on breach (informational, not an error), exit 0 healthy, 2 usage
#   - the two snapshot checks (scorecard-health, eviction-budget) fire on the
#     thresholds they claim to, over caller-controlled fixtures
#   - wall-clock baseline stays INFO until >=3 datapoints, then drift-flags a spike
#
# Every check path is driven by fixtures via flags so no test touches Nick's real
# ~/.claude state.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/consolidate-health-check.sh"
  SANDBOX="$(mktemp -d)"
  CORPUS="$SANDBOX/corpus"
  mkdir -p "$CORPUS"
  # A CLAUDE.md with a single tiny directive pointer line — well under budget.
  CLAUDE_MD="$SANDBOX/CLAUDE.md"
  printf -- '- A directive — feedback_x.md (universal)\n' > "$CLAUDE_MD"
  TIMING="$SANDBOX/timing.jsonl"
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}

# Write a readtime-score.json fixture into the corpus under a timestamp-shaped
# dir. $1=dirname, remaining args are verdict tokens (true|false|unresolved|<other>).
score() {
  local name="$1"; shift
  mkdir -p "$CORPUS/$name"
  {
    printf '{ "prediction_results": ['
    local first=1
    for v in "$@"; do
      [ "$first" -eq 1 ] || printf ', '
      first=0
      case "$v" in
        true|false)  printf '{"actually_true": %s}' "$v" ;;
        unresolved)  printf '{"actually_true": "unresolved"}' ;;
        *)           printf '{"actually_true": "%s"}' "$v" ;;  # malformed/free-text
      esac
    done
    printf '] }'
  } > "$CORPUS/$name/readtime-score.json"
}

run_hc() {
  run bash "$SCRIPT" --corpus-glob "$CORPUS/*/readtime-score.json" \
    --claude-md "$CLAUDE_MD" --timing "$TIMING" "$@"
}

# --- silent-unless-breach (the core discipline) -------------------------------
@test "healthy state is SILENT and exits 0" {
  score s1 true true false
  run_hc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty corpus + tiny CLAUDE.md is healthy and silent" {
  run_hc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- scorecard-health ---------------------------------------------------------
@test "scorecard breach: mostly-unresolved fires (exit 10, names the check)" {
  score s1 unresolved unresolved unresolved unresolved true
  run_hc
  [ "$status" -eq 10 ]
  [[ "$output" == *"Immune Response"* ]]
  [[ "$output" == *"scorecard-health"* ]]
  [[ "$output" == *"unresolvable"* ]]
}

@test "scorecard GREEN: mostly-resolved stays silent" {
  score s1 true true true false unresolved
  run_hc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "malformed verdicts breach on their own threshold" {
  # 3 free-text (malformed) of 5 = 60% > default 25% malformed-pct
  score s1 garbage maybe probably true false
  run_hc
  [ "$status" -eq 10 ]
  [[ "$output" == *"scorecard-health"* ]]
  [[ "$output" == *"malformed"* ]]
}

@test "scorecard threshold is tunable via --unresolvable-pct" {
  score s1 unresolved unresolved true true   # 50% unresolvable
  run_hc --unresolvable-pct 40               # lower bar => breach
  [ "$status" -eq 10 ]
  run_hc --unresolvable-pct 60               # higher bar => green
  [ "$status" -eq 0 ]
}

@test "--window limits which consolidations are counted" {
  score a-old unresolved unresolved unresolved   # old, all unresolved
  score b-new true true true                      # newest, all resolved
  run_hc --window 1     # only the newest (resolved) counts => green
  [ "$status" -eq 0 ]
}

# --- eviction-budget ----------------------------------------------------------
@test "eviction-budget breach when directive layer exceeds --budget" {
  # Build a CLAUDE.md whose pointer lines exceed a small budget.
  : > "$CLAUDE_MD"
  # Pointer filenames are lowercase-underscore only (the regex is feedback_[a-z_]+\.md,
  # mirroring the eviction audit) — keep the fixture faithful to that convention.
  for i in $(seq 1 50); do
    printf -- '- Directive number %s with a feedback_pointer.md backing file (universal)\n' "$i" >> "$CLAUDE_MD"
  done
  run_hc --budget 200
  [ "$status" -eq 10 ]
  [[ "$output" == *"eviction-budget"* ]]
  [[ "$output" == *"budget"* ]]
}

@test "eviction-budget only counts pointer lines, not prose" {
  : > "$CLAUDE_MD"
  # 2000 bytes of prose with NO feedback_*/concept_* pointer — must not count.
  head -c 2000 /dev/zero | tr '\0' 'x' >> "$CLAUDE_MD"
  printf -- '\n- one directive — concept_y.md (repo)\n' >> "$CLAUDE_MD"
  run_hc --budget 200
  [ "$status" -eq 0 ]   # only the ~40-byte pointer line counts, under 200
  [ -z "$output" ]
}

@test "missing CLAUDE.md SKIPs the budget check (not a breach)" {
  run_hc --claude-md "$SANDBOX/nope.md" --verbose
  [[ "$output" == *"eviction-budget"* ]]
  [[ "$output" == *"not found"* ]]
}

# --- wall-clock drift (robust + retry-aware) ----------------------------------
@test "wall-clock stays INFO until 5 clean datapoints" {
  printf '{"wall_s": 100}\n{"wall_s": 110}\n{"wall_s": 105}\n{"wall_s": 108}\n' > "$TIMING"
  run_hc --verbose
  [[ "$output" == *"baseline accruing: 4/5"* ]]
  [ "$status" -eq 0 ]   # INFO is not a breach
}

@test "wall-clock drift breaches when a RETRY-FREE latest run spikes past median+K·MAD" {
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":300}\n' > "$TIMING"
  run_hc
  [ "$status" -eq 10 ]
  [[ "$output" == *"wall-clock-drift"* ]]
  [[ "$output" == *"NO agent retry"* ]]   # honest message: check for retries before regression
}

@test "a retry-inflated LATEST run is INFO, never a breach (the #6 fix)" {
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":2500,"retried":true}\n' > "$TIMING"
  run_hc --verbose
  [ "$status" -eq 0 ]   # NOT a breach
  [[ "$output" == *"retry-inflated"* ]]
}

@test "a retried run is EXCLUDED from the baseline so it can't distort the fence" {
  # The 2500 retry is in the middle; without exclusion it would inflate the median
  # and mask the genuine 300 spike. With exclusion, the clean baseline (~100) flags 300.
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":2500,"retried":true}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":300}\n' > "$TIMING"
  run_hc
  [ "$status" -eq 10 ]
  [[ "$output" == *"wall-clock-drift"* ]]
}

# --- output modes -------------------------------------------------------------
@test "--json emits a parseable object with a breach flag" {
  score s1 unresolved unresolved unresolved unresolved true
  run_hc --json
  echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["breach"] is True; assert any(c["name"]=="scorecard-health" for c in d["checks"])'
}

@test "--verbose shows GREEN lines even when healthy" {
  score s1 true true false
  run_hc --verbose
  [ "$status" -eq 0 ]
  [[ "$output" == *"all checks green"* ]]
  [[ "$output" == *"scorecard-health"* ]]
}

# --- usage --------------------------------------------------------------------
@test "unknown flag is a usage error (exit 2)" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
}
