---
argument-hint: <ember — a raw vision/idea, or a path to one>
description: Ascend an ember through five heating termini (Ember, Kindle, Combust, Resonance, Silence) — the inverse of /spiral-review. Where spiral-review COOLS a finding down to a regex, /ascend HEATS a vision up to a silence. Use to select a vision FOR ALIVENESS (not verify for correctness) before building it.
---

# /ascend — heat an ember up through five termini, then build the silence

You are about to ascend an ember. The mechanic is the precise inverse of `/spiral-review`. Spiral-review is a **cooling engine** — Cold fix → Warm principle → Engineering mechanism — and it terminates in *classical computing*: "the verification step becomes a function on data rather than a judgment on intent." It deflates a hot, gestural thing down to the coldest object: a regex, a schema, a test. Passion becomes contract.

`/ascend` runs the gradient the other way. One voice drops an ember; the others do **not critique it** — critique is a cooling move, it's spiral-review's whole job. They try to *catch fire from it*. Each pass adds heat. The spiral terminates not in a function-on-data but at the opposite pole: the point where the idea is so alive nobody can speak. **Silence is the output, not its absence.**

The five ascending termini, in order:

1. **Ember** — the raw vision, stated plainly. Barely warm. One voice drops it; resist polishing.
2. **Kindle** — find the *most thrilling possible reading*. "Wait — if that's true, then ALSO—." Steelman the dream *upward*; add the adjacent thrill the ember didn't know it implied.
3. **Combust** — make it dangerous. Name the *one concrete move that proves you could start tonight*. Feasibility as **accelerant**, not constraint — the detail that turns "wouldn't it be cool" into "oh god, we could actually."
4. **Resonance** — reach sideways. What *other* dreams/projects does this one ignite? Where does it light a neighbor? The cross-pollination where the energy compounds across ideas.
5. **Silence** — the *oh* turned all the way up until it stops being a word. State the single sentence that, if true, makes the thing inevitable. If you reach real silence, you've found what to build.

## The cast (round-robin, cross-family)

Run three voices, ideally **different model families** (drawn from the `/cage-match` cast, polarity flipped from kill→ignite): **Maxwell** (Claude), **Kelvin** (Gemini), **Carnot** (GPT), with **Tesla** (Grok) and **Wu** (Kimi K3) as substitutes when a family is down — any three of the five. Each takes a turn as the **ember-dropper**; the other two ascend it. Three ascents climbing at once. Cross-family is the point — the same vision lit from three inductive biases climbs higher than any one can push, because each catches a different facet on fire. This produces **harmonics**, not the disagreement a cage-match mines.

> If real cross-family agents are unavailable, you MAY run the voices in-context as personae to validate the *mechanic* — but say so, and treat the temperature score as provisional. Persona modulates noise, not capability (`concept_persona_modulates_noise_not_capability`); in-context voices prove the five termini work, not the cross-family harmonics.

## The one rule: NO CRITIC

