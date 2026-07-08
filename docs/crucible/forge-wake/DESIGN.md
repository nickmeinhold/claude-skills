# DESIGN — The Forge Wake

*Cast movement. The mold the Temper (cage-match) will strike.*

## Problem

Every session opens cold. The Wake-Up Protocol restores open tasks as a **flat, unranked list** (GitHub issues under `project:<slug>`) and surfaces the last consolidation's prose. Nick then decides, by hand, what's worth doing today. Two costs: (a) the daily *"what should I work on?"* decision, and (b) a flat backlog where a stale duplicate and the highest-leverage refactor look identical. Observed live this session: 8 restored `claude-skills` tasks, unranked, including two known duplicates.

## Proposed shape

Co-opt the agent that already runs at end-of-session and already writes the file the next session reads. **No new wake-time scout, no new trigger.**

**Core mechanism:** extend `/consolidate`'s `next-session-prompter` (Opus, Burst 2) with a final **ore-scan** step. It already reads `affective-highlights.md` (what excited Nick) + `open-tasks.md` (the backlog) + `consolidation.md` (the crux). It additionally runs a `/crucible --scout`-style pass over the repo + the restored backlog, and **embeds a ranked ore briefing into `next-session-prompt.md`**:

```
## 🜂 Forge Wake — ore glowing in this repo (as of last consolidation)
1. <ore> — A×I=<n> · continuity:<high|med|low> · <one-line why> · [issue #/path]
2. ...
3. ...
(ranking = aliveness × impact, then nudged by continuity with your last thread)
```

The wake-up protocol already reads `next-session-prompt.md`, so the briefing appears with zero new wake-time work.

**Ranking function:** `score = aliveness × impact`, then a **continuity nudge** — ore adjacent to the last session's `affective-highlights` themes rises within a tied band (NOT a multiplier that dominates; continuity breaks ties, it doesn't override impact — same discipline as `/crucible`'s protected-newborn rule so continuity can't argmax away a high-impact stranger).

## Build order (conventional core first, each step independently useful)

1. **Core — embed a ranked ore briefing in `next-session-prompt.md`.** Add the ore-scan step to the `next-session-prompter` brief in `skills/consolidate/SKILL.md`. Ship without continuity weighting first (pure A×I over repo + backlog). Independently useful day one: the next session opens with ranked ore instead of a flat list. **Gate:** before this is trusted, run the stability check (below).
2. **+ Continuity weighting.** Feed `affective-highlights.md` themes into the ranking as a tie-band nudge. The atypical tail — the repo ranks by "what would pull *you* right now," not just objective impact.
3. **+ On-demand refresh.** Wake-up offers "ranking is as-of-last-consolidation; run `/crucible --scout` to refresh against current repo state." Closes the staleness gap without paying wake-time cost by default.

## Blast-radius + consent spine

