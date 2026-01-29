---
argument-hint: [commit-message]
description: Ship changes: commit, push, create PR, review, and merge
---

# Ship Changes

Automate the full PR workflow: commit, push, create PR, review, and merge.

## Your Task

Ship the current changes with optional commit message: $ARGUMENTS

## Local Configuration

**Check for project-specific config:** If `.claude/ship-config.md` exists, read it first. It may specify:

- Default base branch (if not `main`)
- Required reviewers before merge
- Branch naming conventions
- Auto-merge rules (e.g., only for certain file types)
- Custom PR title/body templates
- Skip review for certain changes (e.g., docs-only)

## Prerequisites

Source environment variables:

```bash
source ~/git/individuals/nickmeinhold/claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Get repo info:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
BASE_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

## Workflow

### Step 0: Repository Setup (once per repo)

Check if this repo has been initialized for `/ship`:

```bash
# Check for initialization marker
if [ -f ".claude/ship-initialized" ]; then
  echo "Repo already initialized"
else
  echo "First run - checking repo setup..."
fi
```

**If not initialized**, set up branch protection and collaborators:

1. **Check current branch protection:**
   ```bash
   gh api repos/$REPO/branches/$BASE_BRANCH/protection 2>/dev/null
   ```

2. **Add claude-reviewer-max as collaborator** (if not already):
   ```bash
   # Check if already a collaborator
   gh api repos/$REPO/collaborators/claude-reviewer-max 2>/dev/null || \
     gh api repos/$REPO/collaborators/claude-reviewer-max -X PUT -f permission=push
   ```

3. **Create CI workflow** (if missing):

   If `.github/workflows/ci.yml` doesn't exist, create it with test coverage and docs-skip:

   ```yaml
   name: CI

   on:
     push:
       branches: [main]
     pull_request:
       branches: [main]

   jobs:
     test:
       runs-on: ubuntu-latest

       steps:
         - uses: actions/checkout@v4
           with:
             fetch-depth: 0

         - name: Check for code changes
           id: changes
           run: |
             if [ "${{ github.event_name }}" = "pull_request" ]; then
               BASE=${{ github.event.pull_request.base.sha }}
               HEAD=${{ github.event.pull_request.head.sha }}
             else
               BASE=${{ github.event.before }}
               HEAD=${{ github.sha }}
             fi
             CODE_CHANGES=$(git diff --name-only $BASE $HEAD | grep -vE '\.(md|txt)$|^LICENSE' || true)
             if [ -z "$CODE_CHANGES" ]; then
               echo "docs_only=true" >> $GITHUB_OUTPUT
             else
               echo "docs_only=false" >> $GITHUB_OUTPUT
             fi

         - name: Setup Node.js
           if: steps.changes.outputs.docs_only != 'true'
           uses: actions/setup-node@v4
           with:
             node-version: '20'
             cache: 'npm'

         - name: Install dependencies
           if: steps.changes.outputs.docs_only != 'true'
           run: npm ci

         - name: Build
           if: steps.changes.outputs.docs_only != 'true'
           run: npm run build

         - name: Run tests with coverage
           if: steps.changes.outputs.docs_only != 'true'
           run: npm run test:coverage

         - name: Skip tests (docs only)
           if: steps.changes.outputs.docs_only == 'true'
           run: echo "Skipping tests - documentation only changes"
   ```

   Commit this file as part of the setup.

4. **Set up branch protection** (if missing):
   ```bash
   gh api repos/$REPO/branches/$BASE_BRANCH/protection -X PUT \
     -H "Accept: application/vnd.github+json" \
     -f "required_pull_request_reviews[required_approving_review_count]=1" \
     -f "required_pull_request_reviews[dismiss_stale_reviews]=true" \
     -f "enforce_admins=false" \
     -f "required_status_checks[strict]=true" \
     -f "required_status_checks[contexts][]=test" \
     -f "restrictions=null"
   ```

6. **Create initialization marker:**
   ```bash
   mkdir -p .claude
   echo "initialized=$(date -Iseconds)" > .claude/ship-initialized
   echo "reviewer=claude-reviewer-max" >> .claude/ship-initialized
   echo "ci=true" >> .claude/ship-initialized
   git add .claude/ship-initialized .github/workflows/ci.yml
   # Will be included in the next commit
   ```

**Report setup status:**
- [x] Added claude-reviewer-max as collaborator
- [x] Created CI workflow with docs-skip
- [x] Enabled branch protection (1 required review + CI)
- [x] Created .claude/ship-initialized marker

### Step 1: Analyze Changes

Check what needs to be committed:

```bash
git status
git diff --stat
git diff --cached --stat
```

If there are no changes (staged or unstaged), report that there's nothing to ship and stop.

### Step 2: Create Commit

If there are uncommitted changes:

1. Stage all relevant changes (be selective - avoid secrets, large binaries)
2. Create a commit message:
   - Use the provided argument if given: `$ARGUMENTS`
   - Otherwise, analyze the diff and generate a descriptive commit message
   - Follow conventional commits format: `type(scope): description`

```bash
git add -A  # or specific files
git commit -m "$(cat <<'EOF'
commit message here

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