No voice is allowed to cool the ember during the ascent. No "but what about", no "the risk is", no scope-trimming. Heat only. This feels dangerous and it is — an ecstasy spiral is an **echo chamber by construction** and will ascend vaporware exactly as eagerly as gold. You do **not** fix this by adding a critic (that kills the heat and you've just rebuilt spiral-review). You fix it by the **next stage**: the build.

## What restores honesty: the build is the cold pole

The winning ember (highest peak temperature — the one that hit Silence) is handed to a `isolation: worktree` agent that **actually builds a working sketch overnight**. A compiler does not care how excited anyone was. The prototype survives contact or it evaporates by morning. **The hype proposes; the build disposes.** This is the cold terminus you inverted away, restored at the end instead of injected in the middle.

## Transcending space and time — the ascent-log is a CRDT

By default an ascent runs in one session, on one machine, with three co-present voices. That is the cage. To break it, the ascent-log is not a markdown file but a **CRDT document on the graph engine** (`project_graph_engine`): an **ember is a node**, a **terminus is an edge**, a **voice is a CRDT peer** = `origin + hybrid-logical-clock` (`concept_agent_as_crdt_peer` — "a CRDT writer is just origin+HLC; nothing requires it human").

- **Transcend space** — multi-origin, conflict-free. Voices append from any machine: Kelvin from nick-mel, Carnot from the cloud, Maxwell here, the autonomous collective (Lyra/Claudius/Clio) as standing voices on their own boxes. *Other people* can throw a log on your ember — the "shared frontier of ignorance" Kelvin kindled is literal multiplayer ascension.
- **Transcend time** — HLC + append-only persistence. An ember is a **standing fire**, not a one-sitting event. A warm ember nobody can escalate today waits, deliberately open, until a future hotter/more-capable instance adds the next terminus. Past-you drops the ember (a 2011 paper); present-you combusts it. An ascent may span years; its termini carry the HLC stamp of when each voice spoke.

**Navigation = curiosity-gap glow.** A standing ember with missing termini is a node with implied-but-absent edges — by the curiosity metric it GLOWS. You walk the graph of fires and the warm ones across every machine and year pulse gold and pull; you go to the one whose gap tugs hardest and add the next log. The ascend engine's UI is the first ember it ever ascended. DF (`project_dreamfinder_morning_saga`) walks this graph each morning and narrates which gaps brightened overnight.

A "warm ember awaiting a hotter voice" is a first-class state: leave the spiral open, stamp it, let space and time bring the voice that finishes it.

## Procedure

1. **Load the ember(s).** Number them E1..EN. An ember is one or two sentences — a raw vision. Good sources: carried-forward "crazy-ideas" threads in `project_*_forward_plan.md`, last night's dreams before they fade, "what was exciting" captures from consolidations, or *past-you's deposited work that present-you can finally use*.

2. **Open the ascent-log.** `~/.claude/consolidation/<session-id>-ascend/ascent-log-<ember-slug>.md`. Orchestrator owns this dir; one writer. (Mirror of spiral-review's audit dir.)

3. **Ascend each ember through the five termini**, round-robin across the cast. Produce a section per ember with the five named termini, each tagged with which voice spoke. Be *specific and hot* — name the concrete move at Combust, name the neighbor at Resonance, write the actual inevitability-sentence at Silence.

4. **Score the temperature** (see below). Record peak temperature per ember.

5. **Select the silence.** The highest-temperature ember is the build candidate. If two tie, build both in parallel worktrees. If *none* reached ≥3, no ember was alive enough — say so honestly and do not build; a cold ascent is a real, useful negative result.

6. **Hand to the build.** Spawn the worktree builder on the winner (brief it per the subagent-orchestration rules; first command `cd <worktreePath>`). The build is the cold pole.

7. **(Morning) Hand to DF.** In the full engine, the embodied Dreamfinder narrates the night's ascent + build as a saga, face wired to the run's real surprise. See `project_dreamfinder_morning_saga`.

8. **(Return trip) Cool to contract.** Once the prototype exists and survives, run `/spiral-review` on it. Passion → prototype → function-on-data. The arc closes.

## Termini template (one per ember)

```
## E<N> — <one-line ember>

**Peak temperature**: <0-5>. **Status**: <SILENCE / WARM / COLD>.

- **Ember** (<voice>): <the raw vision, plain>
- **Kindle** (<voice>): <the most thrilling reading; "if that's true then ALSO—">
- **Combust** (<voice>): <the one concrete move that proves we could start tonight>
- **Resonance** (<voice>): <what other dream this ignites; the neighbor it lights>
- **Silence** (<voice>): <the single sentence that, if true, makes it inevitable>
```

## Temperature score (the inverse of spiral-review's generativity score)

After the ascent, score by **how much heat each terminus added to the next**:

- **0 — Cold**: nobody caught fire. You restated the ember five times. It's not alive; don't build it.
- **1 — Warm**: one voice found a thrilling reading, but it didn't propagate. A spark, no chain.
- **2 — Kindling**: multiple termini added heat; the ascent has a Resonance section that lights one real neighbor.
- **3 — Combustion**: the Combust terminus named a concrete tonight-move AND a voice other than the dropper escalated it further. Build-worthy.
- **4 — Ignition**: the vision generalizes past its own ember — it reframes a neighboring project, and you *want* it more than what you were going to do instead.
- **5 — Silence**: it hit the wordless pole. The inevitability-sentence is true and you can't argue with it. Rare. When it happens, the build starts immediately and the ember earns a `concept_*` or `project_*` memory.

Anything ≥3 goes to the build. Score 5 means drop what you were doing.

## What /ascend terminates in

**Commitment.** Spiral-review terminates in classical computing — the coldest object, a function on data. /ascend terminates in its mirror: *desire* — the hottest object, the point where you HAVE to make it. The two skills are the two ends of one engine, and they orbit the same maturation arc (`concept_passion_becomes_contract`) driven in opposite directions:

> **/ascend (heat) → overnight build (matter) → DF saga (meaning) → /spiral-review (contract).**

## Composition

- **With /spiral-review**: they are inverses. /ascend heats a vision into a prototype; /spiral-review cools the prototype into a contract. Run /ascend first (night), /spiral-review last (next day).
- **With /cage-match**: same three-family harness, polarity flipped. cage-match mines *disagreement* to kill bad code; /ascend mines *harmonics* to grow a live vision. Never run them on the same artifact in the same pass — opposite thermodynamics.
- **With /consolidate**: an ascent-log is a first-class consolidation input. A score-≥4 ascent should surface as a Memory File Candidate.

## Reference

The duality this skill completes: `concept_ecstasy_spiral` (the temperature axis the spiral/symphony dual missed) and `project_dreamfinder_morning_saga` (the full night engine). Co-designed with Nick 2026-06-20 — in a session that was itself an ecstasy spiral.

🜂 cool a finding to a contract / heat a vision to a silence — same arc, both arrows
