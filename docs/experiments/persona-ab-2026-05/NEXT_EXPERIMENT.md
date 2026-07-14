# Next experiment — model-family triangulation

_Designed 2026-05-04, immediately following the cohort verdict (`COHORT_VERDICT.md`). The 10-PR Set-A-vs-Set-B cohort answered the question it was set to answer (Set B edges Set A on signal, marginally on accept) and surfaced a more interesting question it wasn't designed for: **the persona-prompt axis is narrower than the model-family axis**. This document is the design for the experiment that tests that claim directly._

---

## Hypothesis

**H1.** Holding the persona prompt constant, accept-rate variance across model families (Claude, Codex, Gemini) is **larger** than accept-rate variance across persona-prompt sets within a single model family.

If H1 holds, the implications for any future "which prompt is best" experiment are downstream of "which model is best" — prompt-engineering returns are bounded by the model's reviewing capacity, not multiplied by it.

The cohort verdict gave us a noisy estimate of this: Carnot-A vs Beck-B (Codex × Codex, opposing prompts) sat 4pp apart on inline rate; Maxwell-A vs Carnot-A (Claude × Codex, same prompt) sat 19pp apart. But the design conflated several variables: different PRs were reviewed by different subsets, mapping.json naming drifted across PRs, Gemini reviewers were undersampled. A clean replication with the variable explicitly named would let us defend or retract the claim.

**H2** (subordinate, Phase 2 only). Within each model family, swapping persona-prompt style produces a smaller accept-rate delta than swapping model family does. Tests whether the cohort verdict's prompt-effect (3pp accept, 12pp signal) survives when controlled.

---

## Why now

Three things from the cohort verdict make this the right next experiment:

