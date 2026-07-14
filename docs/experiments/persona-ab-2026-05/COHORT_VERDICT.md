# Cohort verdict — persona experiment (claude-skills, 10 PRs)

> **Superseded in part (2026-07-11).** This document's arithmetic is correct
> (independently recomputed from raw data, 0 unmatched findings), but its
> *significance* claims are overclaims: it calls the 12pp signal gap "real" and
> the model-family effect a "decisive win," yet neither clears statistical
> significance at N≈70 (both Fisher p≈0.11–0.12; 95% CIs cross zero). The honest
> result is an **underpowered null on personas** with a directional (unproven)
> lean toward model family. See [README.md](README.md) for the corrected reading.
> Kept verbatim below as the original artifact.

_Tally finalised 2026-05-04. All 10 cohort PRs blind-triaged; 139 findings tagged across `inline` / `deferred` / `rejected`._

---

## Headline

**Set B (book-distilled) edges Set A (production wrestling) on every metric — but the more interesting story is that the persona-prompt axis is *narrower* than the model-family axis. Codex×Codex (Carnot-A and Beck-B, same model, opposing prompts) agree more than Claude×Codex within either set.**

The persona-set was the experiment's intended axis. The model-family axis emerged on its own, without being designed for, and turned out to carry more signal.

---

## Numbers

### Per-set (139 findings across 10 PRs)

| Set | n | inline | deferred | rejected | accept | signal (inline+def) | reject |
|-----|---|--------|----------|----------|--------|---------------------|--------|
| **A — wrestling**     | 71 | 28 | 21 | 22 | 39.4% | 69.0% | 31.0% |
| **B — book-distilled**| 68 | 29 | 26 | 13 | 42.6% | 80.9% | 19.1% |

Set B's lead on `accept` is small (~3pp). Its lead on `signal` is larger (~12pp): findings from the book-distilled personas turned out real-but-out-of-scope more often, and noise less often. The reject-rate gap is the cleanest read — wrestling personas produced ~60% more rejected findings per finding raised.

### Per-reviewer (within-set composition)

| Set | Reviewer | Model    | n  | inline rate |
|-----|----------|----------|----|-------------|
| A   | Carnot   | Codex    | 25 | 52.0%       |
| A   | Maxwell  | Claude   | 46 | 32.6%       |
| B   | Beck     | Codex    | 25 | 48.0%       |
| B   | Maxwell  | Claude   | 43 | 39.5%       |

(Rows aggregate across naming inconsistencies — `carnot` + `carnot-A`, `maxwell` + `maxwell-A`/`-B`/`-b`. Naming drift in `mapping.json` is itself a finding; see "Methodological notes" below.)

### Diagonal convergence — the load-bearing finding

| Pair | Models | Same persona-set? | inline-rate Δ |
|------|--------|---------|----|
| Carnot-A × Beck-B   | Codex × Codex   | No (opposing) | **4.0 pp** |
| Maxwell-A × Carnot-A | Claude × Codex | Yes (Set A)   | 19.4 pp    |
| Maxwell-B × Beck-B   | Claude × Codex | Yes (Set B)   |  8.5 pp    |

**Same model family with opposing prompts agrees 3-5× more tightly than different model families with the same prompt.** Carnot-A (wrestling Codex) and Beck-B (book Codex) — sworn opposites by experimental design — separated by 4pp. Maxwell-A and Carnot-A — supposed teammates inside Set A — separated by 19pp.

That's the experiment telling us the axis we cared about wasn't the dominant axis at all.

---

## What this means

### Set B wins, but the win is procedural

Lower reject rate is the clean signal that the book-distilled personas (Fowler / Beck / Hamming / Carnot Cycle / etc.) generate fewer false-positives. Wrestling personas have rhetorical flair — `"Welcome to the party, pal."` — and that flair sometimes inflated philosophical observations into apparent findings. The tally records seven such findings as `rejected` for Set A vs. zero similar shape for Set B.

But the inline-rate gap (3pp) is small enough to be inside the cohort-size noise band. We have N≈70 per set; that's enough to call signal-rate confidently and accept-rate softly.

### The diagonal is the lead

What surprised both Nick and the orchestrator midway through the cohort: **Carnot (Set A) and Beck (Set B) — both Codex-driven, opposite prompt sets — agreed on substantive bug catches 4-for-4 on the PRs they both reviewed.**

