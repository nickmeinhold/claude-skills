---
description: Prime me with the memory-graph re-engagement packet from the 2026-05-01 sessions so we can pick up exactly where we left off
---

# Memory Graph Re-engagement

I'm coming back to the memory-graph work. Below is the full packet. After reading it, do these things in order:

1. Run `/graph` to see current state (orphan delta from launchd snapshots, edge counts, drift signal).
2. Re-read "THE TEST PLAN" section below carefully.
3. Help me decide one of three things:
   - **A/B-test the hook** (run the test plan now)
   - **Kill the hook** (if I'm convinced the value isn't there)
   - **Defer** another week (move the next reminder forward)

═══════════════════════════════════════════════════════════════════

## Where we left off (sessions of 2026-04-29 → 2026-05-01)

Built typed-edge schema (`←/⊕/~/↔/⊗`) in `MEMORY.md` at `~/.claude/projects/-Users-nick-git/memory/`. Live infrastructure:

- **PreToolUse hook** at `~/.claude/scripts/memory_neighborhood.py` printing 2-hop neighborhood on memory-file Reads
- **Edge-FSRS traversal log** at `~/.claude/scripts/output/edge-traversals.jsonl`
- **Weekly launchd audit** (`com.nickmeinhold.memory-graph-audit`, Monday 09:00 local) producing `audit-weekly-YYYY-WXX.txt` with delta-vs-last-week
- **/graph slash command** (claude-skills repo, PR #6 merged) for on-demand audit + viz
- **Yoneda reconstruction tests** on 2 hubs: ~45-50% saturation. Hubs under-represent themselves; gap concentrated in concrete artifacts (URLs, paths, dates).
- **Dream-cycle hand experiment**: 1 real edge / 5 candidates = 20% hit rate, 3 specific tuning fixes captured as task T25.

## THE CRUX (open, uninvestigated)

We built it but never tested whether the hook earns its tokens. Honest question: **"On real cross-project tasks, does Claude-with-graph produce measurably better output than Claude-without?"** Until tested, value is plausibly-positive at best.

## THE TEST PLAN (~1-2 hours of focused work)

1. Pick 3-5 cross-project recall scenarios that require connecting memories across projects (e.g., "summarize epistemic discipline across all our work" — needs threads across `feedback_*`, SNES debug methodology, audit findings).
2. Run each with hook ENABLED, capture outputs.
3. Disable hook (1-line `settings.json` toggle: remove the `{matcher: Read, ...}` entry under `PreToolUse`), re-run in fresh session, capture outputs.
4. LLM-as-judge or Nick-as-judge: better, worse, indistinguishable?

## Decision tree

- **Indistinguishable** → kill hook (saves ~500-1500 tokens per memory Read), keep schema + viz (passive, near-zero cost)
- **Clearly better** → investment validated, continue building (Flux integration design at `project_graph_flux_integration_design.md`, dream cycle implementation, etc.)
- **Unclear** → sharpen eval methodology before more infrastructure

## Data available by now

- Weekly audit snapshot(s) from launchd in `~/.claude/scripts/output/audit-weekly-*.txt`
- Edge-FSRS log accumulating in `~/.claude/scripts/output/edge-traversals.jsonl`
- `/graph` reflects current state on demand

## Related open tasks (TaskList shows them)

- **T24**: Resolve divergence between synced /graph skill and local audit/render scripts
- **T25**: Tune Flux dream-cycle algorithm (3 specific fixes — hub-trap mitigation, sibling-redundancy filter, length-N oscillation suppression)

═══════════════════════════════════════════════════════════════════

Ready. Run `/graph` first, then orient me.

---

**Open tasks (T24/T25/T26) full descriptions:** `~/.claude/consolidation/2026-05-01T19-31/open-tasks.md`
