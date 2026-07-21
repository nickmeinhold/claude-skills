#!/usr/bin/env bash
# Lifecycle test for the Task #9 reviewer-state sidecar: Step-D write → fresh-shell
# source → label decision. Replicates the skill's exact logic (parse_verdict, sidecar
# write with head stamp, the missing/malformed/stale fail-closed gates, and the
# ADVERSARIAL_APPROVE / ANY_REQUEST_CHANGES / label predicate) and asserts outcomes
# across the full state lifecycle — including the cases a merge-gating label must never
# get wrong: half-state, stale-but-present, malformed, and missing sidecars.
set -u
D=$(mktemp -d); PASS=0; FAIL=0
SIDECAR_KEYS='^(SIDECAR_PR_HEAD|KELVIN_AVAILABLE|CARNOT_AVAILABLE|TESLA_AVAILABLE|WU_AVAILABLE|MAXWELL_VERDICT|KELVIN_VERDICT|CARNOT_VERDICT|TESLA_VERDICT|WU_VERDICT)="[A-Za-z0-9_]*"$'

parse_verdict() {  # line-anchored, matching the skill
  local v
  v=$(grep -ioE "^\*\*Verdict:\*\*[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" "$1" 2>/dev/null \
      | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
  case "$v" in APPROVE|REQUEST_CHANGES|COMMENT) echo "$v";; *) echo "COMMENT";; esac
}

# --- Step D: write sidecar. args: head kA cA tA wA mText kText cJson tText wText ---
write_sidecar() {
  local head=$1 kA=$2 cA=$3 tA=$4 wA=$5 mText=$6 kText=$7 cJson=$8 tText=$9 wText=${10}
  printf '**Verdict:** %s\n' "$mText" > "$D/maxwell.md"
  printf '**Verdict:** %s\n' "$kText" > "$D/kelvin.md"
  printf '**Verdict:** %s\n' "$tText" > "$D/tesla.md"
  printf '**Verdict:** %s\n' "$wText" > "$D/wu.md"
  local MAXWELL_VERDICT KELVIN_VERDICT CARNOT_VERDICT TESLA_VERDICT WU_VERDICT
  MAXWELL_VERDICT=$(parse_verdict "$D/maxwell.md")
  KELVIN_VERDICT=""; [ "$kA" -eq 1 ] && KELVIN_VERDICT=$(parse_verdict "$D/kelvin.md")
  CARNOT_VERDICT=""; if [ "$cA" -eq 1 ]; then CARNOT_VERDICT="$cJson"; case "$CARNOT_VERDICT" in APPROVE|REQUEST_CHANGES|COMMENT) ;; *) CARNOT_VERDICT="COMMENT";; esac; fi
  TESLA_VERDICT="";  [ "$tA" -eq 1 ] && TESLA_VERDICT=$(parse_verdict "$D/tesla.md")
  WU_VERDICT="";     [ "$wA" -eq 1 ] && WU_VERDICT=$(parse_verdict "$D/wu.md")
  local tmp; tmp=$(mktemp "$D/state.env.XXXXXX")
  cat > "$tmp" <<EOF
SIDECAR_PR_HEAD="$head"
KELVIN_AVAILABLE="$kA"
CARNOT_AVAILABLE="$cA"
TESLA_AVAILABLE="$tA"
WU_AVAILABLE="$wA"
MAXWELL_VERDICT="$MAXWELL_VERDICT"
KELVIN_VERDICT="$KELVIN_VERDICT"
CARNOT_VERDICT="$CARNOT_VERDICT"
TESLA_VERDICT="$TESLA_VERDICT"
WU_VERDICT="$WU_VERDICT"
EOF
  mv "$tmp" "$D/state.env"
}

