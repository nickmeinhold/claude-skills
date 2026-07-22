#!/usr/bin/env bash
# Validation-contract test for the reviewer-state sidecar (Task #9), SCOPED to what the sidecar
# still does after Task #13. The sidecar NO LONGER decides the `cage-matched` label — Round 11
# reads authenticated GitHub verdict markers (see tests/test_label_consensus.sh). What survives
# is the sidecar's role as a same-session availability + verdict carrier that Rounds 7/8/10
# `source` behind an identical fail-closed validation gate (missing / malformed / incomplete /
# injected → refuse to source). This test owns THAT contract only — it deliberately does not
# assert any label outcome, so a green run here can't certify the deleted label path.
set -u
D=$(mktemp -d); PASS=0; FAIL=0
SIDECAR_KEYS='^(SIDECAR_PR_HEAD|KELVIN_AVAILABLE|CARNOT_AVAILABLE|TESLA_AVAILABLE|WU_AVAILABLE|MAXWELL_VERDICT|KELVIN_VERDICT|CARNOT_VERDICT|TESLA_VERDICT|WU_VERDICT)="[A-Za-z0-9_]*"$'

# parse_verdict — still used by Step D to record each reviewer's verdict (which Round 10 posts
# as a marker). Line-anchored, matching the skill: a bullet mention of "Verdict:" must NOT parse.
parse_verdict() {
  local v
  v=$(grep -ioE "^\*\*Verdict:\*\*[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" "$1" 2>/dev/null \
      | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
  case "$v" in APPROVE|REQUEST_CHANGES|COMMENT) echo "$v";; *) echo "COMMENT";; esac
}

# The Rounds-7/8/10 validation gate: SOURCE the sidecar iff it is present AND is exactly 10
# known KEY="alnum" lines (no missing/extra keys, no shell metachars). Echoes SOURCED / REJECT.
# This is the fail-closed gate the skill runs before every `source $SIDECAR`.
validate_gate() (
  local F=$1
  [ -f "$F" ] || { echo "REJECT"; exit 0; }
  { [ "$(grep -cE "$SIDECAR_KEYS" "$F")" -ne 10 ] || grep -qvE "$SIDECAR_KEYS" "$F"; } \
    && { echo "REJECT"; exit 0; }
  echo "SOURCED"
)

# Step-D writer (verdicts + availability + head stamp), matching the skill's atomic mktemp+mv.
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

check() { if [ "$2" = "$3" ]; then echo "  PASS: $1 → $3"; PASS=$((PASS+1)); else echo "  FAIL: $1 → got $3, expected $2"; FAIL=$((FAIL+1)); fi; }
H=abc123

# 1  well-formed sidecar → SOURCED
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE;  check "1 well-formed-sourced" SOURCED "$(validate_gate "$D/state.env")"
# 2  missing → REJECT (fail-closed)
rm -f "$D/state.env";                                              check "2 missing-reject" REJECT "$(validate_gate "$D/state.env")"
# 3  MALFORMED: an injected/hand-edited line → REJECT (never source an unvalidated /tmp file)
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE
printf 'rm -rf /tmp/evil="pwn"\n' >> "$D/state.env";              check "3 malformed-injection-reject" REJECT "$(validate_gate "$D/state.env")"
# 4  INCOMPLETE SCHEMA: a well-formed but PARTIAL key set → REJECT (shape≠schema)
write_sidecar $H 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE
grep -vE '^(TESLA_VERDICT|WU_VERDICT)=' "$D/state.env" > "$D/state.env.trim" && mv "$D/state.env.trim" "$D/state.env"
check "4 incomplete-schema-reject" REJECT "$(validate_gate "$D/state.env")"
# 5  ROUND-TRIP: a validated sidecar sources the availability + verdict values Step D wrote.
write_sidecar $H 1 0 1 0  APPROVE APPROVE COMMENT REQUEST_CHANGES ""
( source "$D/state.env"; echo "$KELVIN_AVAILABLE $CARNOT_AVAILABLE $TESLA_VERDICT" ) > "$D/rt.txt"
check "5 roundtrip-availability+verdict" "1 0 REQUEST_CHANGES" "$(cat "$D/rt.txt")"
# 6  ANCHOR REGRESSION: a "Verdict:" mention inside a findings bullet must NOT parse as APPROVE.
printf -- '- The **Verdict:** APPROVE claim in their review is wrong\n' > "$D/bullet.md"
check "6 anchor-regression-bullet-not-approve" COMMENT "$(parse_verdict "$D/bullet.md")"

# 7  DRIFT GUARD: the SIDECAR_KEYS validation pattern is duplicated at every source site in
#    SKILL.md (Rounds 7/8/10x2). Round 11 no longer sources the sidecar (Task #13), so the
#    expected copy count is 4, and all copies must be byte-identical.
SKILL="$(dirname "$0")/../SKILL.md"
if [ -f "$SKILL" ]; then
  N_COPIES=$(grep -cE "^SIDECAR_KEYS='" "$SKILL")
  N_DISTINCT=$(grep -oE "SIDECAR_KEYS='[^']*'" "$SKILL" | sort -u | wc -l | tr -d ' ')
  check "7 sidecar-keys-copies-count(=4)" 4 "$N_COPIES"
  check "7 sidecar-keys-all-identical(distinct=1)" 1 "$N_DISTINCT"
else
  echo "  SKIP: 7 drift-guard (SKILL.md not found at $SKILL)"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$D"
[ "$FAIL" -eq 0 ]
