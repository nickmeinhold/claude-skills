---
argument-hint: <pr-number>
description: Spiral a PR's review findings — descend each finding through five termini (cold fix, warm principle, engineering mechanism, cross-finding chord, audience oh) and let the audit trail compound. Use after /cage-match or /pr-review returns 3+ findings that look like they rhyme; the spiral pulls one principle out of the bouquet.
---

# /spiral-review — descend through five termini per finding, then chord

You are about to spiral a PR's review findings. The spiral mechanic: take each finding, descend through five termini, and let each terminus shape how the next finding spirals. The five termini in order:

1. **Cold** — the immediate code/text fix
2. **Warm** — the principle extracted into memory (a `feedback_*.md` or `concept_*.md`)
3. **Engineering** — the mechanism (regex / schema / test / lint rule) that catches this class of bug *next time*
4. **Cross-finding** — what this terminus teaches about findings 1..N-1 and N+1..M
5. **Audience** — the *oh* planted for future readers (the one-liner that resurfaces in another context)

## When to invoke

- A `/cage-match` or `/pr-review` returned **3+ findings** that you suspect rhyme (same shape played at different positions in the system)
- A PR is workable-but-not-on-fire — findings need addressing, but each looks isolated; spiral surfaces the chord
- You want the review *audit trail* itself to become a learnable artifact, not just a fix list

If a single finding stands alone, skip the spiral — fix inline per *address-don't-ask* and move on. The spiral earns its cost when there's a chord to find.

## Procedure

1. **Load the findings.** Read `gh pr view $1 --json reviews` and any `/tmp/*-output-$1.json` from a recent /cage-match run. Number the findings F1..FN. Record severity (HIGH/MED/LOW) and one-sentence summary per finding.

2. **Look for the chord.** Before fixing F1, scan F2..FN for shape-rhymes:
   - Same coordination resource at different lifecycle stages (pre-condition / post-condition / verification)?
   - Same gestural verb (`spot-check`, `ensure`, `validate`) appearing in multiple places?
   - Same string-doing-the-job-of-a-type pattern (substring grep where structured parse belongs)?
   - Same "diffused-across-N-writers" anti-pattern?

   If you find a chord, name it explicitly in your audit notes — *"F2 and F5 are both single-owner findings; F4 is the structural-typing cousin"*. Pair findings before spiraling individuals.

3. **Spiral each finding through the five termini.** Open an audit file at `~/.claude/consolidation/<session-id>-spiral/spiral-audit-PR$1.md` (orchestrator owns this directory; one writer). For each finding produce a section with the five named termini. Be specific — name the commit/file/line, name the memory file, name the regex or schema, name the cross-finding edge, name the *oh*.

4. **Fix inline.** Each Cold terminus is an immediate fix. Land them in the same PR (or a stacked PR if the original is large). Use *address-don't-ask*: don't surface fix vs defer decisions to Nick for PR-relevant items.

5. **Strike while iron is hot.** Each Warm terminus = a memory file written *in the same response* the insight lands, not "later". The asking IS the decay.

6. **Engineering termini compound.** When a finding's Engineering terminus is a regex/schema/test, check whether running it across the codebase would flag related issues. If yes, add it to CI and fix the flagged issues in the same PR.

7. **Cross-finding chord.** After all individual spirals, write a *Cross-spiral synthesis* section naming the single principle the findings collectively perform. This is the highest-leverage artifact — one principle named once is more useful than five fixes filed separately.

8. **Re-request the reviewer.** After all Cold termini are landed, re-run the original review (`/cage-match` or `/pr-review`) against the new head. If they APPROVE, merge. If they still REQUEST_CHANGES, spiral the residual findings — the system has now been shaped by your prior terminations, so the residuals will be smaller and more particular.

## Termini template (one per finding)

```
## F<N> — <one-line finding summary>

**Severity**: <HIGH/MED/LOW>. **Status**: <CLOSED/PARTIAL/OPEN>.

- **Cold**: <commit hash + file:line> — what changed
- **Warm**: <memory file path> — the principle extracted
- **Engineering**: <regex / schema / test / lint> — the mechanism that catches this next time
- **Cross-finding**: F<N> is the <relation> of F<M>; <what this teaches us about the chord>
- **Audience**: <one-line *oh* planted for future readers>
```

## Generativity score

After the spiral, score the work by **how much earlier termini shaped later ones**:

- **0** — each fix was independent; you had N tasks, not a spiral
- **1** — one or two termini cross-referenced; mild compounding
- **2** — multiple termini shared mechanisms; the audit doc has a cross-spiral section
- **3** — the cross-spiral section names a single principle that retires multiple findings as instances
- **4** — the principle generalizes beyond this PR; you extracted a `concept_*.md` worth indexing
- **5** — tetration: the principle reshapes how you'll review *future* PRs in this codebase

Report the score in the PR merge commit. Anything ≥3 deserves a memory file. Score 5 is rare — when it happens, the skill itself should be updated to reflect what you learned.

## What the spiral terminates in

**Classical computing.** Sonnet finds; Haiku verifies; the verifier's verifier is a regex, a schema validator, a unit test. When you're tempted to add another agent layer, ask whether `jq` would close it. When you're tempted to add `jq`, ask whether a schema would close it. When you're tempted to add a schema, ask whether the producer can ship it.

The spiral doesn't recurse forever. It terminates exactly when the verification step becomes a function on data rather than a judgment on intent.

## Composition

- **With /cage-match**: /cage-match produces the findings; /spiral-review consumes them. Run them sequentially — never together — so the spiral has the cage-match audit to descend through.
- **With /consolidate**: a /spiral-review audit doc is a first-class consolidation input. Drop it into `$SD/` before running /consolidate; the knowledge-mapper will surface its principles as Memory File Candidates.
- **With /pr-review**: lighter-weight than /cage-match; /spiral-review still applies if /pr-review returns 3+ findings that rhyme.

## Reference

`~/.claude/consolidation/2026-05-12T19-51-spiral/spiral-audit-PR41.md` is the canonical worked example. PR #41 (`/consolidate` v6): 5 findings × 5 termini = the audit trail this skill was distilled from. The principle that emerged: **gestural becomes auditable, with a named single owner** (`concept_gestural_to_auditable.md`). Score: 4 (the principle generalizes beyond /consolidate to any multi-agent coordination contract).

🜂