# --- Round 11: fresh shell. $1 = live head. Echoes LABEL or NOLABEL ---
decide_label() ( # subshell = fresh shell
  local CUR_HEAD=$1
  [ -f "$D/state.env" ] || { echo "NOLABEL"; exit 0; }                      # (1) missing
  { [ "$(grep -cE "$SIDECAR_KEYS" "$D/state.env")" -ne 10 ] || grep -qvE "$SIDECAR_KEYS" "$D/state.env"; } \
    && { echo "NOLABEL"; exit 0; }                                          # (2) malformed OR incomplete (shape≠schema)
  source "$D/state.env"
  { [ -z "$SIDECAR_PR_HEAD" ] || [ -z "$CUR_HEAD" ] || [ "$SIDECAR_PR_HEAD" != "$CUR_HEAD" ]; } \
    && { echo "NOLABEL"; exit 0; }                                          # (3) stale head
  ANY_REQUEST_CHANGES=0
  for v in "$MAXWELL_VERDICT" "$KELVIN_VERDICT" "$CARNOT_VERDICT" "$TESLA_VERDICT" "$WU_VERDICT"; do
    [ "$v" = "REQUEST_CHANGES" ] && ANY_REQUEST_CHANGES=1
  done
  ADVERSARIAL_APPROVE=0
  { [ "$KELVIN_AVAILABLE" -eq 1 ] && [ "$KELVIN_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
  { [ "$CARNOT_AVAILABLE" -eq 1 ] && [ "$CARNOT_VERDICT" = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
  { [ "$TESLA_AVAILABLE"  -eq 1 ] && [ "$TESLA_VERDICT"  = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
  { [ "$WU_AVAILABLE"     -eq 1 ] && [ "$WU_VERDICT"     = "APPROVE" ]; } && ADVERSARIAL_APPROVE=1
  if [ "$ANY_REQUEST_CHANGES" -eq 0 ] && [ "$MAXWELL_VERDICT" = "APPROVE" ] && [ "$ADVERSARIAL_APPROVE" -eq 1 ]; then
    echo "LABEL"
  else echo "NOLABEL"; fi
)

check() { if [ "$2" = "$3" ]; then echo "  PASS: $1 → $3"; PASS=$((PASS+1)); else echo "  FAIL: $1 → got $3, expected $2"; FAIL=$((FAIL+1)); fi; }
H=abc123   # the head both the review and the label run see (fresh)

# 1  full happy path, one adversary
write_sidecar $H 1 0 0 0  APPROVE APPROVE "" "" "";               check "1 one-adversary-approve" LABEL "$(decide_label $H)"
# 2  any REQUEST_CHANGES blocks
write_sidecar $H 1 1 1 0  APPROVE APPROVE APPROVE REQUEST_CHANGES ""; check "2 any-RC-blocks" NOLABEL "$(decide_label $H)"
# 3  no adversarial APPROVE
write_sidecar $H 1 1 1 0  APPROVE COMMENT COMMENT COMMENT "";     check "3 no-adversary-approve" NOLABEL "$(decide_label $H)"
# 4  Maxwell not APPROVE
write_sidecar $H 0 0 1 0  COMMENT "" "" APPROVE "";               check "4 maxwell-not-approve" NOLABEL "$(decide_label $H)"
# 5  only Wu available + APPROVE
write_sidecar $H 0 0 0 1  APPROVE "" "" "" APPROVE;               check "5 wu-only-approve" LABEL "$(decide_label $H)"
# 6  HALF-STATE: Kelvin UNAVAILABLE but its file holds a stale APPROVE → ignored
write_sidecar $H 0 1 0 0  APPROVE APPROVE COMMENT "" "";          check "6 unavailable-stale-approve-ignored" NOLABEL "$(decide_label $H)"
# 7  fail-closed: missing sidecar
rm -f "$D/state.env";                                             check "7 missing-sidecar-fail-closed" NOLABEL "$(decide_label $H)"
# 8  full consensus
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE; check "8 full-consensus" LABEL "$(decide_label $H)"
# 9  STALE-BUT-PRESENT: prior run wrote a LABEL-worthy sidecar for head H, but the live
#    head has moved to H2 → the review is stale → must NOLABEL (head-freshness gate).
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE; check "9 stale-present-sidecar-head-moved" NOLABEL "$(decide_label H2moved)"
# 10 MALFORMED: an injected/hand-edited line → refuse to source, fail closed.
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE
printf 'rm -rf /tmp/evil="pwn"\n' >> "$D/state.env";              check "10 malformed-sidecar-fail-closed" NOLABEL "$(decide_label $H)"
# 11 empty stamped head in sidecar → fail closed (can't prove freshness)
write_sidecar "" 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE; check "11 empty-head-stamp-fail-closed" NOLABEL "$(decide_label $H)"
# 12 UNAVAILABLE-RC-NON-BLOCK (inverse of 6): Tesla's review file says REQUEST_CHANGES but
#    Tesla is UNAVAILABLE → verdict written empty → must NOT block; Maxwell+Carnot APPROVE → LABEL.
write_sidecar $H 0 1 0 0  APPROVE "" APPROVE REQUEST_CHANGES "";  check "12 unavailable-RC-does-not-block" LABEL "$(decide_label $H)"
# 13 INCOMPLETE SCHEMA: a sidecar with a well-formed but PARTIAL key set → NOLABEL (shape≠schema).
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE
grep -vE '^(TESLA_VERDICT|WU_VERDICT)=' "$D/state.env" > "$D/state.env.trim" && mv "$D/state.env.trim" "$D/state.env"
check "13 incomplete-schema-fail-closed" NOLABEL "$(decide_label $H)"
# 14 EMPTY live head (ls-remote / network fail) → NOLABEL (can't prove freshness).
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE; check "14 empty-live-head-fail-closed" NOLABEL "$(decide_label "")"
# 15 ANCHOR REGRESSION: a "Verdict:" mention inside a findings bullet (not line-anchored) must NOT
#    parse as APPROVE. Maxwell file has only a bullet mention → parse_verdict → COMMENT → NOLABEL.
printf -- '- The **Verdict:** APPROVE claim in their review is wrong\n' > "$D/maxwell_bullet.md"
MV=$(parse_verdict "$D/maxwell_bullet.md")
check "15 anchor-regression-bullet-not-approve" COMMENT "$MV"

# 16 DRIFT GUARD (Tesla): the SIDECAR_KEYS validation pattern is duplicated at every
#    source site in SKILL.md (no shared function crosses markdown fences). A silent
#    drift between copies would let one round validate differently than another. Assert
#    all copies are byte-identical and that there are the expected 5 (Rounds 7/8/10x2/11).
SKILL="$(dirname "$0")/../SKILL.md"
if [ -f "$SKILL" ]; then
  N_COPIES=$(grep -cE "^SIDECAR_KEYS='" "$SKILL")
  N_DISTINCT=$(grep -oE "SIDECAR_KEYS='[^']*'" "$SKILL" | sort -u | wc -l | tr -d ' ')
  check "16 sidecar-keys-copies-count" 5 "$N_COPIES"
  check "16 sidecar-keys-all-identical(distinct=1)" 1 "$N_DISTINCT"
else
  echo "  SKIP: 16 drift-guard (SKILL.md not found at $SKILL)"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$D"
[ "$FAIL" -eq 0 ]
