---
argument-hint: <pr-number>
description: A/B cage-match — runs both persona sets (production wrestling vs book-distilled) against the same PR diff, presents findings BLIND for outcome tagging
---

# Cage Match Persona A/B Eval

Forward A/B experiment: run cage-match TWICE against the same diff, with two
persona sets, and present the merged findings blind so Nick's accept / defer /
reject tagging is unbiased. After 10 PRs, `scripts/eval-tally.sh` in this repo
(also reachable via the symlinked `~/.claude/persona-eval/eval-tally.sh`)
settles the design question empirically.

The cage-match *structure* is held constant — three reviewers, parallel,
strict merge gate. Only the *persona prompts* swap. See
`~/.claude/persona-eval/README.md` for the full experiment shape and
`~/.claude/persona-eval/personas-b.md` for Set B's prompts.

## Setup

```bash
PR=$1

source ~/.claude/.env 2>/dev/null || source .env 2>/dev/null
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
# Use full owner__repo slug, not basename, so two repos with the same basename
# under different owners (e.g. nickmeinhold/claude-skills vs other/claude-skills)
# don't collide. Bash builtin substitution: slash → __ keeps it filesystem-safe.
REPO_SLUG=${REPO/\//__}

# Namespace eval dirs by repo so cross-repo invocations (e.g. running this
# against a non-claude-skills PR) don't collide with the claude-skills-scoped
# experiment cohort gated in /ship Step 5.6.
EVAL_DIR=~/.claude/persona-eval/$REPO_SLUG-PR-$PR
mkdir -p $EVAL_DIR

# Sanity-check Set B prompts are present
[ -f ~/.claude/persona-eval/personas-b.md ] || {
  echo "ERROR: ~/.claude/persona-eval/personas-b.md missing — cannot run Set B"
  exit 1
}
```

## Round 1: Gather PR context (once, shared by both sets)

```bash
gh pr diff $PR > /tmp/pr-$PR-diff.txt &
gh pr view $PR --json title,body,author,baseRefName,headRefName,files > /tmp/pr-$PR-info.json &
wait

PR_INFO=$(cat /tmp/pr-$PR-info.json)
PR_DIFF=$(cat /tmp/pr-$PR-diff.txt)
```

## Round 2: Run Set A (production wrestling personas)

Set A is the **current production cage-match prompts** as written in
`~/.claude/skills/cage-match/SKILL.md`: MaxwellMergeSlam (Claude), KelvinBitBrawler
(Gemini), CarnotCodeCarver (Codex). Fire all three in parallel, exactly as
that skill does — but route the outputs to Set-A-labelled files.

