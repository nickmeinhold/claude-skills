#!/usr/bin/env bash
# Lifecycle test for the Task #9 sidecar: Step-D write → fresh-shell source → label decision.
# Replicates the skill's exact logic (parse_verdict, sidecar write, ADVERSARIAL_APPROVE /
# ANY_REQUEST_CHANGES / label condition) and asserts outcomes across the state lifecycle.
set -u
D=$(mktemp -d); PASS=0; FAIL=0
parse_verdict() {
  local v
  v=$(grep -ioE "Verdict:\**[[:space:]]*(APPROVE|REQUEST_CHANGES|COMMENT)" "$1" 2>/dev/null \
      | grep -oiE "APPROVE|REQUEST_CHANGES|COMMENT" | head -1 | tr '[:lower:]' '[:upper:]')
  case "$v" in APPROVE|REQUEST_CHANGES|COMMENT) echo "$v";; *) echo "COMMENT";; esac
}

# --- Step D: write sidecar given availability + review-file contents ---
write_sidecar() { # args: kA cA tA wA  mVerdictText kText cJsonVerdict tText wText
  local kA=$1 cA=$2 tA=$3 wA=$4 mText=$5 kText=$6 cJson=$7 tText=$8 wText=$9
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
  cat > "$D/state.env.tmp" <<EOF
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
  mv "$D/state.env.tmp" "$D/state.env"
}

# --- Round 11: fresh shell sources sidecar + decides label. Echoes LABEL or NOLABEL ---
decide_label() ( # subshell = fresh shell
  if [ ! -f "$D/state.env" ]; then echo "NOLABEL"; exit 0; fi
  source "$D/state.env"
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

check() { # name expected  actual
  if [ "$2" = "$3" ]; then echo "  PASS: $1 → $3"; PASS=$((PASS+1)); else echo "  FAIL: $1 → got $3, expected $2"; FAIL=$((FAIL+1)); fi
}

# Scenario 1: Maxwell APPROVE + Kelvin APPROVE(avail), others unavailable → LABEL
write_sidecar 1 0 0 0  APPROVE APPROVE "" "" "";           check "1 all-happy one-adversary" LABEL "$(decide_label)"
# Scenario 2: RC anywhere blocks (Tesla REQUEST_CHANGES) → NOLABEL
write_sidecar 1 1 1 0  APPROVE APPROVE APPROVE REQUEST_CHANGES ""; check "2 any-RC-blocks" NOLABEL "$(decide_label)"
# Scenario 3: Maxwell APPROVE + all adversaries COMMENT → NOLABEL (no adversarial APPROVE)
write_sidecar 1 1 1 0  APPROVE COMMENT COMMENT COMMENT ""; check "3 no-adversarial-approve" NOLABEL "$(decide_label)"
# Scenario 4: Maxwell COMMENT → NOLABEL
write_sidecar 0 0 1 0  COMMENT "" "" APPROVE "";           check "4 maxwell-not-approve" NOLABEL "$(decide_label)"
# Scenario 5: only Wu available + APPROVE → LABEL (one adversary suffices)
write_sidecar 0 0 0 1  APPROVE "" "" "" APPROVE;           check "5 wu-only-approve" LABEL "$(decide_label)"
# Scenario 6: HALF-STATE — Kelvin UNAVAILABLE but its file holds a stale APPROVE.
#   Must NOT count (verdict not parsed when unavailable). Maxwell APPROVE, no other adversary approve → NOLABEL.
write_sidecar 0 1 0 0  APPROVE APPROVE COMMENT "" "";      check "6 unavailable-stale-approve-ignored" NOLABEL "$(decide_label)"
# Scenario 7: fail-closed — missing sidecar → NOLABEL
rm -f "$D/state.env";                                       check "7 missing-sidecar-fail-closed" NOLABEL "$(decide_label)"
# Scenario 8: full consensus, all five APPROVE → LABEL
write_sidecar 1 1 1 1  APPROVE APPROVE APPROVE APPROVE APPROVE; check "8 full-consensus" LABEL "$(decide_label)"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
rm -rf "$D"
[ "$FAIL" -eq 0 ]