The numbers above formalise that observation: Carnot-A and Beck-B run within 4pp of each other on inline rate, while Claude-driven Maxwell drifts 8-19pp away from same-set Codex teammates. The persona prompt is the loud variable. The model family is the quiet one. The model family is bigger.

The implication for the *next* experiment: don't run Set A vs Set B. Run **Claude×Claude vs Claude×Codex vs Claude×Gemini**, holding persona prompt constant. Triangulate model families. The reviewers we have today already drew that map for us; we just have to read it.

### Workaround-blindness, meta-edition

The tally script `eval-tally.sh` — itself shipped as part of this experiment — silently returned **"no PRs complete"** when run against production directories today. PR #30 renamed the cohort prefix from `claude-skills-PR-` to `nickmeinhold__claude-skills-PR-`. The `COHORT_PREFIX` constant in `eval-tally.sh` was never updated. The PR-32 golden-file test uses fixtures with the *old* prefix, so it kept passing.

The experiment built a measuring instrument and the instrument broke under exactly the rename one of the experiment's findings caused. The bug sat invisible because no one ran tally between PR-30 and 2026-05-04.

That's not a one-off. It's the textbook shape of `concept_workaround_blindness.md`: **persistent workarounds become invisible**. The prefix bug is structurally identical to the `--admin` merge fallthrough Nick captured during the run — a known-broken path that the orchestrator routes around so reliably it stops registering as broken.

The verdict on the experiment includes the verdict on its own infrastructure. The infrastructure had bugs. The experiment found them.

---

## Methodological notes

- **Reviewer naming drift** in `mapping.json` files: `carnot` / `carnot-A`, `maxwell` / `maxwell-A` / `maxwell-b` / `maxwell-B`. Suggests the naming convention evolved across PRs without backfilling. Tally aggregation handled it by grouping on `(set, model)` rather than `reviewer`, but the drift is itself a workaround-blindness instance.
- **Gemini reviewers (Kelvin, Sage)** were absent from most blind-doc files due to quota-exhaustion. The 8s cooldown shipped in PR-26 partially mitigated this for *intra-run* spacing but not for cross-run quota. Set A's Gemini surface and Set B's Gemini surface are both undersampled.
- **Order-effects in retrospective tagging**: the early PRs (20, 22, 23, 26, 31) were triaged today, retrospectively, while the later PRs (24, 27, 28, 29, 32) were tagged live during /ship. The deferred-vs-rejected line is the most order-sensitive distinction. Tagged today using a generous deferred rule (real concern + out-of-scope = deferred, regardless of whether a task was created at the time) to match the live-tagged calibration. This may modestly inflate the deferred bucket on retrospective PRs.
- **Sample size**: N≈70 per set is sufficient for narrow confidence on signal-rate (the reject gap), looser confidence on accept-rate. The 12pp signal gap is real; the 3pp accept gap is suggestive.

---

## Recommendations

1. **Retire Step 5.6 of /ship.** The cohort gate did its job — counted to 10 and self-deactivated. The experiment isn't worth re-running on Set A vs Set B; the question is answered. Leave the gate code in place but don't rearm it for another claude-skills cohort.

2. **Design the next experiment on the model-family axis.** Three reviewer slots, each running the same (probably Set B, since it edges) persona prompt: Claude (Maxwell) × Codex (Beck) × Gemini (Kelvin or successor). The interesting tally there isn't accept-rate; it's *unique findings* — what each family catches that the others miss.

3. **Fix `eval-tally.sh` `COHORT_PREFIX`.** Bring the script back to life with the correct prefix. Add a production smoke-test (not just the fixture-based golden-file test) so a future rename doesn't silently disable the instrument again.

4. **Workaround-blindness audit.** Grep recent transcripts for `--admin`, `--no-verify`, `EVAL_ROOT_OVERRIDE`, manual-rename steps in PR descriptions, and "documented in PR body" patterns. Each is a candidate. The diagonal-convergence finding has set the lens; use it.

5. **Capture the diagonal-convergence concept in memory.** Already done — `concept_diagonal_convergence.md` and `concept_workaround_blindness.md` are the two transferable insights this experiment crystallised. They'll outlive the cohort.

---

_Cohort closed. Set B wins narrowly. Model family wins decisively. Infrastructure caught its own bugs and we wrote them down._
