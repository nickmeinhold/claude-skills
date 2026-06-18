#!/usr/bin/env bash
# consolidate-health-check.sh — the /consolidate IMMUNE RESPONSE.
#
# WHY THIS EXISTS (2026-06-18 retro crux, Nick-gated "true"): the whole
# /consolidate maintenance system was REACTIVE. Every audit — the scorecard
# noise review, the permission-mode diagnosis, the eviction pass — was triggered
# by Nick *noticing* a problem and asking. The prediction scorecard ran ~68%
# unresolvable for 132 cycles before anyone looked; the directive layer sat over
# budget for an unknown number of sessions with no flag. The detectors existed
# (scorecard, reinforcement sidecar, eviction audit) but they were JANITORS —
# they only ran when invoked. An immune system instead responds to a threshold
# breach WITHOUT waiting for the organism to notice. This script is that immune
# response: a cheap, synchronous snapshot of system health that /consolidate runs
# in Phase 0 and that self-reports ONLY on a real breach.
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
#   1. scorecard-health — UNRESOLVABLE% (+ malformed-verdict%) over the last
#      --window readtime-score.json files. This is the exact signal that ran
#      invisible for 132 cycles. Breach: unresolvable% > --unresolvable-pct.
#   2. eviction-budget — directive-layer bytes vs --budget, using the SAME
#      formula the eviction audit uses (grep feedback_*/concept_* pointer lines
#      in CLAUDE.md, wc -c). Breach: layer bytes > budget.
#   3. wall-clock baseline — reports timing.jsonl accrual (the Step-1 prerequisite
#      for drift detection). Drift flag activates only once >=3 datapoints exist;
#      until then it is informational (shown with --verbose/--json, never a breach).
#
# CONFIG (flag overrides env overrides default):
#   --window N              HEALTH_WINDOW            (default 10)
#   --unresolvable-pct PCT  HEALTH_UNRESOLVABLE_PCT  (default 60)
#   --malformed-pct PCT     HEALTH_MALFORMED_PCT     (default 25)
#   --budget BYTES          HEALTH_BUDGET            (default 24576)
#   --claude-md PATH        HEALTH_CLAUDE_MD         (default ~/.claude/CLAUDE.md)
#   --corpus-glob GLOB      HEALTH_CORPUS_GLOB       (default ~/.claude/consolidation/*/readtime-score.json)
#   --timing PATH           HEALTH_TIMING            (default ~/.claude/consolidation/timing.jsonl)
#   --verbose               also print GREEN statuses (default: breach-only)
#   --json                  emit a machine-readable JSON object instead of markdown
#
# EXIT CODES (a reporter, not a gate — never break consolidation):
#   0  healthy (no breach)
#   10 at least one breach detected — informational, NOT an error
#   2  usage error
set -euo pipefail

WINDOW="${HEALTH_WINDOW:-10}"
UNRESOLVABLE_PCT="${HEALTH_UNRESOLVABLE_PCT:-60}"
MALFORMED_PCT="${HEALTH_MALFORMED_PCT:-25}"
BUDGET="${HEALTH_BUDGET:-24576}"
CLAUDE_MD="${HEALTH_CLAUDE_MD:-$HOME/.claude/CLAUDE.md}"
CORPUS_GLOB="${HEALTH_CORPUS_GLOB:-$HOME/.claude/consolidation/*/readtime-score.json}"
TIMING="${HEALTH_TIMING:-$HOME/.claude/consolidation/timing.jsonl}"
VERBOSE=0
JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --window)            WINDOW="$2"; shift 2 ;;
    --unresolvable-pct)  UNRESOLVABLE_PCT="$2"; shift 2 ;;
    --malformed-pct)     MALFORMED_PCT="$2"; shift 2 ;;
    --budget)            BUDGET="$2"; shift 2 ;;
    --claude-md)         CLAUDE_MD="$2"; shift 2 ;;
    --corpus-glob)       CORPUS_GLOB="$2"; shift 2 ;;
    --timing)            TIMING="$2"; shift 2 ;;
    --verbose)           VERBOSE=1; shift ;;
    --json)              JSON=1; shift ;;
    -h|--help)           sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "usage: consolidate-health-check.sh [--window N] [--unresolvable-pct P] [--malformed-pct P] [--budget B] [--claude-md PATH] [--corpus-glob G] [--timing PATH] [--verbose] [--json]" >&2; exit 2 ;;
  esac