### Step 3: Push to Remote

Ensure the branch is pushed:

```bash
# Check if branch has upstream
if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null; then
  git push -u origin $CURRENT_BRANCH
else
  git push
fi
```

### Step 4: Create Pull Request

Check if a PR already exists for this branch:

```bash
EXISTING_PR=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
```

If no PR exists, create one:

```bash
gh pr create --title "PR title based on changes" --body "$(cat <<'EOF'
## Summary
- Brief description of changes

## Test plan
- [ ] Tests pass
- [ ] Manual verification

Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Get the PR number:

```bash
PR_NUMBER=$(gh pr view --json number -q '.number')
```

### Step 5: Review the PR

Wait briefly for CI to start, then perform code review:

1. Fetch the PR diff:
   ```bash
   gh pr diff $PR_NUMBER
   ```

2. Analyze changes for:
   - Code quality and readability
   - Potential bugs or edge cases
   - Security concerns
   - Test coverage
   - Adherence to project conventions

3. Generate review verdict: APPROVE, REQUEST_CHANGES, or COMMENT

4. Post the review as **claude-reviewer**:

```bash
curl -s -X POST \
  -H "Authorization: Bearer $CLAUDE_REVIEWER_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/pulls/$PR_NUMBER/reviews" \
  -d '{
    "body": "REVIEW_BODY_HERE",
    "event": "APPROVE|REQUEST_CHANGES|COMMENT"
  }'
```

### Step 6: Merge (if approved)

**Only merge if the review verdict is APPROVE.**

If there are blocking issues (REQUEST_CHANGES), report them and stop. The user can fix and re-run `/ship` after addressing feedback.

If approved:

1. Check CI status:
   ```bash
   gh pr checks $PR_NUMBER
   ```

2. If CI passes (or no required checks), merge:
   ```bash
   gh pr merge $PR_NUMBER --squash --delete-branch
   ```

3. Report success with the merged PR URL.

## Output Format

Report progress at each step:

```markdown
## Shipping Changes

### Commit
- [x] Staged 3 files
- [x] Committed: "feat: add user authentication"

### Push
- [x] Pushed to origin/feature-branch

### Pull Request
- [x] Created PR #42: "feat: add user authentication"
- URL: https://github.com/owner/repo/pull/42

### Review
- [x] Code review: APPROVE
- Summary: Clean implementation, tests pass

### Merge
- [x] Merged PR #42 (squash)
- [x] Deleted branch: feature-branch

**Done! Changes shipped successfully.**
```

## Safety Checks

Before proceeding at each step, verify:

1. **Before commit:** No secrets or credentials in diff
2. **Before push:** Confirm we're not on main/master (create feature branch if needed)
3. **Before merge:** CI checks pass, review is APPROVE
4. **Abort conditions:**
   - If on protected branch without changes, stop
   - If review finds blocking issues, stop and report
   - If CI fails, stop and report

## Edge Cases

**Already on main with uncommitted changes:**
- Create a new feature branch first
- Name it based on the changes (e.g., `feat/add-auth`)

**PR already exists:**
- Push new commits to existing PR
- Re-review if there are new changes
- Proceed to merge if approved

**No CLAUDE_REVIEWER_PAT:**
- Skip the formal review posting
- Still analyze the code and report findings
- Proceed to merge if self-review looks good (with warning)

**Cannot set up branch protection (not repo admin):**
- Skip the setup step
- Warn that reviews won't be enforced
- Still post advisory reviews and proceed

**Repo already has branch protection:**
- Don't modify existing rules
- Just add collaborator if missing
- Mark as initialized

## Interactive Mode

If `$ARGUMENTS` is empty or unclear, ask the user:

1. What should the commit message be?
2. Should we auto-merge if review passes, or stop for manual approval?
