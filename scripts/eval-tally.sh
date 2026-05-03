#!/usr/bin/env bash
# eval-tally.sh — settle the cage-match persona A/B experiment.
#
# Walks ~/.claude/persona-eval/claude-skills-PR-*/outcomes.json, joins each
# with its sibling mapping.json, and computes per-set accept / defer / reject
# rates plus unique-finding counts. Writes ~/.claude/persona-eval/tally.md and
# prints to stdout.
#
# Cohort scope: claude-skills only. Cross-repo eval dirs (e.g.
# tech_world-PR-310/) are intentionally excluded — they're observational data
# points, not part of the 10-PR experiment.
#
# A PR is "complete" iff every finding in its outcomes.json has a non-null
# action. Incomplete PRs are skipped (and listed at the top of the report so
# Nick can see what's outstanding).

set -euo pipefail

# Bash 4+ required for associative arrays (declare -A). macOS ships with
# bash 3.2 by default; install a current bash via Homebrew (`brew install
# bash`) and either run this script via `/opt/homebrew/bin/bash` or update
# the shebang locally. We re-exec under a 4+ shell when one is available.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [ -x "$candidate" ]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  echo "ERROR: bash 4+ required (found ${BASH_VERSION:-unknown}). Install via 'brew install bash'." >&2
  exit 1
fi

EVAL_ROOT="${HOME}/.claude/persona-eval"
TALLY_FILE="${EVAL_ROOT}/tally.md"
# Cohort prefix for the claude-skills 10-PR experiment. Cross-repo dirs
# (e.g. tech_world-PR-310/) deliberately don't match this prefix.
COHORT_PREFIX="claude-skills-PR-"

command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }

# Validate action vocabulary: any value outside the documented enum is a
# silent skew on the tally (e.g. a typo of "accepted" for "inline" would
# count toward {a,b}_total but not toward any of the per-action buckets,
# pulling the accept-rate down). Fail loud instead.
validate_action() {
  case "$1" in
    inline|deferred|rejected) return 0 ;;
    *) echo "ERROR: unknown action '$1' in outcomes (expected: inline|deferred|rejected)" >&2; return 1 ;;
  esac
}

complete_prs=()
incomplete_prs=()

for outcomes in "${EVAL_ROOT}/${COHORT_PREFIX}"*/outcomes.json; do
  [ -f "$outcomes" ] || continue
  dir=$(dirname "$outcomes")
  pr=$(basename "$dir" | sed "s/^${COHORT_PREFIX}//")
  mapping="${dir}/mapping.json"
  [ -f "$mapping" ] || { echo "WARN: $dir missing mapping.json — skipping" >&2; continue; }

  # All findings tagged?
  null_count=$(jq '[.findings[] | select(.action == null)] | length' "$outcomes")
  if [ "$null_count" -eq 0 ]; then
    complete_prs+=("$pr")
  else
    incomplete_prs+=("$pr (${null_count} untagged)")
  fi
done

# Aggregate per-set stats over complete PRs
declare -A counts
for eval_set in a b; do
  for action in inline deferred rejected total; do
    counts["${eval_set}_${action}"]=0
  done
done

unique_a=0
unique_b=0

# Build joined records: one row per finding with set + action
joined=$(mktemp)
trap 'rm -f "$joined"' EXIT

for pr in "${complete_prs[@]}"; do
  dir="${EVAL_ROOT}/${COHORT_PREFIX}${pr}"
  jq -r --slurpfile m "${dir}/mapping.json" '
    (.findings | map({(.id|tostring): .action}) | add) as $a
    | $m[0].findings
    | map(. + {action: $a[(.id|tostring)]})
    | .[]
    | [.id, .set, .reviewer, .action] | @tsv
  ' "${dir}/outcomes.json" | awk -v pr="$pr" '{print pr"\t"$0}' >> "$joined"
done

while IFS=$'\t' read -r pr id eval_set reviewer action; do
  validate_action "$action" || exit 1
  counts["${eval_set}_total"]=$((counts["${eval_set}_total"] + 1))
  counts["${eval_set}_${action}"]=$((counts["${eval_set}_${action}"] + 1))
done < "$joined"

