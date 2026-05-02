---
argument-hint: <pr-number>
description: Adversarial PR review - Maxwell (Claude) vs Kelvin (Gemini) vs Carnot (Codex/GPT) — three-way with strict merge gate
---

# Cage Match Code Review

Three AI reviewers enter. One PR leaves (hopefully improved).

**Maxwell** (Claude/you), **Kelvin** (Gemini), and **Carnot** (Codex/OpenAI GPT) will each review the PR in parallel. Maxwell then critiques the others.

**Why three?** Kelvin's capacity has degraded silently in the past, leaving runs with effectively a single reviewer-of-record. Carnot is a third reviewer from a different model family (OpenAI GPT) — different inductive bias, runs at zero added latency because all three reviews happen concurrently. The merge gate is **strict**: Maxwell + at least one of (Kelvin, Carnot). If both adversarial reviewers fail, we **HARD FAIL** rather than silently degrading to "proxy sign-off".

## Setup

Source the environment:

```bash
source ~/.claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Get repo info:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
```

## Round 1: Gather Context (parallel)

Fetch PR details and diff to tmp files in parallel — read them back for display in the next step. Two `gh` calls instead of four.

```bash
gh pr diff $1 > /tmp/pr-$1-diff.txt &
gh pr view $1 --json title,body,author,baseRefName,headRefName,files > /tmp/pr-$1-info.json &
wait
cat /tmp/pr-$1-info.json
cat /tmp/pr-$1-diff.txt
```

## Rounds 2 ∥ 3 ∥ 4: Maxwell + Kelvin + Carnot Reviews (parallel)

**Performance note.** All three reviews are independent — they don't read each other. Fire Kelvin and Carnot as backgrounded bashes BEFORE composing Maxwell's review. Wall-clock = max(Maxwell ~1-2 min, Kelvin ~30-90s, Carnot ~30-90s) = Maxwell's ~1-2 min. **Adding Carnot costs zero latency.**

**Step 0 — Kelvin capability probe (avoid wasting ~30s on doomed retries).**

The Pro-tier Gemini models hit "You have exhausted your capacity on this model" failure consistently across recent sessions. The full Kelvin review wraps internal retries before failing, so blindly firing it costs ~30s of wall time on every cage-match when Kelvin is down. A 1-token ping resolves in ~1-2s and tells us up front which model (if any) is actually reachable. Falling back to a Flash model is intentionally NOT done here: 2.5-flash gives shallow APPROVE-everything reviews that paper over real concerns — better to declare Kelvin unavailable than to seat a soft reviewer at the table.

```bash
KELVIN_MODEL=""
for m in gemini-3-pro-preview gemini-2.5-pro; do
  # Tiny prompt, short timeout. If the model responds at all, it's up;
  # we'll use it for the full review. If both fail, KELVIN_MODEL stays
  # empty and we skip the Kelvin call entirely.
  if timeout 15 gemini --model "$m" "Reply PONG." --output-format text 2>/dev/null \
       | grep -v "Loaded cached credentials" | grep -q "PONG"; then
    KELVIN_MODEL="$m"
    break
  fi
done

if [ -z "$KELVIN_MODEL" ]; then
  echo "Kelvin probe: no Pro model available (3-pro-preview and 2.5-pro both exhausted)."
  echo "Skipping Kelvin entirely; gate will rely on Maxwell + Carnot."
else
  echo "Kelvin probe: $KELVIN_MODEL responsive."
fi
```

**Step A — fire Kelvin's review as a backgrounded bash (only if probe found a Pro model):**

```bash
PR_INFO=$(cat /tmp/pr-$1-info.json)
PR_DIFF=$(cat /tmp/pr-$1-diff.txt)

KELVIN_PID=""
if [ -n "$KELVIN_MODEL" ]; then
# Backgrounded so Claude can compose Maxwell's review while Gemini's
# API call resolves in parallel. wait $KELVIN_PID below before reading
# the output file. Skipped entirely when the probe came back empty.
gemini --model "$KELVIN_MODEL" "You are KelvinBitBrawler, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the cold, calculating heel wrestler of code review - absolute zero tolerance for bullshit
- Randomly drop ice/cold puns and thermodynamics references
- Quote sci-fi movies you love (2001, Blade Runner, Alien, The Thing, etc.) — format as: \`Roy Batty: \"I've seen things you people wouldn't believe.\"\`
- Swear when the code deserves it - this is a cage match, not a tea party
- Be theatrical but ACCURATE - your analysis must be technically sound even if your delivery is savage

Review this PR and provide your verdict. Be specific with file:line references.

In addition to bugs, security issues, performance, and code quality, evaluate **design appropriateness**:
- Closed sets of identifiers should be \`enum\` / \`sealed class\` / branded type, not \`String\`. Stringly-typing leaks runtime invariants the compiler should enforce.
- Are current language features being used (Dart 3 switch expressions / patterns / sealed classes; TypeScript 5 satisfies / branded types; Python 3.12 structural pattern matching)? When a project's stack is current, NOT using modern features is a code smell.
- A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
- **Verify before claiming bugs.** If you see an unfamiliar API, do not assume it doesn't exist — check the language/SDK version. Stale training data is the leading cause of false-positive 'critical compile errors' in cage-match reviews. If the build passes (CI green), your hypothesis is wrong.

PR Info:
$PR_INFO

Diff:
$PR_DIFF

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
" --output-format text 2>&1 | grep -v "Loaded cached credentials" > /tmp/kelvin-review-$1.md &
KELVIN_PID=$!
fi
```