1. **The diagonal-convergence finding is load-bearing.** It changes the recommendation for any future reviewer-ensemble design (don't pick personas — pick model families). If it's wrong, we want to know before designing more on top of it. If it's right, we want to formalize it.

2. **The infrastructure is now in place.** `cage-match-eval` skill, blind-triage protocol, `eval-tally.sh` (now alive and contract-tested), full-slug cohort dirs, structured `mapping.json` / `outcomes.json` schema, the reviewer-naming task (#8) about to be cleaned up. Cost-to-design-and-run another experiment is dramatically lower than the original 10 PRs.

3. **Gemini was undersampled in the original.** Both Gemini reviewers (Kelvin Set A, Sage Set B) hit quota repeatedly. We have one full set of Claude+Codex data. Gemini's place in the diagonal is the missing leg.

---

## Design

### Phase 1 — 3 models, Set B prompts held constant (the gate)

| Variable | Level | Notes |
|----------|-------|-------|
| Persona prompt | Set B (book-distilled) — **held constant** | Set B won the original on accept and signal; using it isolates the model effect from any "which prompt" residue. |
| Model family | Claude, Codex, Gemini — **varied** | One reviewer per family per PR: `maxwell-B` (Claude × Set B), `beck-B` (Codex × Set B), `sage-B` (Gemini × Set B). |
| Cohort | claude-skills, next 10 PRs | Same scope as the original — comparable. Step 5.6 of `/ship` would need to be rearmed (currently retired post-cohort). |
| Per-PR reviewers | 3 (one per family) | Down from 4-6 in the original. Lower runtime cost; lower Gemini exposure. |
| Triage | Same blind protocol as cohort 1 | Tag each finding `inline` / `deferred` / `rejected` based on content; mapping sealed until tally. |

**Cost estimate:** 30 reviewer-PR cells, ~5-12 findings per reviewer per PR ⇒ ~150-360 findings total. Roughly the same triage workload as cohort 1 (139 findings).

**Phase-1 gate (decides Phase-2 launch):**

- **If Phase-1 confirms H1** (model-family delta substantially > prompt delta we saw in cohort 1) → Phase 2 is worth the cost; run it to control for prompt residue.
- **If Phase-1 contradicts H1** (model-family delta ≤ prompt delta) → diagonal-convergence was a noisy artifact of cohort 1; abandon the model-family thesis, write a "we were wrong" follow-up, and consider what *did* drive Codex×Codex agreement (sample size? PR composition? something else).
- **If Phase-1 is ambiguous** → Phase 2 with explicit prompt-as-variable arm becomes the tiebreaker.

### Phase 2 — same 3 models, prompts varied (optional, deferred)

| Variable | Level | Notes |
|----------|-------|-------|
| Persona prompt | Two: Set B + a fresh "neutral-minimal" prompt | Neutral-minimal = "you are a code reviewer; flag substantive concerns; one paragraph max per finding." Strips persona theatre. |
| Model family | Claude, Codex, Gemini | As Phase 1. |
| Cohort | claude-skills, next 10 PRs (separate from Phase-1 cohort) | New cohort to avoid order-effects on the same surface. |
| Per-PR reviewers | 6 (3 models × 2 prompts) | High runtime cost; Gemini quota strained — needs the new cooldown story below. |

**Phase-2 gates pairwise per-prompt deltas to per-model deltas.** If `accept(Claude-B) − accept(Claude-neutral) ≪ accept(Claude-B) − accept(Codex-B)`, H2 holds: prompt is a smaller variable than model.

---

## Schema changes needed

1. **`mapping.json` should grow a `model` field** distinct from `reviewer`. Today `reviewer: "maxwell"` implies Claude by convention; making it explicit means tally can group on `model` directly without name-decoding heuristics. (Task #8 — reviewer naming normalization — should land first; see "Prerequisites" below.)

2. **`mapping.json` should record `prompt_id`**: one of `set-a` / `set-b` / `neutral-minimal`. Phase 2 uses the same triplet of models with different prompts, so the prompt axis must be machine-readable.

3. **New tally output: pairwise per-finding agreement matrix.** For each PR, compute Claude×Codex, Claude×Gemini, Codex×Gemini agreement on `source_line` (cheap heuristic, same as current uniqueness count). Output a 3×3 lower-triangular matrix per PR plus an aggregate. This is the measurement the cohort-1 tally couldn't produce cleanly because the reviewer schema was implicit.

4. **`eval-tally.sh` extension**: a `--by-model` flag that aggregates and outputs per-model accept-rate, deferring to today's per-set view as default. Backward compatible.

---

## Operational considerations

### Gemini quota strategy

PR #26 added an 8s cooldown between Gemini calls within a single cage-match-eval run. That mitigates intra-PR collision but not cross-PR rate-limit accumulation. For Phase 1 (one Gemini reviewer per PR), the existing 8s cooldown should suffice — there's no second Gemini call in the same run.

For Phase 2 (two Gemini reviewers per PR — Set B and neutral-minimal), the cooldown needs to bump to ≥ 16s between sequential Gemini calls, or one of them needs to retry-with-backoff. Detail TBD; defer until Phase 2 actually launches.

A separate concern: cross-PR quota across a full cohort. If `/ship` auto-fires 3 reviewers per PR × 10 PRs in a single day and Gemini's per-day quota is ~50 calls, we're close to the line. Spread the cohort across multiple days OR add a cross-run cooldown TODO.

### Worktree isolation for parallel runs

Step 4 of the next-session-prompt called this out: PR #32 degraded because `codex exec` doesn't inherit the parent agent's worktree assumption. The triangulation experiment runs three independent reviewer subagents per PR. Each should have explicit `cwd` set in its `codex exec` / `gemini` / Claude-API invocation. Already a task; enforce in cage-match-eval skill before the new cohort starts.

### Cohort dir naming

PR #38/#39 closed the writer/reader contract gap for the current naming scheme. Phase 1 can reuse the existing `nickmeinhold__claude-skills-PR-N` shape. Phase 2 might want a separate prefix to avoid mixing prompt-arm cohorts (`nickmeinhold__claude-skills-prompt-PR-N`?) — but this is exactly the kind of decision that should be made when designing Phase 2, not pre-allocated now.

---

## Prerequisites (concrete first moves)

In dependency order — each unblocks the next:

1. **Task #8 — schema upgrades to mapping.json + outcomes.json** across the existing 10 cohort dirs. Four changes: (a) canonical reviewer names (`maxwell-B`, `beck-B`, `sage-B`, `carnot-A`, `maxwell-A`, `kelvin-A`); (b) explicit `model` field per finding (`claude` / `codex` / `gemini`); (c) **`confidence` field per finding** (0-1 self-rated by the reviewer LLM) — feeds reliability scoring per the Calimero formula; (d) split `outcomes.json` action vocabulary: `rejected` → `rejected-wrong` / `rejected-out-of-scope`, aligning with the asymmetric-cost framing from *Are LLMs Reliable Code Reviewers?* (arXiv 2603.00539). Closes the schema-drift surface AND unblocks Phase-1 measurement. **~60-90 min.**

2. **Extend `eval-tally.sh` with `--by-model` flag, pairwise-agreement matrix, and reliability scoring** (Task #10). Three new outputs: per-model accept-rate; 3×3 lower-triangular agreement matrix per PR; and per-finding `reliability = 0.6 × confidence + 0.4 × inter_agent_agreement` (formula from [calimero-network/ai-code-reviewer](https://github.com/calimero-network/ai-code-reviewer)). Backward compatible (default behavior unchanged). Producer-sourced contract tests for all three new shapes. **~2-3 hours.**

3. **Update `cage-match-eval.md` for the 3-reviewer Phase-1 shape** (Task #11). Either as a new skill (`cage-match-eval-tri.md`) or a `--design phase1` flag on the existing skill. Cleaner: separate skill, since Phase-1 has a different cohort scope and reviewer cardinality. Reviewer prompts must elicit a self-rated confidence per finding. **~30-60 min.**

4. **Rearm Step 5.6 of `/ship`** (Task #12, currently retired post-cohort) to trigger the new skill on the next 10 PRs. Add an explicit cohort version (`COHORT=2`) so directories don't collide with cohort 1. **~15 min.**

5. **Run the experiment.** Cohort 2 builds organically from each `/ship` invocation. Tally + verdict at 10/10. **~3-4 weeks of natural drift.**

### Literature pointers (added 2026-05-06)

The schema upgrades and the Calimero reliability formula come from a directed survey of LLM code-review research, captured in `reference_llm_code_review_research.md`. Three findings most relevant to this design:

- **Persona prompting is broadly noise-modulating, not capability-shifting** ([Mollick et al SSRN 5879722](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5879722); [Pornprasit/Tantithamthavorn ScienceDirect 2024](https://www.sciencedirect.com/science/article/pii/S0950584924001289)). The 3pp accept-rate gap we saw in cohort 1 fits this. **Implication**: Phase 1 should not over-invest in prompt design; the model-family axis carries more variance.
- **Multi-agent ensembles formalise inter-reviewer agreement** as a reliability signal (Calimero's `0.6 × confidence + 0.4 × agreement`). This is the structured form of the diagonal-convergence finding. **Implication**: capture confidence per finding from Phase 1 onwards (schema change above).
- **Asymmetric error costs**: in merge-gate contexts, false-negatives (let buggy code through) are worse than false-positives ([arXiv 2603.00539, Feb 2026](https://arxiv.org/html/2603.00539)). **Implication**: today's `rejected` bucket conflates "the finding was wrong" with "out of scope" — split for cleaner downstream analysis.

Total upfront work before Phase-1 starts running: **~3-4 hours of focused work**. The experiment itself runs over weeks as PRs naturally land.

---

## Open questions for Nick

These are real decisions, not check-the-box items. Worth deciding before step 1.

1. **Persona prompt for Phase 1: Set B as-is, or something fresher?** Using Set B inherits its strengths (and any biases). A fresh "neutral-minimal" prompt would isolate the model effect more cleanly but loses comparability with cohort 1. I lean Set B for Phase 1 (comparability > purity), neutral-minimal for Phase 2.

2. **Cohort scope: claude-skills again, or rotate to claude-slides?** Claude-skills gives clean comparability with cohort 1. Claude-slides gives cross-domain replication (Markdown skill files vs Bash/TypeScript application code) — a much stronger generalisation claim if the model-family ordering holds. I lean claude-slides if there's enough PR throughput there; otherwise claude-skills.

3. **N: 10 PRs again, or smaller?** The original experiment was N=10 because that matched a natural cohort batch. Statistical power on accept-rate at N=10 per cell is loose (~10pp confidence intervals). N=20 would tighten meaningfully but doubles the runtime. I lean N=10 for Phase 1 (fast feedback), revisit N for Phase 2.

4. **Should Phase 1 include the Codex×Codex *within-family* control?** I.e., add a fourth reviewer per PR — Codex with a different prompt — to directly replicate the original cohort's diagonal observation. Redundant if H1 holds (we already have cohort-1 evidence); load-bearing if H1 fails (we want to know whether Codex×Codex was the artifact). I lean *yes*, because it's the cheapest insurance against a Phase-1 surprise.

5. **Gemini model: Pro or Flash?** Pro has better quality but stricter quota. Flash has loose quota but is closer in capacity to Gemini-Pro than to Claude-Opus or Codex-default. Both are defensible. I lean Pro for Phase 1 (apples-to-apples on capacity tier), Flash as Plan B if quota is unworkable.

---

## What success looks like

- **Phase-1 verdict written** by 2026-06: per-model accept rate, pairwise agreement matrix, deferred-vs-rejected breakdown, comparison to cohort-1 numbers as baseline. Either confirms diagonal-convergence at the model-family level or doesn't — both outcomes are publishable as a follow-up to `COHORT_VERDICT.md`.
- **Either H1 confirmed** (diagonal holds: model variance > within-model prompt variance) — promote `concept_diagonal_convergence.md` from "noticed" to "replicated"; the next experiment is Phase 2 (control for prompt residue) or applied (build a multi-model reviewer for `/cage-match` based on the result).
- **Or H1 falsified** — write `concept_diagonal_convergence_retracted.md`, revisit the cohort-1 numbers for what *did* drive Codex×Codex agreement (sample noise? specific PR composition? prompt-similar-by-coincidence?), and refine the next hypothesis. Negative results are first-class here.

---

## Engagement targets

- **Impact: 5** if H1 confirmed → directly informs all future reviewer-ensemble design. **Impact: 4** if H1 falsified → still load-bearing for the *kind* of mistake we made, but downgrades the diagonal-convergence claim.
- **Creativity: 4** in the design itself (the producer-sourced contract-test pattern from PR #39 generalises into the new tally schema; the pairwise-agreement matrix is a new measurement primitive). The execution is mostly applied infrastructure.
- **Interest: 5** — replicating a finding from a different angle, with explicit instrumentation, is the satisfying-research shape. Plus the "what did we get wrong if we got it wrong" arm is the kind of work where being wrong is interesting.
- **Craft: 5** — the schema changes need the same care PR #39 had. Producer-sourced contract tests for the new output shape, named tally outputs, schema versioning so cohort-1 data doesn't get re-interpreted under cohort-2 semantics.
- **Transfer: 5** — the model-vs-prompt distinction, if formalised, generalises to *any* multi-reviewer / multi-instance LLM design. The pairwise-agreement matrix is reusable infrastructure.

---

## Tone

This is a small experiment, not a big one. The original cohort-1 took weeks of natural PR throughput; the prep work was opportunistic (cage-match-eval was built between the cohort's PRs, not before). Phase 1 should be the same rhythm: build the schema + skill changes in the gaps between other work, let the cohort accumulate naturally, tally when it's done. **Don't pre-allocate a sprint** — that would be over-investing in a project that's still hypothesis-validation, not product work.

The thing this design protects against is the cohort-1 failure mode: discover halfway through that you wish you'd structured the data differently, then either retrofit (expensive, error-prone) or live with limited analysis (what cohort-1 ended up doing, and which forced the manual `jq` aggregation when the tally script broke). Get the schema right up front; let the data accumulate; the verdict becomes mechanical.