done

WINDOW="$WINDOW" UNRESOLVABLE_PCT="$UNRESOLVABLE_PCT" MALFORMED_PCT="$MALFORMED_PCT" \
BUDGET="$BUDGET" CLAUDE_MD="$CLAUDE_MD" CORPUS_GLOB="$CORPUS_GLOB" TIMING="$TIMING" \
VERBOSE="$VERBOSE" JSON="$JSON" python3 <<'PY'
import os, re, glob, json, statistics

window          = int(os.environ["WINDOW"])
unresolvable_max= float(os.environ["UNRESOLVABLE_PCT"])
malformed_max   = float(os.environ["MALFORMED_PCT"])
budget          = int(os.environ["BUDGET"])
claude_md       = os.environ["CLAUDE_MD"]
corpus_glob     = os.environ["CORPUS_GLOB"]
timing_path     = os.environ["TIMING"]
verbose         = os.environ["VERBOSE"] == "1"
as_json         = os.environ["JSON"] == "1"

checks = []  # each: {name, status: GREEN|BREACH|SKIP|INFO, headline, detail}

def add(name, status, headline, detail=""):
    checks.append({"name": name, "status": status, "headline": headline, "detail": detail})

# --- Check 1: scorecard health -------------------------------------------------
files = sorted(glob.glob(os.path.expanduser(corpus_glob)))
recent = files[-window:] if window > 0 else files
t = f = u = malformed = 0
for p in recent:
    try:
        d = json.load(open(p, encoding="utf-8"))
    except Exception:
        continue
    prs = d.get("prediction_results") or d.get("predictions") or []
    for r in prs:
        if not isinstance(r, dict):
            malformed += 1; continue
        v = r.get("actually_true")
        if v is True:           t += 1
        elif v is False:        f += 1
        elif v == "unresolved": u += 1
        else:                   malformed += 1  # free-text verdicts rotted this once
total = t + f + u + malformed
if total == 0:
    add("scorecard-health", "SKIP",
        f"no graded predictions in the last {len(recent)} readtime files")
else:
    upct = 100.0 * u / total
    mpct = 100.0 * malformed / total
    breach = upct > unresolvable_max or mpct > malformed_max
    head = (f"{upct:.0f}% unresolvable, {mpct:.0f}% malformed "
            f"over last {len(recent)} consolidations ({total} predictions)")
    detail = (f"true={t} false={f} unresolved={u} malformed={malformed}. "
              f"Thresholds: unresolvable>{unresolvable_max:.0f}% or malformed>{malformed_max:.0f}%. "
              f"A high unresolvable% means predictions can't be graded at readtime — "
              f"the instrument is measuring the future instead of the session. "
              f"Action: audit scorecard prediction shape (narrow to same-session-verifiable).")
    add("scorecard-health", "BREACH" if breach else "GREEN", head, detail if breach else "")

# --- Check 2: eviction budget --------------------------------------------------
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

# --- Check 3: wall-clock baseline (Step-1 prerequisite for drift) --------------
times = []
if os.path.isfile(timing_path):
    for line in open(timing_path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
            w = o.get("wall_s")
            if isinstance(w, (int, float)):
                times.append(float(w))
        except Exception:
            continue
if len(times) < 3:
    add("wall-clock-baseline", "INFO",
        f"baseline accruing: {len(times)}/3 datapoints (drift detection inactive)")
else:
    prior, last = times[:-1], times[-1]
    mean = statistics.fmean(prior)
    sigma = statistics.pstdev(prior) if len(prior) > 1 else 0.0
    bound = mean + 2 * sigma
    breach = last > bound
    head = f"last agent-phase {last:.0f}s vs baseline mean {mean:.0f}s (+2σ bound {bound:.0f}s, n={len(prior)})"
    detail = ("The most recent consolidation ran beyond mean+2σ of the baseline — "
              "a possible perf regression in the agent phase. Compare DAG concurrency / model tiers.")
    add("wall-clock-baseline", "BREACH" if breach else "GREEN", head, detail if breach else "")

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