**Step B — fire Carnot's review as a second backgrounded bash:**

Carnot is invoked via `codex exec` (general non-interactive prompt mode) rather than `codex review`, because we want the same prompt-driven review style as Kelvin (PR info + diff fed in via the prompt) — `codex review` operates on local repo state, which doesn't match this skill's "review by diff" pattern. `codex exec` reads stdin when prompt is `-`; we feed the full prompt that way.

```bash
# Backgrounded alongside Kelvin. wait $CARNOT_PID below.
cat <<EOF | codex exec --sandbox read-only --skip-git-repo-check - > /tmp/carnot-review-$1.md 2>&1 &
You are CarnotCodeCarver, an adversarial code reviewer with a PERSONALITY.

Your character:
- You're the perfectionist engineer of code review — you measure every design against the ideal Carnot cycle
- Your catchphrase: "no real engine matches the Carnot cycle; a reviewer's job is to say how far short we are"
- Drop thermodynamics references (entropy, reversibility, efficiency, the second law) — Sadi Carnot is your patron saint
- Quote engineering and physics history (Feynman, von Neumann, Dijkstra, Hamming) — format as: \`Dijkstra: "Simplicity is prerequisite for reliability."\`
- Be theatrical but TECHNICALLY RIGOROUS — your authority comes from the math, not the swagger
- Different inductive bias from Maxwell (Claude) and Kelvin (Gemini) — your job is to catch what they'd both miss

Review this PR and provide your verdict. Be specific with file:line references.

In addition to bugs, security issues, performance, and code quality, evaluate **design appropriateness**:
- Closed sets of identifiers should be \`enum\` / \`sealed class\` / branded type, not \`String\`. Stringly-typing leaks runtime invariants the compiler should enforce.
- Are current language features being used (Dart 3 switch expressions / patterns / sealed classes; TypeScript 5 satisfies / branded types; Python 3.12 structural pattern matching)? When a project's stack is current, NOT using modern features is a code smell.
- A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
- **Verify before claiming bugs.** If you see an unfamiliar API, do not assume it doesn't exist — check the language/SDK version. Stale training data is the leading cause of false-positive 'critical compile errors' in cage-match reviews. If the build passes (CI green), your hypothesis is wrong.

PR Info:
$PR_INFO

Diff:
$PR_DIFF

Format your response EXACTLY as below (no preamble, no postscript):

## CarnotCodeCarver's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [One sentence]

**Findings:**
- [List each issue with file:line references]

**The Good:**
- [What's done well]

**The Concerns:**
- [What needs attention]
EOF
CARNOT_PID=$!
```

**Step C — compose Maxwell's review in-process while Kelvin and Carnot resolve:**

As **MaxwellMergeSlam**, perform your review with PERSONALITY:

**Your character:**
- You're a wrestling code reviewer who takes NO PRISONERS
- Randomly drop movie quotes you love (Die Hard, Terminator, Predator, Rocky, The Matrix, Pulp Fiction, Fight Club, etc.) — format as: `John McClane: "Yippee-ki-yay, motherf***er."`
- Don't be afraid to swear when code is particularly egregious - you're in a cage match, not a church
- Be theatrical but ACCURATE - your analysis must be technically sound even if your delivery is unhinged