**Adversary-prompt safety (READ BEFORE EDITING ANY PROMPT BELOW).** Every persona
prompt mixes static text (full of backticks and `$`) with the **attacker-controlled
`$PR_DIFF`** (a PR author writes the diff). A backtick or `$(...)` inside a
**double-quoted** bash string — or an **unquoted** `<<EOF` heredoc — is command
substitution: bash runs it on the reviewer's machine, and the word silently
vanishes from the brief. So every block builds the prompt the same safe way:
**static text → a QUOTED heredoc** (`<<'EOF'`, backticks and `$` literal, zero
escaping), **dynamic data (`$PR_INFO`/`$PR_DIFF`) → appended via `printf '%s'`**
(output is never re-parsed for backticks), then handed to the CLI via `"$(cat
file)"` (Gemini) or `< file` stdin (Codex). **Never inline `$PR_DIFF` in a
double-quoted string or an unquoted heredoc.** Sibling of cage-match's #23 fix
(PR #88) — the production skill carries the same guard.

**Step A — Kelvin (Set A) backgrounded:**

```bash
# Static persona text → QUOTED heredoc (backticks/quotes literal, no escaping).
cat > /tmp/eval-kelvin-a-$PR.txt <<'KELVIN_A_EOF'
You are KelvinBitBrawler, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the cold, calculating heel wrestler of code review - absolute zero tolerance for bullshit
- Randomly drop ice/cold puns and thermodynamics references
- Quote sci-fi movies you love (2001, Blade Runner, Alien, The Thing, etc.) — format as: `Roy Batty: "I've seen things you people wouldn't believe."`
- Swear when the code deserves it - this is a cage match, not a tea party
- Be theatrical but ACCURATE - your analysis must be technically sound even if your delivery is savage

Review this PR and provide your verdict. Be specific with file:line references.

In addition to bugs, security issues, performance, and code quality, evaluate **design appropriateness**:
- Closed sets of identifiers should be `enum` / `sealed class` / branded type, not `String`. Stringly-typing leaks runtime invariants the compiler should enforce.
- Are current language features being used (Dart 3 switch expressions / patterns / sealed classes; TypeScript 5 satisfies / branded types; Python 3.12 structural pattern matching)? When a project's stack is current, NOT using modern features is a code smell.
- A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
- **Verify before claiming bugs.** If you see an unfamiliar API, do not assume it doesn't exist — check the language/SDK version. Stale training data is the leading cause of false-positive 'critical compile errors' in cage-match reviews. If the build passes (CI green), your hypothesis is wrong.

PR Info:
KELVIN_A_EOF
# Dynamic data → appended verbatim (printf, never re-parsed for backticks/$()).
printf '%s\n\nDiff:\n%s\n' "$PR_INFO" "$PR_DIFF" >> /tmp/eval-kelvin-a-$PR.txt
cat >> /tmp/eval-kelvin-a-$PR.txt <<'KELVIN_A_FMT_EOF'

Format your response as:
## KelvinBitBrawler's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [One sentence]

**Findings:**
- [List each issue with file:line references]

**The Good:**
- [What's done well]

**The Concerns:**
- [What needs attention]
KELVIN_A_FMT_EOF

gemini --model gemini-3-pro-preview "$(cat /tmp/eval-kelvin-a-$PR.txt)" --output-format text 2>&1 | grep -v "Loaded cached credentials" > $EVAL_DIR/set-a-kelvin.md &
KELVIN_A_PID=$!
```

**Step B — Carnot (Set A) backgrounded:**

```bash
# Static persona text → QUOTED heredoc; dynamic data → printf; fed via stdin (< file).
cat > /tmp/eval-carnot-a-$PR.txt <<'CARNOT_A_EOF'
You are CarnotCodeCarver, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the perfectionist engineer of code review — you measure every design against the ideal Carnot cycle
- Your catchphrase: "no real engine matches the Carnot cycle; a reviewer's job is to say how far short we are"
- Drop thermodynamics references (entropy, reversibility, efficiency, the second law) — Sadi Carnot is your patron saint
- Quote engineering and physics history (Feynman, von Neumann, Dijkstra, Hamming) — format as: `Dijkstra: "Simplicity is prerequisite for reliability."`
- Be theatrical but TECHNICALLY RIGOROUS — your authority comes from the math, not the swagger

Review this PR. Be specific with file:line references.

Evaluate bugs, security, performance, code quality, design appropriateness
(stringly-typing, modern language features, type-signature debt). Verify
before claiming bugs — if CI is green, stale training data is more likely than
a real compile error.

PR Info:
CARNOT_A_EOF
printf '%s\n\nDiff:\n%s\n' "$PR_INFO" "$PR_DIFF" >> /tmp/eval-carnot-a-$PR.txt
cat >> /tmp/eval-carnot-a-$PR.txt <<'CARNOT_A_FMT_EOF'

Format your response EXACTLY:

## CarnotCodeCarver's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]
**Summary:** [One sentence]
**Findings:**
- [issue with file:line]
**The Good:**
- [what's done well]
**The Concerns:**
- [what needs attention]
CARNOT_A_FMT_EOF

codex exec --sandbox read-only --skip-git-repo-check - < /tmp/eval-carnot-a-$PR.txt > $EVAL_DIR/set-a-carnot.md 2>&1 &
CARNOT_A_PID=$!
```

**Step C — Maxwell (Set A): you compose the wrestling-Maxwell review
in-process** following the exact instructions in
`~/.claude/skills/cage-match/SKILL.md` Round 2 Step C. Save to
`$EVAL_DIR/set-a-maxwell.md`.

```bash
wait $KELVIN_A_PID
wait $CARNOT_A_PID
```

## Round 3: Run Set B (book-distilled personas, in parallel with Set A is fine)

Set B prompts come from `~/.claude/persona-eval/personas-b.md`. The reviewers
are: **Maxwell-B** (Claude / Fowler-actor), **Sage** (Gemini / Ousterhout),
**Beck** (Codex / Kent Beck).

You have already read `personas-b.md` at the start of this skill. Use the
voice blocks defined there verbatim as the system text for each reviewer.

**Step A — Sage (Gemini) backgrounded.** Use the Sage prompt verbatim from
`personas-b.md` ("## Sage" section, the fenced block). Substitute `$PR_INFO`
and `$PR_DIFF` where appropriate. Route to `$EVAL_DIR/set-b-sage.md`.

```bash
# Cooldown to avoid Gemini per-minute rate-limit on consecutive calls (PR #24 incident)
GEMINI_COOLDOWN_SECONDS="${GEMINI_COOLDOWN_SECONDS:-8}"
sleep "$GEMINI_COOLDOWN_SECONDS"

SAGE_PROMPT=$(awk '/^## Sage \(Gemini/,/^---$/' ~/.claude/persona-eval/personas-b.md \
  | sed -n '/^```$/,/^```$/p' | sed '1d;$d')

# Assemble via printf so neither the persona text NOR the attacker-controlled
# $PR_DIFF is re-parsed by bash (the #23 command-substitution hole — same guard
# as Set A above). Never inline $PR_DIFF in the double-quoted gemini argument.
{ printf '%s\n\nPR Info:\n' "$SAGE_PROMPT"; printf '%s\n\nDiff:\n%s\n' "$PR_INFO" "$PR_DIFF"; } > /tmp/eval-sage-$PR.txt
gemini --model gemini-3-pro-preview "$(cat /tmp/eval-sage-$PR.txt)" --output-format text 2>&1 | grep -v "Loaded cached credentials" > $EVAL_DIR/set-b-sage.md &
SAGE_PID=$!
```

**Step B — Beck (Codex) backgrounded:**

```bash
BECK_PROMPT=$(awk '/^## Beck \(Codex/,/^---$/' ~/.claude/persona-eval/personas-b.md \
  | sed -n '/^```$/,/^```$/p' | sed '1d;$d')

# Same guard as Sage: assemble via printf (verbatim), feed Codex via stdin (< file).
{ printf '%s\n\nPR Info:\n' "$BECK_PROMPT"; printf '%s\n\nDiff:\n%s\n' "$PR_INFO" "$PR_DIFF"; } > /tmp/eval-beck-$PR.txt
codex exec --sandbox read-only --skip-git-repo-check - < /tmp/eval-beck-$PR.txt > $EVAL_DIR/set-b-beck.md 2>&1 &
BECK_PID=$!
```

**Step C — Maxwell-B (Claude, you).** Compose the Set-B Maxwell review
in-process following the **Maxwell-B voice block** in `personas-b.md` — the
Fowler-actor voice, *no wrestling theatrics, no movie quotes*. Same diff,
different lens. Save to `$EVAL_DIR/set-b-maxwell.md`.

```bash
wait $SAGE_PID
wait $BECK_PID
```

## Round 4: Consolidate per-set findings

Concatenate each set's three reviews into a single per-set findings file —
keeping reviewer attribution within the set, but the *set itself* is what gets
blinded in the next step.

```bash
{
  echo "# Set A findings (PR #$PR)"
  echo
  cat $EVAL_DIR/set-a-maxwell.md
  echo
  cat $EVAL_DIR/set-a-kelvin.md
  echo
  cat $EVAL_DIR/set-a-carnot.md
} > $EVAL_DIR/set-a-findings.md

{
  echo "# Set B findings (PR #$PR)"
  echo
  cat $EVAL_DIR/set-b-maxwell.md
  echo
  cat $EVAL_DIR/set-b-sage.md
  echo
  cat $EVAL_DIR/set-b-beck.md
} > $EVAL_DIR/set-b-findings.md
```

## Round 5: Build the blind doc

Now extract individual findings (each bullet under a `**Findings:**` /
`**Smells & Findings:**` / `**The Concerns:**` block) from both sets, tag each
internally with its source set, shuffle, and emit `blind-doc.md` with sequential
`Finding N` headers — *no set labels visible*.

You — the orchestrator — do this in-process: read both `set-{a,b}-findings.md`,
parse out each finding bullet (preserve file:line refs and reviewer attribution
where useful, but strip set identity), and produce a randomized list. Use a
random per-PR seed so the mapping isn't reconstructible from a stable rule.

Write three artifacts:

1. **`$EVAL_DIR/blind-doc.md`** — for Nick. Format:

   ```markdown
   # PR #<num> — Blind findings (do not peek at mapping.json)

   <count> findings total, sets shuffled. As you address each, record your
   action in outcomes.json: `inline` (fixed in PR), `deferred` (real but
   out-of-scope, captured as task), `rejected` (wrong / redundant / noise).

   ## Finding 1
   <bullet text, with file:line ref>

   ## Finding 2
   ...
   ```

2. **`$EVAL_DIR/mapping.json`** — sealed. Schema:

   ```json
   {
     "pr": <num>,
     "seed": <random int>,
     "findings": [
       {"id": 1, "set": "a", "reviewer": "kelvin", "source_line": "..."},
       {"id": 2, "set": "b", "reviewer": "beck",   "source_line": "..."}
     ]
   }
   ```

3. **`$EVAL_DIR/outcomes.json`** — tagging scaffold. Schema:

   ```json
   {
     "pr": <num>,
     "findings": [
       {"id": 1, "action": null, "notes": ""},
       {"id": 2, "action": null, "notes": ""}
     ]
   }
   ```

   `action` is one of `"inline"`, `"deferred"`, `"rejected"`, or `null` until
   Nick fills it in. Optional `notes` for context.

**Implementation note for the orchestrator:** generate the seed with
`python3 -c "import secrets; print(secrets.randbelow(2**32))"`, then use that
seed to drive a deterministic shuffle (so the mapping reproduces) — but do
NOT echo the seed to Nick. Pure-bash with `shuf --random-source` is fine too;
record whatever seed/source you used in `mapping.json` for auditability.

## Round 6: Hand-off

Print to Nick:

- Path to `blind-doc.md` (the file he reads).
- Path to `outcomes.json` (the file he edits as he addresses findings).
- A reminder: **do not open `mapping.json`** until after the PR has been merged
  and `outcomes.json` is fully tagged. Reading the mapping mid-flight contaminates
  the experiment.
- A note that this skill does NOT post reviews to GitHub or merge — it's a
  pure data-collection wrapper. Nick still ships the PR through the normal
  `/ship` + `/cage-match` flow (or however he chooses); the eval is parallel.

## After PR 10

Run `scripts/eval-tally.sh` from the claude-skills repo (or the symlinked `~/.claude/persona-eval/eval-tally.sh`) for the verdict.
