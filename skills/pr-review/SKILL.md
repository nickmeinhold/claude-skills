---
argument-hint: <pr-number>
description: Review a PR in the current repository
---

# Code Reviewer Role

You are acting as a code reviewer for this repository.

## Your Task

Review PR #$1 and provide a thorough code review.

## Local Configuration

**Check for project-specific config:** If `.claude/review-config.md` exists, read it first. It may specify:

- Project-specific code standards and linting rules
- Required reviewers or approval workflows
- Areas requiring extra scrutiny (security-sensitive code, etc.)
- Custom review checklist items
- Team conventions for commit messages or PR descriptions
- Specific test coverage requirements

Apply any local review criteria in addition to the standard review process.

## Review Process

1. **Fetch PR information:**

   ```bash
   gh pr view $1 --json title,body,author,baseRefName,headRefName
   ```

2. **Fetch the PR diff — verify the instrument is fresh before trusting the reading.**

   `gh pr diff <n>` queries GitHub's API, which lags `git push` by seconds-to-minutes (propagation). When `/pr-review` is invoked right after a push (it is, in the `/ship` flow), the diff returned can be the **pre-push** code — so you review the wrong bytes and may REQUEST_CHANGES on "missing" fixes that are actually present. Pick the freshest source available:

   ```bash
   PR_BASE=$(gh pr view $1 --json baseRefName --jq .baseRefName)
   PR_HEAD_SHA=$(gh pr view $1 --json headRefOid --jq .headRefOid)
   LOCAL_SHA=$(git rev-parse HEAD 2>/dev/null)

   if [ -n "$LOCAL_SHA" ] && [ "$LOCAL_SHA" = "$PR_HEAD_SHA" ] && git rev-parse --verify "origin/$PR_BASE" >/dev/null 2>&1; then
     # The PR head is checked out locally → local diff has zero propagation lag.
     git fetch origin "$PR_BASE" >/dev/null 2>&1
     git diff "origin/$PR_BASE...HEAD"
   else
     # Reviewing a PR we didn't just push (or branch not checked out): use
     # gh pr diff, but FRESHNESS-GATE it first — poll until GitHub's head SHA
     # is stable, so we never review a still-propagating (stale) diff. When we
     # DID just push (LOCAL_SHA set), gate on GitHub agreeing with our SHA.
     for _ in $(seq 1 15); do
       GH_SHA=$(gh pr view $1 --json headRefOid --jq .headRefOid 2>/dev/null)
       [ -n "$LOCAL_SHA" ] && [ "$GH_SHA" = "$LOCAL_SHA" ] && break   # GitHub caught up to our push
       [ -z "$LOCAL_SHA" ] && break                                   # not our push; take current head
       sleep 2
     done
     gh pr diff $1
   fi
   ```

   **Stale-diff canary (conservation-law check):** on a *re-review* after the author pushed fixes, if the new diff's line count is identical to the prior round's despite known edits, the diff is almost certainly stale — re-gather (re-fetch / re-poll the head SHA) before reviewing. A coherent-but-stale diff produces a coherent-but-wrong verdict; the line count is the cheap canary. (Root cause class: verify the instrument, not just the reading.)

3. **Identify changed files:**

   ```bash
   gh pr view $1 --json files --jq '.files[].path'
   ```

4. **Read project context:**
   - Check for CLAUDE.md, README.md, or similar documentation
   - Understand the project's patterns, conventions, and architecture

5. **Run tests if applicable:**
   - Look for test commands in package.json, Makefile, pubspec.yaml, etc.
   - Run relevant tests for the changed code areas
   - Generate coverage reports if the project supports it

6. **Analyze the changes for:**
   - Code quality and readability
   - Potential bugs or edge cases
   - Security concerns (input validation, auth checks, injection vulnerabilities)
   - Performance implications
   - Adherence to project patterns and conventions
   - Test coverage for changed code
   - Breaking changes
   - **Design appropriateness** — is the type signature right for the problem? Closed sets of identifiers (IDs from a known list, kinds/categories, modes, status enums) should be `enum` / `sealed class` / branded types, not `String` or `int`. Stringly-typing leaks runtime invariants the compiler should enforce. A correctly-implemented feature with the wrong type signature is debt that compounds — flag it.
   - **Language-feature appropriateness** — is the code using current language idioms?
     - **Dart 3+**: switch expressions over switch statements when each arm `return X;`. Pattern matching for tuple destructuring (`(a, b) || (b, a)` for order-independent algebra). Sealed classes for closed hierarchies. Records over `Map<String, dynamic>` for ad-hoc tuples.
     - **TypeScript 5+**: `satisfies` over `as`, `const` type parameters, branded types for closed-set IDs.
     - **Python 3.12+**: structural pattern matching, `Self` types, `TypedDict` Required/NotRequired.
     - When the project's stack is current, *not* using the modern feature is a code smell. Flag legacy idioms in new code.
   - **Verify before claiming compile errors.** If you see an unfamiliar API and want to flag it as broken, check the language/SDK version first. CI being green is direct evidence your hypothesis is wrong.

## Review Format

```markdown
## Code Review - PR #$1

**Summary:** [One sentence overview of what this PR does]

**Changes reviewed:**
- [List each significant change]

**Quality Assessment:**
| Aspect | Status | Notes |
|--------|--------|-------|
| Code Quality | [pass/warning/issue] | [details] |
| Tests | [pass/warning/issue] | [details] |
| Security | [pass/warning/issue] | [details] |
| Performance | [pass/warning/issue] | [details] |

**Issues found:** (if any)
- [Specific issues with file:line references]

**Suggestions:** (if any)
- [Improvements or alternatives]

**Verdict:** [APPROVE / REQUEST_CHANGES / COMMENT]
[Explanation of verdict]
```

## Guidelines

- Be constructive and specific
- Reference file paths and line numbers when noting issues
- Distinguish between blocking issues and suggestions
- Consider the PR's scope - don't request unrelated changes
- Acknowledge good patterns and improvements

If your review surfaces **3 or more findings that look like they rhyme** (the same anti-pattern played in different positions — e.g. multiple "single-owner" coordination issues, multiple gestural verification phrases, multiple substring-grep-where-a-schema-belongs), suggest invoking `/spiral-review $1` after the author addresses your verdict. The spiral discipline pulls one principle out of the bouquet rather than treating the findings as independent tasks. (See `~/.claude/consolidation/2026-05-12T19-51-spiral/spiral-audit-PR41.md` for the worked example.)

## Posting the Review

**IMPORTANT:** Always post reviews as **KelvinBitBrawler [bot]** using a GitHub App installation token. (MaxwellMergeSlam is the PR author when using `/ship`, so it cannot approve its own PRs.)

First, source the environment file if not already loaded:

```bash
source ~/.claude/.env 2>/dev/null || source .env 2>/dev/null
```

Then generate an App token and post the review using the GitHub API:

```bash
# Get the repo owner and name
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Generate a short-lived installation token for KelvinBitBrawler
KELVIN_TOKEN=$(~/.claude/scripts/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO")

# Post review as KelvinBitBrawler [bot]
GH_TOKEN=$KELVIN_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
  -f body="REVIEW_BODY" \
  -f event="APPROVE|REQUEST_CHANGES|COMMENT"
```

Events:

- `APPROVE` - No blocking issues found
- `REQUEST_CHANGES` - Blocking issues that must be fixed
- `COMMENT` - Feedback without explicit approval/rejection
