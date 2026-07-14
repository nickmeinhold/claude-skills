# Persona A/B cage-match experiment (claude-skills, May 2026)

_A 10-PR blind-triaged experiment testing whether reviewer **persona prompts**
change review quality. Ran May 2026 via the (now-retired) `/cage-match-eval`
skill and `scripts/eval-tally.sh`. Preserved here 2026-07-10 when the tooling
was removed; the raw data lived in a loose `~/.claude/persona-eval/` dir with no
git home. **Statistically reanalyzed 2026-07-11** — see the correction below._

## TL;DR — an underpowered null: no effect here is distinguishable from noise

Two persona sets ran head-to-head across 10 PRs (139 findings, blind-tagged
`inline` / `deferred` / `rejected`):

- **Set A** — "production wrestling" (rhetorical flair, WWE quotes)
- **Set B** — "book-distilled" (Fowler / Beck / Hamming voices, no theatrics)

At N≈70 findings per set, **none of the measured effects clear statistical
significance** — every 95% confidence interval crosses zero:

| Claim | Gap (point est.) | 95% CI on the gap | Fisher exact p | Verdict |
|-------|------------------|-------------------|----------------|---------|
| Persona **accept** rate (A vs B) | +3.2pp | [−13.1, +19.6]pp | 0.73 | not significant |
| Persona **signal** rate | +11.9pp | [−2.4, +26.1]pp | 0.12 | not significant |
| Persona **reject** rate | −11.9pp | [−26.1, +2.4]pp | 0.12 | not significant |
| **Model family** (Claude vs Codex, personas pooled) | +14.0pp | [−3.0, +31.1]pp | 0.11 | not significant |

**The honest headline is the null: this experiment could not detect a persona
effect.** "Personas don't make much difference" is the most defensible single
statement the data supports — a null is exactly what an underpowered study can
safely report.

## What survives, and at what strength

1. **Persona axis: no detectable effect.** The accept-rate gap (3.2pp, p=0.73) is
   consistent with pure noise. This is the cleanest read in the dataset.

2. **Model family: directionally larger, but unproven.** Codex reviewers ran ~14pp
   higher inline-rate than Claude reviewers pooled across persona sets — a bigger
   point estimate than the persona effect — but p=0.11, CI [−3, +31]pp. This is a
   reasonable **prior for the next experiment**, not an established finding. It's
   the motivation for [NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md) (model-family
   triangulation with the family axis named explicitly and powered for).

3. **"Diagonal convergence" — weaker than it reads.** The original write-up frames
   same-model/opposing-persona reviewers as "agreeing" (Codex-A × Codex-B within
   4pp inline-rate, vs Claude×Codex diverging 8–19pp). But **inline-rate similarity
   is not agreement** — two reviewers can post identical acceptance rates while
   flagging entirely disjoint findings. True agreement needs per-finding pairwise
   matching, which was never done. Read the diagonal as "similar aggregate rates,"
   not "caught the same bugs." Per-cell n=25 (Codex) makes even the rate comparison
   underpowered.

## Why the experiment still shaped the product

Even underpowered, the directional signal (model family ≳ persona) plus the sound
prior that **different inductive biases catch different bugs** is why `/cage-match`
today runs **four different model families** — Maxwell (Claude), Kelvin (Gemini),
Carnot (Codex), Tesla (Grok) — rather than four personas of one model. The design
bet on the axis with the larger point estimate; it just shouldn't be described as
*proven*.

## Correction note (2026-07-11)

The preserved [COHORT_VERDICT.md](COHORT_VERDICT.md) calls the 12pp signal gap
"real" and the model-family effect a "decisive win / load-bearing finding." **Those
are overclaims** — neither clears significance (both p≈0.11–0.12). The document is
kept verbatim as the original artifact; this README supersedes its statistical
conclusions. The arithmetic in it is correct (independently recomputed from raw
`outcomes.json` × `mapping.json`, 0 unmatched findings) — only the significance
framing was wrong.

### Reproduce the significance tests

The 2×2 counts (recomputed from raw, all 10 cohort dirs):

```
Set A: 71 findings — inline 28, deferred 21, rejected 22   (accept 39.4%, signal 69.0%)
Set B: 68 findings — inline 29, deferred 26, rejected 13   (accept 42.6%, signal 80.9%)
By model (personas pooled): Claude 32/89 inline (36.0%) · Codex 25/50 inline (50.0%)
```

```python
from scipy.stats import fisher_exact
# persona accept:  A 28/71 vs B 29/68
print(fisher_exact([[28, 43], [29, 39]])[1])   # 0.73
# persona signal:  A 49/71 vs B 55/68
print(fisher_exact([[49, 22], [55, 13]])[1])   # 0.12
# model family:    Claude 32/89 vs Codex 25/50
print(fisher_exact([[32, 57], [25, 25]])[1])   # 0.11
```

## Contents

- **[COHORT_VERDICT.md](COHORT_VERDICT.md)** — the original full write-up (per-set
  and per-reviewer numbers, the diagonal-convergence observation, methodological
  caveats, the self-caught `eval-tally.sh` prefix bug). Arithmetic sound;
  significance conclusions superseded by this README.
- **[NEXT_EXPERIMENT.md](NEXT_EXPERIMENT.md)** — the never-run follow-up design:
  model-family triangulation (Claude × Codex × Gemini, persona held constant),
  powered to test the one axis that showed a larger point estimate here.
- **[personas-b.md](personas-b.md)** — the book-distilled persona set, written as
  drop-in substitutes for Maxwell / Kelvin / Carnot. Reusable regardless of the
  null (the personas work; they just don't measurably beat the alternative).
- **[tally.md](tally.md)** — the raw generated tally (2026-05-04).

## Status

**Closed.** The experiment is underpowered to answer its own question; the honest
result is a null on personas and a directional (unproven) lean toward model family.
The `/cage-match-eval` skill, `eval-tally.sh`, and `/ship` Step 5.6 auto-trigger
were removed 2026-07-10 — the tooling only analyzed data nothing will regenerate.
Raw per-PR data (`~/.claude/persona-eval/nickmeinhold__claude-skills-PR-*/`) is not
copied here; these distilled findings are the durable record.
