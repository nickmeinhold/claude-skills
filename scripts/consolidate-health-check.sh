#!/usr/bin/env bash
# consolidate-health-check.sh — the /consolidate IMMUNE RESPONSE.
#
# WHY THIS EXISTS (2026-06-18 retro crux, Nick-gated "true"): the whole
# /consolidate maintenance system was REACTIVE. Every audit — the scorecard
# noise review, the permission-mode diagnosis, the eviction pass — was triggered
# by Nick *noticing* a problem and asking. The directive layer sat over budget
# for an unknown number of sessions with no flag. The detectors existed
# (reinforcement sidecar, eviction audit) but they were JANITORS — they only ran
# when invoked. An immune system instead responds to a threshold breach WITHOUT
# waiting for the organism to notice. This script is that immune response: a
# cheap, synchronous snapshot of system health that /consolidate runs in Phase 0
# and that self-reports ONLY on a real breach.
#
# 2026-07-05: the scorecard-health check (prediction unresolvable%) was removed
# when the `predictions` sub-experiment was retired — with no predictions to
# grade it could only ever SKIP. The two remaining checks are prediction-free.
#
# DESIGN (concept_system_reactive_no_immune_response.md):
#   1. Silent unless a real breach — the graduation/eviction model, never nagging.
#      Healthy => no output, exit 0.
#   2. Nick-gated action — the report surfaces the number; Nick decides to act.
#   3. In-consolidate, not cron — the checks are milliseconds of jq/wc over files
#      that already exist (NOT agents), so they add nothing to wall-clock; and the
#      mac-not-always-on constraint makes a standalone cron unreliable while a
#      Phase-0 check naturally runs when Nick (and the mac) are present.
#
# CHECKS:
#   1. eviction-budget — directive-layer bytes vs --budget, using the SAME
#      formula the eviction audit uses (grep feedback_*/concept_* pointer lines
#      in CLAUDE.md, wc -c). Breach: layer bytes > budget. The --budget default
#      is the SINGLE SOURCE for the cap; SKILL Trigger A references it.
#   2. wall-clock drift — robust + retry-aware. Baseline = prior NON-retried runs;
#      fence = median + K·MAD (immune to outliers). A retried LATEST run is annotated
#      (INFO), never a breach. Activates once >=5 clean datapoints exist; until then
#      informational. Breach: a retry-free run beyond the robust fence.
#
# CONFIG (flag overrides env overrides default):
#   --budget BYTES          HEALTH_BUDGET            (default 31744)
#   --claude-md PATH        HEALTH_CLAUDE_MD         (default ~/.claude/CLAUDE.md)
#   --timing PATH           HEALTH_TIMING            (default ~/.claude/consolidation/timing.jsonl)
#   --verbose               also print GREEN statuses (default: breach-only)
#   --json                  emit a machine-readable JSON object instead of markdown
#
# EXIT CODES (a reporter, not a gate — never break consolidation):
#   0  healthy (no breach)
#   10 at least one breach detected — informational, NOT an error
#   2  usage error
set -euo pipefail

# *** SINGLE SOURCE OF TRUTH for the directive-layer cap (task #5, dir-id 9b3d). ***
# 31744 = 31 KiB (31*1024). This ONE number is the directive-layer budget; the
# /consolidate SKILL.md eviction audit (Trigger A) references THIS default rather
# than restating a number — so the two cannot drift. Tune here, nowhere else.
# History: 20→24 KiB (2026-06-18), 24→28 KiB (2026-06-22, #87), 28→31 KiB
# (2026-06-26) — each raised when the layer's growth was load-bearing
# non-redundant directives (compress-not-evict found no fat to cut), not bloat.
# Cutting distinct nuance to satisfy the cap is the self-harm trap the audit
# warns against; the cap reflects the real set.
BUDGET="${HEALTH_BUDGET:-31744}"
CLAUDE_MD="${HEALTH_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
TIMING="${HEALTH_TIMING:-$HOME/.claude/consolidation/timing.jsonl}"
VERBOSE=0
JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --budget)            BUDGET="$2"; shift 2 ;;
    --claude-md)         CLAUDE_MD="$2"; shift 2 ;;
    --timing)            TIMING="$2"; shift 2 ;;
    --verbose)           VERBOSE=1; shift ;;
    --json)              JSON=1; shift ;;
    -h|--help)           sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "usage: consolidate-health-check.sh [--budget B] [--claude-md PATH] [--timing PATH] [--verbose] [--json]" >&2; exit 2 ;;
  esac
done

BUDGET="$BUDGET" CLAUDE_MD="$CLAUDE_MD" TIMING="$TIMING" \
VERBOSE="$VERBOSE" JSON="$JSON" python3 <<'PY'
import os, re, json, statistics

budget          = int(os.environ["BUDGET"])
claude_md       = os.environ["CLAUDE_MD"]
timing_path     = os.environ["TIMING"]
verbose         = os.environ["VERBOSE"] == "1"
as_json         = os.environ["JSON"] == "1"

checks = []  # each: {name, status: GREEN|BREACH|SKIP|INFO, headline, detail}

def add(name, status, headline, detail=""):
    checks.append({"name": name, "status": status, "headline": headline, "detail": detail})

# --- Check 1: eviction budget --------------------------------------------------
ptr = re.compile(r"feedback_[a-z_]+\.md|concept_[a-z_]+\.md")
if not os.path.isfile(claude_md):
    add("eviction-budget", "SKIP", f"CLAUDE.md not found at {claude_md}")
