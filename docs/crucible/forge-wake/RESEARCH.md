# RESEARCH — The Forge Wake (Heat movement)

*Internal-substrate research (no web needed — this is a wiring design over existing skills). Scope: how the wake-up + consolidate machinery works today, and whether the falsifier holds.*

## Ground truth of the existing machinery

1. **The Wake-Up Protocol** (in `~/.claude/CLAUDE.md`) is dual-driven: SessionStart hooks (`~/.claude/settings.json`) + in-context steps. Step 2 resolves the newest consolidation **for the current project** by mtime, filtered via each dir's `memory-path.txt`. Step 3 restores open tasks from GitHub issues (`nickmeinhold/claude-tasks`, label `project:<slug>`) — **as a flat, unranked list**. That flat list is the pain the Forge Wake targets.

2. **`/consolidate` already produces the continuity signal.** Its agents write, per-project, into a session-namespaced consolidation dir:
   - `affective-highlights.md` — *what was exciting / surprising / frustrating* (Phase 0a). **This is the continuity-weighting input the Forge Wake needs — it already exists.**
   - `next-session-prompt.md` — the cold-reader onboarding prompt, written by the **`next-session-prompter` (Opus)** agent (Burst 2), which *already reads* `consolidation.md` (crux + forward plan) + `open-tasks.md` + the affective highlights.
   - `open-tasks.md` + `<MEMORY_DIR>/pending-tasks.json` — the task snapshot the wake-up restore consumes.

3. **The wake-up reads `next-session-prompt.md`** (`ls -t .../next-session-prompt.md | head -1`). So whatever the `next-session-prompter` writes is what greets the next session.

## The architecture this unlocks (the key Heat finding)

There are two places the scout could run:

- **Wake-time** (SessionStart hook / wake-up step runs `/crucible --scout` fresh): current repo state, but adds LLM-cost + latency to *every* session start, and duplicates infra.
- **Consolidate-time** (the `next-session-prompter` runs the scout as its final step and embeds ranked ore into `next-session-prompt.md`): **piggybacks on an agent that already runs, already holds `affective-highlights.md` in context (continuity), and already writes the file the wake-up reads.** Zero added wake-time cost. This is an *exaptation* — co-opt an existing organ, don't grow a new one.

**Consolidate-time wins.** The only cost is ranking staleness (ore ranked as-of-last-consolidation, not as-of-wake) — minor, because a repo rarely changes between a consolidation and the next session, and the wake-up can label it "as of last consolidation" + offer a `/crucible --scout` refresh on demand.

## Falsifier probe: is `--scout` ranking trustworthy enough?

The falsifier ("noisy ranking → briefing becomes ignorable noise") is the real risk. Findings:
- `--scout` ranking is an **LLM judgement over aliveness × impact with an evidence bullet per score** (the rubric shipped in `/crucible` today). Evidence-anchored scoring is more stable than free-vibe ranking, but it is **not yet empirically validated across repeated runs** — we have exactly one `--scout` run (this session) as prior.
- **Mitigation, not assumption:** the build must gate step 1 (wake-time surfacing) on a cheap stability check — run `--scout` 2-3× on the same repo state and assert the top-2 ore are stable before trusting it at every wake. If unstable, the briefing degrades to "here are the restored tasks (unranked) + a note that ranking was low-confidence" — still no worse than today.

## Prior art / adjacent patterns

- `/reconcile` already scans repo substrates for drift (its inward findings overlap the scout's inward scan) — a future fold, not this build.
- The `--scout` Cadence section in `/crucible` already anticipated a scheduled scout; the Forge Wake is that idea wired to the *right* trigger (session-start / consolidation) instead of an arbitrary cron.
