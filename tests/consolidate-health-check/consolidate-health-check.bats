#!/usr/bin/env bats
# tests/consolidate-health-check/consolidate-health-check.bats — contract tests
# for scripts/consolidate-health-check.sh, the /consolidate IMMUNE RESPONSE
# (task #4 / issue #953). Pins the load-bearing behaviours so a future edit can't
# silently break the self-reporting discipline:
#   - SILENT unless a real breach (the graduation/eviction model — no nagging)
#   - exit 10 on breach (informational, not an error), exit 0 healthy, 2 usage
#   - the two snapshot checks (memory-health, eviction-budget) fire on the
#     thresholds they claim to, over caller-controlled fixtures
#   - wall-clock baseline stays INFO until >=3 datapoints, then drift-flags a spike
#
# Every check path is driven by fixtures via flags so no test touches Nick's real
# ~/.claude state.

load ../helpers

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
# dir. $1=dirname, remaining args are memory_usefulness scores: an int 1-5 for a
# graded memory, or `null` for a PHANTOM write (a memory the scorecard claimed but
# that was missing on disk at grading time — the signal memory-health counts).
mem() {
  local name="$1"; shift
  mkdir -p "$CORPUS/$name"
  {
    printf '{ "memory_usefulness": ['
    local first=1
    for s in "$@"; do
      [ "$first" -eq 1 ] || printf ', '
      first=0
      case "$s" in
        null) printf '{"score": null}' ;;
        *)    printf '{"score": %s}' "$s" ;;
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
  mem s1 5 4 3
  run_hc
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -z "$output" ] || fail "output=$output"
}

@test "empty corpus + tiny CLAUDE.md is healthy and silent" {
  run_hc
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -z "$output" ] || fail "output=$output"
}

# --- memory-health (phantom writes; replaced retired scorecard-health 2026-07-05) --
@test "memory-health breach: phantom writes fire (exit 10, names the check)" {
  mem s1 null null null 4 5     # 3/5 = 60% phantom > default 5%
  run_hc
  [ "$status" -eq 10 ] || fail "status=$status"
  [[ "$output" == *"Immune Response"* ]] || fail "output=$output"
  [[ "$output" == *"memory-health"* ]] || fail "output=$output"
  [[ "$output" == *"phantom"* ]] || fail "output=$output"
}

@test "memory-health GREEN: all real scores stays silent" {
  mem s1 5 4 3 2 1              # 0 phantom writes
  run_hc
  [ "$status" -eq 0 ] || fail "status=$status"
  [ -z "$output" ] || fail "output=$output"
}

@test "memory-health threshold is tunable via --phantom-pct" {
  mem s1 null null 4 5          # 2/4 = 50% phantom
  run_hc --phantom-pct 40       # lower bar => breach
  [ "$status" -eq 10 ] || fail "status=$status"
  run_hc --phantom-pct 60       # higher bar => green
  [ "$status" -eq 0 ] || fail "status=$status"
}

@test "--window limits which consolidations are counted" {
  mem a-old null null null       # oldest, all phantom
  mem b-new 5 4 3                # newest, all real
  run_hc --window 1     # only the newest (clean) counts => green
  [ "$status" -eq 0 ] || fail "status=$status"
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
  [ "$status" -eq 10 ] || fail "status=$status"
  [[ "$output" == *"eviction-budget"* ]] || fail "output=$output"
  [[ "$output" == *"budget"* ]] || fail "output=$output"
}

@test "eviction-budget only counts pointer lines, not prose" {
  : > "$CLAUDE_MD"
  # 2000 bytes of prose with NO feedback_*/concept_* pointer — must not count.
  head -c 2000 /dev/zero | tr '\0' 'x' >> "$CLAUDE_MD"
  printf -- '\n- one directive — concept_y.md (repo)\n' >> "$CLAUDE_MD"
  run_hc --budget 200
  [ "$status" -eq 0 ] || fail "status=$status"   # only the ~40-byte pointer line counts, under 200
  [ -z "$output" ] || fail "output=$output"
}

@test "missing CLAUDE.md SKIPs the budget check (not a breach)" {
  run_hc --claude-md "$SANDBOX/nope.md" --verbose
  [[ "$output" == *"eviction-budget"* ]] || fail "output=$output"
  [[ "$output" == *"not found"* ]] || fail "output=$output"
}

# --- wall-clock drift (robust + retry-aware) ----------------------------------
@test "wall-clock stays INFO until 5 clean datapoints" {
  # 5 datapoints: the last is the "current run", leaving 4 baseline -> still accruing.
  printf '{"wall_s":100}\n{"wall_s":110}\n{"wall_s":105}\n{"wall_s":108}\n{"wall_s":103}\n' > "$TIMING"
  run_hc --verbose
  [ "$status" -eq 0 ] || fail "status=$status"   # INFO is not a breach
  [[ "$output" == *"baseline accruing: 4/5"* ]] || fail "output=$output"   # 5 points - 1 current = 4 baseline
}

@test "wall-clock drift breaches when a RETRY-FREE latest run spikes past median+K·MAD" {
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":300}\n' > "$TIMING"
  run_hc
  [ "$status" -eq 10 ] || fail "status=$status"
  [[ "$output" == *"wall-clock-drift"* ]] || fail "output=$output"
  [[ "$output" == *"NO agent retry"* ]] || fail "output=$output"   # honest message: check for retries before regression
}

@test "a retry-inflated LATEST run is INFO, never a breach (the #6 fix)" {
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":2500,"retried":true}\n' > "$TIMING"
  run_hc --verbose
  [ "$status" -eq 0 ] || fail "status=$status"   # NOT a breach
  [[ "$output" == *"retry-inflated"* ]] || fail "output=$output"
}

@test "retried is STRICT boolean — a string \"false\" is NOT treated as retried (finding 3)" {
  # bool("false") would be True (non-empty string) and wrongly downgrade this spike to
  # INFO; `is True` keeps it as a real, breaching drift. Strings fail safe to not-retried.
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":300,"retried":"false"}\n' > "$TIMING"
  run_hc
  [ "$status" -eq 10 ] || fail "status=$status"
  [[ "$output" == *"wall-clock-drift"* ]] || fail "output=$output"
}

@test "a retried run is EXCLUDED from the baseline so it can't distort the fence" {
  # The 2500 retry is in the middle; without exclusion it would inflate the median
  # and mask the genuine 300 spike. With exclusion, the clean baseline (~100) flags 300.
  printf '{"wall_s":100}\n{"wall_s":102}\n{"wall_s":2500,"retried":true}\n{"wall_s":98}\n{"wall_s":101}\n{"wall_s":99}\n{"wall_s":300}\n' > "$TIMING"
  run_hc
  [ "$status" -eq 10 ] || fail "status=$status"
  [[ "$output" == *"wall-clock-drift"* ]] || fail "output=$output"
}

# --- output modes -------------------------------------------------------------
@test "--json emits a parseable object with a breach flag" {
  mem s1 null null null 4 5
  run_hc --json
  echo "$output" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["breach"] is True; assert any(c["name"]=="memory-health" for c in d["checks"])'
}

@test "--verbose shows GREEN lines even when healthy" {
  mem s1 5 4 3
  run_hc --verbose
  [ "$status" -eq 0 ] || fail "status=$status"
  [[ "$output" == *"all checks green"* ]] || fail "output=$output"
  [[ "$output" == *"memory-health"* ]] || fail "output=$output"
}

# --- usage --------------------------------------------------------------------
@test "unknown flag is a usage error (exit 2)" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ] || fail "status=$status"
}