else:
    layer_bytes = 0
    for line in open(claude_md, "rb"):
        if ptr.search(line.decode("utf-8", "replace")):
            layer_bytes += len(line)  # bytes incl. newline — matches grep|wc -c
    breach = layer_bytes > budget
    head = f"directive layer {layer_bytes} / {budget} bytes ({100.0*layer_bytes/budget:.0f}% of budget)"
    detail = (f"The always-on CLAUDE.md directive layer is over budget. "
              f"Per feedback_compress_not_evict: COMPRESS hot directives to "
              f"trigger+pointer before evicting cold ones. Run the Wrap-up eviction audit.")
    add("eviction-budget", "BREACH" if breach else "GREEN", head, detail if breach else "")

# --- Check 2: wall-clock drift (robust + retry-aware) --------------------------
# The naive mean+2σ had two failure modes (task #6, the detector flagged its OWN
# run): (a) a retry-inflated run — an agent socket-death + full re-run balloons
# wall_s — false-positives as a "DAG perf regression" when the cause is a benign
# retry; (b) a tiny/noisy baseline (n=2) makes the bound meaningless. Fixes:
#   - read an optional per-datapoint "retried" flag; a retried LATEST run is
#     annotated (INFO), never a breach — the timer counted a retry, not the DAG.
#   - EXCLUDE retried runs from the baseline so they don't define "normal".
#   - robust fence = median + K·MAD (MAD scaled to σ via 1.4826), so an UNflagged
#     historical outlier (the old datapoints predate the flag) can't distort it;
#     relative ×1.5 fallback when MAD==0 (degenerate identical baseline).
#   - require >= MIN_BASELINE clean points before activating (was 3, too noisy).
MIN_BASELINE = 5      # clean (non-retried) prior runs before drift activates
DRIFT_K      = 3.0    # robust σ-equivalents above the median that counts as drift
points = []           # [(wall_s, retried_bool)] in file order
if os.path.isfile(timing_path):
    for line in open(timing_path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        w = o.get("wall_s")
        if isinstance(w, (int, float)):
            # STRICT boolean: only a real JSON `true` counts as retried. bool("false")
            # would be True (non-empty string), wrongly excluding a clean run — so a
            # string/garbage value fails SAFE to not-retried (Carnot PR #83 finding 3).
            points.append((float(w), o.get("retried") is True))

if not points:
    add("wall-clock-drift", "SKIP", "no timing datapoints yet")
else:
    last_w, last_retried = points[-1]
    baseline = [w for (w, r) in points[:-1] if not r]  # prior, non-retried runs only
    if last_retried:
        add("wall-clock-drift", "INFO",
            f"latest run {last_w:.0f}s was retry-inflated — drift check skipped",
            "wall_s includes a failed-agent retry/socket-death, not a DAG regression; excluded from the baseline too.")
    elif len(baseline) < MIN_BASELINE:
        add("wall-clock-drift", "INFO",
            f"baseline accruing: {len(baseline)}/{MIN_BASELINE} clean datapoints (drift inactive)")
    else:
        med = statistics.median(baseline)
        mad = statistics.median([abs(w - med) for w in baseline])
        if mad > 0:
            fence = med + DRIFT_K * 1.4826 * mad
            spread = f"robust σ≈{1.4826*mad:.0f}s"
        else:
            fence = med * 1.5  # identical baseline — flag only a >50% jump
            spread = "MAD=0, relative ×1.5"
        breach = last_w > fence
        head = (f"last agent-phase {last_w:.0f}s vs baseline median {med:.0f}s "
                f"({spread}, fence {fence:.0f}s, n={len(baseline)} clean)")
        detail = (f"The most recent (non-retried) consolidation ran beyond the robust drift fence "
                  f"({spread}, {fence:.0f}s). BEFORE concluding a DAG perf regression, confirm this run had NO agent "
                  f"retry / socket-death / API stall — those inflate the phase timer and are the common benign "
                  f"cause (mark such runs retried:true in timing.jsonl so they self-exclude). A real regression "
                  f"shows elevated wall-clock on a retry-free run; then compare DAG concurrency / model tiers.")
        add("wall-clock-drift", "BREACH" if breach else "GREEN", head, detail if breach else "")

# --- emit ----------------------------------------------------------------------
breaches = [c for c in checks if c["status"] == "BREACH"]

if as_json:
    print(json.dumps({"breach": bool(breaches), "checks": checks}, indent=2))
else:
    show = checks if verbose else breaches
    if breaches:
        print("## ⚠️ Immune Response — consolidation health breach\n")
        print("_The system self-flagged the following (silent unless a threshold breaches). "
              "Each is Nick-gated: this surfaces the number; you decide whether to act._\n")
        for c in show:
            mark = {"BREACH": "🔴", "GREEN": "🟢", "SKIP": "⚪", "INFO": "🔵"}.get(c["status"], "•")
            print(f"- {mark} **{c['name']}** — {c['headline']}")
            if c["detail"]:
                print(f"    - {c['detail']}")
    elif verbose:
        print("## 🟢 Immune Response — all checks green\n")
        for c in show:
            mark = {"GREEN": "🟢", "SKIP": "⚪", "INFO": "🔵"}.get(c["status"], "•")
            print(f"- {mark} **{c['name']}** — {c['headline']}")
    # healthy + non-verbose => print nothing (silent-unless-breach)

raise SystemExit(10 if breaches else 0)
PY