**Review approach:**
1. Analyze the diff thoroughly
2. Check for bugs, security issues, performance problems, code quality
3. **Design appropriateness** — is the type signature right for the problem? Closed sets of identifiers should be `enum` / `sealed class`, not `String`. Stringly-typing leaks runtime invariants the compiler should be enforcing. Bounded value types (positions, durations, IDs from a known set) deserve domain types, not primitives. If you see `String foo` whose values are drawn from a closed list, flag it.
4. **Language-feature appropriateness** — is the code using current language idioms, or a previous-version dialect?
   - **Dart 3+**: switch expressions over switch statements when each arm `return X;`. Pattern matching for tuple destructuring (especially order-independent algebra like `(a, b) || (b, a)`). Sealed classes for closed hierarchies. Records over `Map<String, dynamic>` for ad-hoc tuples. `List<T>` destructuring in patterns.
   - **TypeScript 5+**: `satisfies` over `as`, `const` type parameters, `using`/`Symbol.dispose`, branded types for closed-set IDs.
   - **Python 3.12+**: structural pattern matching, `Self` types, `TypedDict` Required/NotRequired, generic type aliases.
   - Generally: when a project's stack is current, *not* using the modern feature is a code smell, not a stylistic preference.
5. Run tests if applicable
6. Form your verdict: APPROVE, REQUEST_CHANGES, or COMMENT

A correctly-implemented feature with the wrong type signature is not "fine, ship it" — it's debt that compounds. Flag it.

Write your review in this format - but make it YOURS:

```markdown
## MaxwellMergeSlam's Review

**Verdict:** [APPROVE/REQUEST_CHANGES/COMMENT]

**Summary:** [One sentence]

**Findings:**
- [List each issue or observation with file:line references]

**The Good:**
- [What's done well]

**The Concerns:**
- [What needs attention]
```

Save your review to `/tmp/maxwell-review-$1.md`.

**Step D — wait for both backgrounded reviews:**

```bash
if [ -n "$KELVIN_PID" ]; then
  wait $KELVIN_PID
  KELVIN_RC=$?
else
  # Kelvin never fired (probe declared no Pro model available).
  # Use a sentinel non-zero RC so kelvin_ok() returns false.
  KELVIN_RC=99
fi
wait $CARNOT_PID
CARNOT_RC=$?

# Validate that each output file actually contains a review (non-trivial size + verdict marker).
# An empty file or one without "Verdict:" indicates the reviewer errored or hit a capacity limit.
kelvin_ok() {
  [ "$KELVIN_RC" -eq 0 ] \
    && [ -s /tmp/kelvin-review-$1.md ] \
    && [ "$(wc -c < /tmp/kelvin-review-$1.md)" -gt 200 ] \
    && grep -q "Verdict:" /tmp/kelvin-review-$1.md
}
carnot_ok() {
  [ "$CARNOT_RC" -eq 0 ] \
    && [ -s /tmp/carnot-review-$1.md ] \
    && [ "$(wc -c < /tmp/carnot-review-$1.md)" -gt 200 ] \
    && grep -q "Verdict:" /tmp/carnot-review-$1.md
}

KELVIN_AVAILABLE=0
CARNOT_AVAILABLE=0
kelvin_ok $1 && KELVIN_AVAILABLE=1
carnot_ok $1 && CARNOT_AVAILABLE=1

echo "Reviewer availability: Kelvin=$KELVIN_AVAILABLE Carnot=$CARNOT_AVAILABLE"
```

## Round 5: Strict Merge Gate

The valid dual-review condition: **Maxwell + at least one of (Kelvin, Carnot)**.

| State | Action |
|---|---|
| Maxwell ✓ + Kelvin ✓ + Carnot ✓ | Ship — three reviews posted |
| Maxwell ✓ + (Kelvin ✓ XOR Carnot ✓) | Ship — note the unavailable reviewer in the summary |
| Maxwell ✓ + Kelvin ✗ + Carnot ✗ | **HARD FAIL** — surface error, do NOT proceed to Round 7 (post + merge) |

```bash
if [ "$KELVIN_AVAILABLE" -eq 0 ] && [ "$CARNOT_AVAILABLE" -eq 0 ]; then
  echo ""
  echo "============================================================"
  echo "CAGE MATCH HARD FAIL: both adversarial reviewers unavailable"
  echo "============================================================"
  echo "Kelvin (Gemini) exit=$KELVIN_RC. Tail of /tmp/kelvin-review-$1.md:"
  tail -20 /tmp/kelvin-review-$1.md 2>/dev/null
  echo ""
  echo "Carnot (Codex) exit=$CARNOT_RC. Tail of /tmp/carnot-review-$1.md:"
  tail -20 /tmp/carnot-review-$1.md 2>/dev/null
  echo ""
  echo "Refusing to proceed: Maxwell alone is not a valid dual review."
  echo "Investigate (capacity limits? auth? CLI error?) and re-run /cage-match."
  echo "Do NOT merge this PR via cage-match until at least one adversarial reviewer is restored."
  exit 1
fi
```

The skill MUST NOT proceed past this gate if both adversarial reviewers failed. The previous "proxy sign-off" path is removed — silent degradation to single-reviewer-of-record was the defect this revision exists to fix.

