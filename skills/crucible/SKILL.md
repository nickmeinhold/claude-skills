---
argument-hint: [optional seed — a domain/theme nudge, or "inward only"; add --scout to rank candidates and stop (for scheduled sweeps); omit for a full autonomous forge]
description: Forge raw enthusiasm into a battle-tested, ready-to-build plan. /crucible SCOUTS the codebase + open task list ITSELF, pounces on the most alive candidate, gets genuinely pumped about it, then runs it through five metallurgical movements — Ore (scout + select), Heat (deep research), Cast (design doc), Temper (adversarial cage-match on the design), Blade (plan mode). Where /ascend is pure heat with no critic and /spiral-review cools a finding to a contract, /crucible melts excitement into form and tempers the brittleness out — ending not in a prototype but in a plan you're excited about that already survived the fire. Use to turn "ooh, that'd be fun" into something you can actually start.
---

# /crucible — melt an idea from ore to a tempered blade

You are about to forge something. A crucible is a vessel that survives extreme heat so the metal inside can melt, separate from its slag, take a mold, and come out hard. This skill is that vessel for an *idea*: it starts with raw enthusiasm (heat) and ends with a plan you can start on Monday (a blade). Unlike its sibling engines, **you do not wait for the topic** — `/crucible` roams the codebase and the open task list, develops taste, and *chooses the most alive candidate itself*, then drives it all the way to a vetted plan.

## The law (everything below serves it)

**Heat without a mold is a puddle; a mold without heat is empty.** Enthusiasm is the *fuel*, never the product. `/crucible` earns the right to get genuinely, unironically pumped about an idea only because a **mold** (the design doc) and a **hammer** (the cage-match) are waiting downstream to give the heat form and beat the brittleness out. The joy is real and load-bearing — it's what makes the scout pick something worth building instead of something safe — but it is disposed of by the temper, in the same pass, before any plan is trusted.

This is the family's third thermodynamic position:

> **/ascend** heats with NO critic and defers the cold pole to an overnight build (hot → matter). **/spiral-review** cools a live finding down to a function-on-data (hot → contract). **/crucible** heats to *select*, pours into a mold, and tempers in the SAME pass — ending in a **plan**, before a line of code (hot → blueprint).

`/ascend`'s honesty-restorer is a compiler tomorrow. `/crucible`'s is the cage-match at movement 4 — the adversary is built into the middle, not deferred. That is the whole reason this is a distinct engine and not "`/ascend` with extra steps."

## The five movements (metallurgy, in order)

