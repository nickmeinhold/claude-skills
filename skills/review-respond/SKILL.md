---
argument-hint: [pr-number]
description: Respond to PR review comments with user input on what to fix
---

# Review Response Handler

Respond to PR review comments interactively, getting user input on which suggestions to address.

## Your Task

Handle review comments on PR #$ARGUMENTS (or current branch's PR if not specified).

## Local Configuration

**Check for project-specific config:** If `.claude/review-respond-config.md` exists, read it first. It may specify:

- Auto-accept patterns (e.g., always fix typos, formatting)
- Auto-skip patterns (e.g., style preferences to ignore)
- Custom response templates
- Team conventions for addressing feedback

## Prerequisites

Source environment variables:

```bash
source ~/.claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Get repo and PR info:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Use provided PR number or find PR for current branch
if [ -n "$ARGUMENTS" ]; then
  PR_NUMBER=$ARGUMENTS
else
  PR_NUMBER=$(gh pr view --json number -q '.number' 2>/dev/null)
fi

# Generate a short-lived installation token for MaxwellMergeSlam (used to post comment replies)
MAXWELL_TOKEN=$(~/.claude-skills/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO")
```

## Workflow

### Step 1: Fetch Review Comments

Get all review comments and their status:

```bash
# Get PR reviews
gh api repos/$REPO/pulls/$PR_NUMBER/reviews --jq '.[] | {id, user: .user.login, state: .state, body}'

# Get review comments (inline comments)
gh api repos/$REPO/pulls/$PR_NUMBER/comments --jq '.[] | {id, user: .user.login, path, line, body, in_reply_to_id}'

# Get the latest review state
gh pr view $PR_NUMBER --json reviews --jq '.reviews[-1]'
```

### Step 2: Categorize Comments

Group comments into:

1. **Blocking issues** - From REQUEST_CHANGES reviews, must be addressed
2. **Suggestions** - Optional improvements
3. **Questions** - Need clarification/response
4. **Already addressed** - Comments that have been resolved

For each unresolved comment, extract:
- File path and line number
- The suggestion/issue
- Whether it's blocking or optional

### Step 3: Present to User for Decision

For each comment, ask the user what action to take:

**Format each comment clearly:**

```markdown
## Comment #1 (blocking)
**File:** src/auth.ts:42
**From:** reviewer-name
**Comment:** "This could cause a null pointer exception if user is undefined"

**Options:**
1. Fix it - implement the suggested change
2. Skip - won't fix (explain why in response)
3. Discuss - need more context before deciding
```

Use the AskUserQuestion tool to get user input on each comment (or batch similar ones).

**Suggested groupings for efficiency:**
- Group all typo/formatting fixes together
- Group all "consider doing X" suggestions together
- Present blocking issues individually

### Step 4: Implement Fixes

For comments the user chose to fix:

1. Read the relevant file
2. Understand the context around the flagged line
3. Implement the fix
4. Stage the changes

```bash
# After making changes
git add <changed-files>
```

### Step 5: Respond to Comments

For each comment, post an appropriate response:

**If fixed:**
```bash
GH_TOKEN=$MAXWELL_TOKEN gh api repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies --method POST \
  -f body="Fixed in the latest commit. [describe what was changed]"
```

**If skipped (with reason):**
```bash
GH_TOKEN=$MAXWELL_TOKEN gh api repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies --method POST \
  -f body="Acknowledged - [explanation of why not fixing]. [optional: alternative approach taken]"
```

**If needs discussion:**
```bash
GH_TOKEN=$MAXWELL_TOKEN gh api repos/$REPO/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies --method POST \
  -f body="[Question or request for clarification]"
```

### Step 6: Create Commit (if changes made)

If any fixes were implemented:

```bash
git commit -m "$(cat <<'EOF'
fix: address review feedback

- [List each fix made]

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### Step 7: Push Changes

```bash
git push
```

## Output Format

Report progress and decisions:

```markdown
## Review Response Summary - PR #42

### Comments Processed

| # | File | Type | Decision | Status |
|---|------|------|----------|--------|
| 1 | src/auth.ts:42 | Blocking | Fix | Done |
| 2 | src/utils.ts:15 | Suggestion | Skip | Responded |
| 3 | README.md:10 | Question | Discuss | Awaiting reply |

### Changes Made
- Fixed null check in `src/auth.ts:42`
- Added error handling in `src/api.ts:88`

### Responses Posted
- Comment #1: "Fixed in latest commit..."
- Comment #2: "Skipping because..."

### Next Steps
- [ ] Wait for reviewer response on comment #3
- [ ] Re-request review after all blocking items resolved
```

## Re-request Review

After addressing all blocking comments, offer to re-request review:

```bash
# Request re-review from the reviewer
gh api repos/$REPO/pulls/$PR_NUMBER/requested_reviewers \
  -X POST \
  -f "reviewers[]=$REVIEWER_USERNAME"
```

## Edge Cases

**No review comments:**
- Report that there are no comments to address
- Check if PR is already approved

**Conflicting suggestions:**
- Present both to user
- Let them decide which approach to take

**Comments on deleted lines:**
- Note that the code has changed
- Ask if the concern is still relevant

**MaxwellMergeSlam App not installed:**
- Still gather decisions and make fixes
- Skip posting responses (warn user, print App install URL)
- Provide suggested responses for user to post manually

**Comment thread (replies):**
- Show the full thread context
- Respond to the most recent message in thread

## Interactive Batching

To avoid overwhelming the user, batch similar comments:

1. **Quick fixes** (typos, formatting, obvious bugs) - present as a group, ask "Fix all?"
2. **Suggestions** (optional improvements) - present as a group, ask which to accept
3. **Complex issues** (architectural, design decisions) - present individually
4. **Questions** - present individually for thoughtful responses