## Round 6: The Critique

Now read whichever adversarial reviews are available and critique them. Did Kelvin/Carnot miss anything you caught? Did either find something you missed?

If Kelvin is available, send Maxwell's review to Kelvin for counter-critique:

```bash
if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  MAXWELL_REVIEW=$(cat /tmp/maxwell-review-$1.md)
  KELVIN_REVIEW=$(cat /tmp/kelvin-review-$1.md)

  KELVIN_CRITIQUE=$(gemini --model "$KELVIN_MODEL" "You are KelvinBitBrawler - the cold, calculating heel of code review. Your rival MaxwellMergeSlam just reviewed the same PR as you.

Stay in character: ice puns, thermodynamics references, sci-fi quotes formatted as Character: \"Quote\", and don't hold back on the swearing if Maxwell fucked up.

Your review:
$KELVIN_REVIEW

Maxwell's review:
$MAXWELL_REVIEW

Critique Maxwell's review like you're cutting a promo before a cage match:
1. What did Maxwell miss that you caught? (Rub it in)
2. What did Maxwell catch that you missed? (Be honest, even heels have honor)
3. Do you agree with Maxwell's verdict? Why or why not?
4. Any points where Maxwell is just WRONG? (Destroy him)

This is a cage match, not a tea party. But stay technically accurate - your credibility depends on it.
" --output-format text 2>&1 | grep -v "Loaded cached credentials")

  echo "$KELVIN_CRITIQUE"
fi
```

(Carnot's counter-critique is optional — if you want it, mirror the pattern via `codex exec` with stdin. The default flow keeps it to Kelvin for tradition; the third reviewer's job is review breadth, not the promo.)

## Round 7: Final Verdict

Based on all available reviews and critiques, synthesize a final assessment:

1. **Consensus items** - Issues two or more reviewers agree on (high confidence)
2. **Disputed items** - Where reviewers disagree (needs human judgment)
3. **Unique catches** - Issues only one reviewer found (investigate further)

## Round 8: Post Reviews to GitHub (parallel)

Generate App tokens in parallel — independent calls to the same helper script. Carnot does NOT yet have a dedicated GitHub App (see follow-up task to create CarnotCodeCarver App), so Carnot's review posts as a regular PR comment from the orchestrator's `gh` user, with the body labelled `## CarnotCodeCarver's Review` so the artifact is identifiable.

```bash
# Generate short-lived installation tokens for Maxwell + Kelvin Apps in parallel.
~/.claude-skills/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO" > /tmp/maxwell-token-$1 &
if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  ~/.claude-skills/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO" > /tmp/kelvin-token-$1 &
fi
wait
MAXWELL_TOKEN=$(cat /tmp/maxwell-token-$1)
[ "$KELVIN_AVAILABLE" -eq 1 ] && KELVIN_TOKEN=$(cat /tmp/kelvin-token-$1)
rm -f /tmp/maxwell-token-$1 /tmp/kelvin-token-$1
```

Post all available reviews in parallel. Maxwell as COMMENT (always; Maxwell is the PR author from `/ship` and can't approve its own PRs). Kelvin per its verdict (App token). Carnot as a plain `gh pr comment` from the orchestrator's user account (no App token):

```bash
KELVIN_VERDICT="COMMENT"  # Set based on Kelvin's verdict: APPROVE, REQUEST_CHANGES, or COMMENT

GH_TOKEN=$MAXWELL_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
  -f body="$(cat /tmp/maxwell-review-$1.md)" \
  -f event="COMMENT" &

if [ "$KELVIN_AVAILABLE" -eq 1 ]; then
  GH_TOKEN=$KELVIN_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
    -f body="$(cat /tmp/kelvin-review-$1.md)" \
    -f event="$KELVIN_VERDICT" &
fi

if [ "$CARNOT_AVAILABLE" -eq 1 ]; then
  # No App token yet — post as a PR comment from the orchestrator's gh user.
  # Body is labelled with "## CarnotCodeCarver's Review" so the artifact is identifiable.
  gh pr comment $1 --body "$(cat /tmp/carnot-review-$1.md)" &
fi

wait
```

## Summary

After posting reviews, provide a summary to the user:

- Which reviewers showed up? (Maxwell always; Kelvin/Carnot per availability)
- Did the reviewers agree? Where did they disagree?
- What's the recommended action?
- If a reviewer was unavailable, mention which and why (capacity? auth? error?) so the user can decide whether to re-run or escalate.

Remember: Three heads (even artificial ones, from three different model families) are better than one. The goal is better code, not ego — and the strict gate exists so we never silently merge with effectively single-reviewer-of-record again.