1. **Ore** — *scout two ways, then select on aliveness × impact.* Roam the real substrate: `grep`/read the codebase, and read the **open task list** (`gh issue list -R nickmeinhold/claude-tasks --label "project:<slug>" --state open`, plus the in-session TaskList) and carried-forward `project_*_forward_plan.md` "crazy-ideas" threads. The scout runs **two scan passes and picks the single winner across both** — a candidate is not only a new capability:
   - **Forward scan** — *what could we build?* New features, capabilities, ideas the substrate is reaching for.
   - **Inward scan** — *what should we rework?* Opportunities to **extract** (duplication → a shared module), **combine** (two things that should be one — dispatch to `/recombine`), **simplify** (a tangle that should collapse — dispatch to `/simplify`), or **redesign** (a subsystem that's rotting and wants a new shape). Smell-detect: duplication clusters, tight coupling, complexity hotspots, drift, N-similar-artifacts, dead code.

   Crucible does not *replace* `/simplify` or `/recombine` — its scout autonomously *finds* the opportunity none of them scout for, and Cast/Heat may **call them as operators** (as it composes `/deep-research` and `/cage-match`). Sometimes the highest-impact ore in a codebase is a redesign, not a new feature — a scout blind to that would lie about optimizing for impact. Surface a handful of candidates across BOTH scans, then **reject the slag** — the dull, the already-done, and the thrilling-but-trivial — and keep the ONE that **glows AND matters most**. Selection is the *meet of two axes, not one*: **aliveness** (does it hit *oh, of course* — the thing you'd want to build) × **impact** (does it remove a real human task, unblock something stuck, matter to a user or to Nick). Highest impact alone is the wrong knob — it's a pure argmax that sands off the atypical tail (a genuinely novel idea scores low on impact *at first*, precisely because it's new); highest glow alone picks a shiny toy that fixes nothing. Take the candidate at the **peak of the product**, and when two are close, break the tie toward **impact** (the whole point is to forge something that changes the world a little, not just something fun). Then **get pumped**: state plainly and with real heat *why this one* — what makes it thrilling AND what it would actually change (the human task it removes, the thing it unblocks) — and the one-line spark that, if true, makes you want to drop everything. This is the joy beat; do not flatten it into a neutral status report. **Verify the ore is real** — the candidate must point at an artifact that exists (a file, an issue, a live thread), not an invention (verify-before-asserting; the scout selects from what IS, never from what would be cool if it existed).

2. **Heat** — *melt it down.* Run a deep research pass on the chosen candidate to separate metal from slag: prior art, existing implementations in this repo and the wider world, the real constraints, the failure modes others already hit, the libraries/APIs/patterns that apply. Compose with **`/deep-research`** (or a background `general-purpose` researcher) — fan out, fetch sources, verify claims, and write findings to `RESEARCH.md` in the target's dir. Heat is where "wouldn't it be cool" meets the ground truth of what's actually known.

3. **Cast** — *give it shape.* Pour the melt into a mold: write a **design doc** (`DESIGN.md` in the target's dir). It states the problem, the proposed shape (architecture, interfaces, data shapes, the one atypical element), the **build order** (conventional core first, each step independently useful, no big-bang), the tradeoffs taken, and — because this is a Nick-shaped forge — the **blast-radius and consent spine up front** (cage before monster: name the owner, the injection surface, the throttle *in the design*, not as a follow-up). A design with `[TODO]`/`[CONFIRM]` gaps self-reports as unfinished — enumerate the open variables explicitly rather than rounding to "ready."

4. **Temper** — *harden it under fire.* Tempering removes brittleness by cycling heat and stress; the design cage-match does the same. Run **`/cage-match` on the design doc** (not code) with the cross-family cast (Maxwell/Kelvin/Carnot/Tesla) set to *hunt fatal design flaws*: unstated assumptions, missing failure modes, a simpler alternative that dissolves the problem, a wrong option-frame, the blast-radius the Cast under-counted, the coupling that should be removed rather than guarded. **Strict gate:** every finding is either folded back into the design (return to Cast, re-temper) or explicitly recorded as a named tradeoff. The plan is not trusted until the design survives the strike. This is the cold pole; it is what earns the heat back in movement 1.

5. **Blade** — *the finished tool.* Hand the tempered design to **plan mode** (`EnterPlanMode`): translate the surviving design + build order into a concrete, ordered implementation plan the user can approve and start. Blade **hones, it does not re-forge** — it sharpens the already-tempered design into ordered steps; it does NOT run a second cage-match. The brittleness was beaten out at movement 4, when the metal was still malleable; you temper a blade once, not twice, and a second full strike here can only surface flaws the tempered design already didn't contain (a light self-review that Blade dropped or distorted nothing from the tempered design is the right check — the "verify each step" discipline, not another four-family burn). The output of `/crucible` is not a prototype and not code — it is a **plan you are excited about that already survived the fire**. Present it, then let Nick's taste own the go/no-go.

## The cast (for Temper)

The `/cage-match` cast, cross-family for genuine adversarial independence: **Maxwell** (Claude), **Kelvin** (Gemini), **Carnot** (Codex/GPT), **Tesla** (Grok). Cross-family is the point — a design lit from four inductive biases finds fatal flaws one model, reviewing its own enthusiasm, will launder past. If real cross-family agents are unavailable you MAY run them in-context as personae to validate the *mechanic*, but say so and treat the verdict as provisional (persona modulates noise, not capability). **Note the temperature flip:** Ore/Heat/Cast run hot (the author, excited); Temper runs cold and adversarial. Do not let the author-instance grade its own homework — the whole value of Temper is that a different bias strikes the casting the excited scout poured.

## The one discipline: the scout must not grade its own homework

Movement 1 is a *taste* call, and taste at the front is fine and necessary — that's where the joy lives. The danger is letting that same excited voice carry all the way to the plan unchallenged (the ecstasy-spiral echo chamber `/ascend` names — it will forge slag as eagerly as gold). You do **not** fix this by adding a critic to the Ore movement — that kills the heat that makes the scout brave. You fix it at **Temper**: a cold, cross-family adversary strikes the *casting*, not the scout's enthusiasm. Heat proposes; temper disposes; the plan is what's left standing.

## Procedure

1. **Ore.** Scout the codebase + open task list + forward-plan "crazy-ideas" **two ways** — a *forward* scan (what to build) and an *inward* scan (what to extract/combine/simplify/redesign). Reject the slag. Select the one at the peak of **aliveness × impact** across both scans (glows AND matters; tie-break toward impact) and verify it points at a real artifact. Write the pick + the genuine why-this-thrills-me-AND-what-it-changes case (with heat) to `CRUCIBLE.md` in the target's dir. If an `$ARGUMENTS` seed was given, let it *bias* the scout (e.g. "inward only", or a domain), not replace the selection. **If `--scout` was passed, STOP HERE** — output the ranked candidate list and forge nothing (see Cadence).
2. **Heat.** Deep-research the pick (compose `/deep-research` or a background researcher) → `RESEARCH.md`.
3. **Cast.** Write `DESIGN.md`: problem, shape, build order (core-first), tradeoffs, blast-radius + consent spine, open variables enumerated (no silent `[TODO]`s).
4. **Temper.** Run `/cage-match` on `DESIGN.md`, cross-family, hunting fatal *design* flaws. Fold every finding back (re-Cast) or record it as a named tradeoff. Loop until the design survives a clean strike or remaining findings are explicit tradeoffs.
5. **Blade.** `EnterPlanMode` with the tempered design translated into an ordered, approvable implementation plan. Present; hand the go/no-go to Nick.

## When the ore is cold (an honest negative result)

If the scout genuinely can't find a candidate that glows — everything is dull, done, or not-yet-ripe — **say so and stop.** A cold crucible is a real, useful result: it means the exciting work isn't in the visible substrate right now, and forging slag into a polished plan just to have shipped something is exactly the failure `/crucible` exists to avoid. Do not manufacture enthusiasm; report the empty melt.

## Cadence — the janitor is crucible on a timer, not a second skill

A recurring "what's rotting?" sweep is **not** a separate skill and its schedule does **not** live inside the scout — a scout that knows what day it is is a capability that grew a trigger (*remove the coupling, don't add a layer*). The janitor is simply **`/crucible --scout` fired by a `/schedule` routine or cron**. Two orthogonal axes, kept apart:

- **Eyes** (what it scans for — rot, duplication, coupling, drift): the Ore movement's *inward scan*. Already in the scout.
- **Clock** (when it runs): a cron/routine that invokes the skill. Lives in the scheduler, never in the movement.

**`--scout` (shallow mode):** run **Ore only** — the two scans + the ranked aliveness × impact candidate list — then **STOP**. Forge nothing. This is what the scheduled sweep uses, and why: an unattended weekly run must **not** burn a full deep-research pass + a four-family cage-match and end in a plan nobody asked for (bounded blast-radius / cost). The cron posts the ranked list; Nick reads it, picks the one that glows, and *then* runs full `/crucible <pick>` on-demand to carry it through Heat → Temper → Blade. Cheap eyes on a clock; expensive forge on a human trigger.

## Composition

- **With /ascend**: `/ascend` is pure heat (no critic, deferred build). Run `/ascend` when you want to know if a *single named ember* is alive; run `/crucible` when you want the engine to *find* the ember itself and carry it all the way to a vetted plan. `/crucible`'s Ore movement is a `/ascend`-flavored heating of the chosen candidate; its Temper is a `/cage-match`. It recombines both on the anchor *"forge excitement into a plan without letting the excitement lie."*
- **With /cage-match**: `/crucible` *is* a caller of `/cage-match` — pointed at a design doc rather than a PR diff. The adversaries hunt design flaws (missing failure modes, simpler alternatives, uncounted blast-radius), not code bugs.
- **With /deep-research**: the Heat movement is a `/deep-research` run scoped to the chosen candidate.
- **With plan mode**: `/crucible` terminates *into* plan mode — it is the pre-flight that makes the plan worth approving. What plan mode receives has already been researched and tempered.
- **With /spiral-review**: the inverse arc's far end. Once the plan is built, `/spiral-review` cools the shipped thing's review findings into contracts. `/crucible` forges the plan; `/spiral-review` files the fixes.

## Reference

Third temperature in the forge family beside `/ascend` (heat) and `/spiral-review` (cool). Named and designed with Nick 2026-07-08 — he chose the metallurgical frame (ore → heat → cast → temper → blade) and the autonomous-scout constraint (the engine picks the topic, not the human). The distinctive move: the adversary lives in movement 4, in-pass, so the output is a **plan that already survived the fire** rather than a hopeful blueprint.

🜂 melt the ore, temper the blade — enthusiasm forged into a plan that survived the strike