- **Read-only.** The ore-scan forges nothing (it's `--scout` semantics inside the prompter). It writes only to `next-session-prompt.md`, a file the prompter already owns exclusively. No new mutation surface.
- **Cost:** one extra scan step inside an agent that already runs at consolidation. No added wake-time latency. No new agent, no new hook.
- **Failure mode is graceful:** if the scan errors or the repo is unreadable, the briefing section is omitted and the prompt degrades to today's behaviour (flat restored tasks). Existence-is-the-contract, like `open-tasks.md`.

## Claims to falsify (for the adversary)

1. **"Consolidate-time beats wake-time."** Load-bearing assumption: repo state rarely changes between a consolidation and the next session, so ranking staleness is minor. FALSIFIABLE: if sessions frequently start after significant external changes (peer commits, other tabs), the briefing is stale and misleads. → mitigated by step 3 (on-demand refresh) + the "as of last consolidation" label.
2. **"The ranking is stable enough to trust."** FALSIFIABLE: if `--scout` produces different top-2 ore on repeated runs over identical state, the briefing is noise. → **hard gate:** step 1 ships only after a stability check (run the scan 2-3× on fixed state, assert top-2 stable). If unstable, degrade to unranked + low-confidence note.
3. **"Continuity should nudge, not dominate."** FALSIFIABLE: if continuity weighting makes the Wake always propose more-of-the-same and never surfaces the high-impact stranger, it's an echo chamber. → tie-band nudge only, capped like the protected-newborn rule.
4. **"This isn't just `/crucible --scout` at wake-up with extra steps."** FALSIFIABLE: if the continuity weighting adds nothing measurable, the honest design is just "run `--scout` at wake" and the consolidate-fusion is decoration. → the continuity nudge (step 2) is the load-bearing novelty; if it proves worthless, ship only step 1 and rename accordingly.

## Rejected alternatives

- **Wake-time SessionStart hook running `/crucible --scout`.** Rejected: adds LLM cost + latency to every session start, duplicates infra, and lacks the continuity signal (the hook has no `affective-highlights` in context). The whole win is the piggyback.
- **A new standalone `/forge-wake` skill.** Rejected: it's not a new capability, it's a wiring of two existing ones — a new skill would duplicate `--scout` and drift from it (same anti-pattern that made us fold the janitor into `/crucible` rather than spin a sibling).
- **Rank inside the wake-up bash step (no LLM).** Rejected: aliveness × impact is an LLM taste judgement; a bash heuristic (issue age, label counts) can't score aliveness and would produce exactly the untrustworthy ranking the falsifier warns about.

## Open variables (enumerated, not rounded to "ready")

- `[OPEN]` How many ore in the briefing? (proposed: top 3 — enough to choose, few enough to read.)
- `[OPEN]` Does the scan include the *inward* scan (refactor/rot) or forward-only at wake? (proposed: both, but cap inward at 1 slot so the Wake isn't all-janitorial.)
- `[OPEN]` The stability-check threshold: how many runs, what "stable" means (proposed: 2 of 3 runs agree on top-2). To be pinned in the build, not now.

---

## v2 — re-Cast from Temper (Carnot + Kelvin CONVERGENT findings)

The cage-match (2026-07-08) returned REQUEST_CHANGES from both cross-family adversaries, converging on three real flaws. The **core survives** (both called the consolidate-time injection point "thermodynamic elegance"); the **naive novelty was dissolved** and re-instrumented. Changes:

1. **Continuity must be a STRUCTURAL signal, not an emotional one (the crux).** Both adversaries independently flagged the `affective-highlights`-keyword nudge as "confirmation bias, implemented" — emotional salience ≠ strategic value, and keyword overlap overfits on past excitement, walling out high-impact strangers. **Fix:** continuity = **structural adjacency** — memory-graph distance / file-dependency proximity to the nodes+files the last session actually touched — NOT emotional-theme overlap. This preserves the third-thing (ore ranked by relevance-to-your-thread) while killing the echo chamber. If a rigorous structural signal can't be defined, the honest fallback is to CUT continuity and ship the core as "`/crucible --scout` wired to consolidation" — still useful, no longer a novel recombination. The continuity instrument is the single load-bearing open decision.

2. **Freshness: a cheap non-LLM invalidation check, not an "as of" label.** GH issues restore at wake and change independently of the repo; a ranking embedded at consolidation can contradict today's restored tasks. **Fix:** stamp the briefing with `{repo HEAD, issue-snapshot time, pending-tasks hash}` at generation; at wake, a cheap check (HEAD changed? issue-set changed?) marks the briefing STALE and *forces* a `--scout` refresh rather than presenting a history lesson. The system must not start by lying.

3. **Validation is continuous + empirical, not a one-time variance gate.** "A stable hallucinated ranking is still stable." **Fix:** (a) a canonical fixed ore-set ranked on every build with a distribution-in-tolerance assertion (catches model/rubric drift), and (b) an empirical loop — track whether Nick actually picks a top-ranked ore over real sessions; if the hit-rate is low, the briefing suppresses itself.

4. **Shared scout interface, not copied prose (kills rubric drift).** Do NOT embed `--scout`-style taste logic into `skills/consolidate/SKILL.md` — that recreates the standalone-drift anti-pattern we rejected, inside another skill. **Fix:** `/crucible --scout --output=json` emits a structured ore artifact with metadata; the `next-session-prompter` *calls* it and renders it. One rubric, one owner.

5. **Defined candidate pool + evidence contract.** Ore comes from an explicit set: open GH issues (`project:<slug>`), `pending-tasks.json`, and the `--scout` forward+inward repo scan — deduped. Each ranked item carries source link + why-now evidence + impact evidence; thin-evidence items are not ranked. "Ranking stability" is meaningless without a fixed candidate boundary.

6. **Control-plane blast-radius acknowledged + configurable.** `next-session-prompt.md` is the first context injected every session — a stable-but-wrong ranking biases all planning. Add a per-project config (`.claude/forge-wake`: `off | summary-only | top-3-cached | require-refresh`) and a confidence floor below which the briefing degrades to the plain restored-task list.

**Status after v2 re-Cast:** core hardened; the continuity-instrument (structural vs cut) is the one decision that gates whether this stays a recombination. Would benefit from a round-2 strike on the re-Cast before build — marked accordingly (this is a design+plan deliverable, not tonight's ship).