# Per-PR unique findings: a finding is "unique to its set" if no finding from
# the OTHER set in the same PR shares the same source_line (cheap heuristic;
# refines if/when we add semantic dedup).
for pr in "${complete_prs[@]}"; do
  dir="${EVAL_ROOT}/${COHORT_PREFIX}${pr}"
  a_lines=$(jq -r '.findings[] | select(.set=="a") | .source_line' "${dir}/mapping.json" 2>/dev/null | sort -u)
  b_lines=$(jq -r '.findings[] | select(.set=="b") | .source_line' "${dir}/mapping.json" 2>/dev/null | sort -u)
  ua=$(comm -23 <(echo "$a_lines") <(echo "$b_lines") | grep -v '^$' | wc -l | tr -d ' ')
  ub=$(comm -13 <(echo "$a_lines") <(echo "$b_lines") | grep -v '^$' | wc -l | tr -d ' ')
  unique_a=$((unique_a + ua))
  unique_b=$((unique_b + ub))
done

pct() {
  local num=$1 den=$2
  if [ "$den" -eq 0 ]; then echo "n/a"; else awk "BEGIN { printf \"%.1f%%\", ($num/$den)*100 }"; fi
}

{
  echo "# Cage-match persona A/B tally"
  echo
  echo "_Generated $(date '+%Y-%m-%d %H:%M:%S')_"
  echo
  echo "## PRs evaluated"
  echo
  if [ "${#complete_prs[@]}" -eq 0 ]; then
    echo "_None complete yet._"
  else
    echo "Complete: ${#complete_prs[@]} — $(IFS=, ; echo "${complete_prs[*]}")"
  fi
  if [ "${#incomplete_prs[@]}" -gt 0 ]; then
    echo
    echo "Incomplete (skipped):"
    for p in "${incomplete_prs[@]}"; do echo "- PR-$p"; done
  fi
  echo
  echo "## Per-set rates"
  echo
  echo "| Set | Total | Inline (accept) | Deferred | Rejected | Accept rate | Defer rate | Reject rate |"
  echo "|-----|-------|-----------------|----------|----------|-------------|------------|-------------|"
  for eval_set in a b; do
    label=$([ "$eval_set" = "a" ] && echo "A (wrestling)" || echo "B (book)")
    t=${counts["${eval_set}_total"]}
    i=${counts["${eval_set}_inline"]}
    d=${counts["${eval_set}_deferred"]}
    r=${counts["${eval_set}_rejected"]}
    echo "| $label | $t | $i | $d | $r | $(pct $i $t) | $(pct $d $t) | $(pct $r $t) |"
  done
  echo
  echo "## Unique findings (raised by one set, not the other)"
  echo
  echo "- Set A unique: $unique_a"
  echo "- Set B unique: $unique_b"
  echo
  echo "_Heuristic: matched on \`source_line\` field in mapping.json. Tighten with semantic dedup if needed._"
  echo
  echo "## Verdict"
  echo
  ta=${counts["a_total"]}; tb=${counts["b_total"]}
  ai=${counts["a_inline"]}; bi=${counts["b_inline"]}
  if [ "$ta" -gt 0 ] && [ "$tb" -gt 0 ]; then
    a_rate=$(awk "BEGIN { printf \"%.3f\", $ai/$ta }")
    b_rate=$(awk "BEGIN { printf \"%.3f\", $bi/$tb }")
    echo "- Set A accept-rate: $a_rate"
    echo "- Set B accept-rate: $b_rate"
    echo
    if awk "BEGIN { exit !($a_rate > $b_rate) }"; then
      echo "**Set A leads** on accept rate. Set B unique = $unique_b vs Set A unique = $unique_a."
    elif awk "BEGIN { exit !($b_rate > $a_rate) }"; then
      echo "**Set B leads** on accept rate. Set B unique = $unique_b vs Set A unique = $unique_a."
    else
      echo "**Tied on accept rate.** Decide on unique-finding count or qualitative review."
    fi
  else
    echo "_Insufficient data — need at least one complete PR with findings from each set._"
  fi
} | tee "$TALLY_FILE"

echo
echo "Wrote $TALLY_FILE"
