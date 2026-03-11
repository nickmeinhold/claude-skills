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
- **CI configuration** (see below)
- **Test configuration** (see below)

### CI Configuration

Control CI setup via `.claude/ship-config.md`:

```markdown
## CI Settings

ci: none
```

**Options:**
- `ci: none` - Don't create CI workflow, no CI requirement in branch protection
- `ci: node` - Node.js template with npm test/coverage (default if `package.json` exists)
- `ci: flutter` - Flutter template with flutter test (default if `pubspec.yaml` exists)
- `ci: skip` - Don't touch CI at all (keep existing or none)
- `ci: custom` - Use custom template defined in config (see below)

**Custom CI template:**
```markdown
## CI Settings

ci: custom

### Custom CI Workflow
\`\`\`yaml
name: CI
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make test
\`\`\`
```

**Defaults (no config file):**
- If `pubspec.yaml` exists → `ci: flutter`
- If `package.json` exists → `ci: node`
- If neither → `ci: none`
- If `.github/workflows/` already has files → don't overwrite

### Test Configuration

Control pre-commit test runs via `.claude/ship-config.md`:

```markdown
## Test Settings

test-command: npm run test:coverage
```

**Options:**
- `test-command: <command>` - Run this exact command before committing. If it exits non-zero, stop and fix.
- `test-command: none` - Skip local tests entirely.

If not specified, auto-detect:
- Has `package.json` with a `test:coverage` script → `npm run test:coverage`
- Has `package.json` with a `test` script (no coverage) → `npm run test`
- Has `pubspec.yaml` → `flutter test`
- Neither → skip

Coverage thresholds are owned by the project's test runner config (e.g., `vitest.config.ts`, `jest.config.js`), not by `/ship`.

## Prerequisites

Source environment variables:

```bash
source ~/.enspyr-claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Get repo info and generate bot token for PR creation:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
BASE_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Generate Maxwell App token — PRs are created as MaxwellMergeSlam [bot]
# so the human developer can approve them
MAXWELL_TOKEN=$(~/.enspyr-claude-skills/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO")
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

**If not initialized**, set up branch protection and verify App installations:

1. **Check current branch protection:**
   ```bash
   gh api repos/$REPO/branches/$BASE_BRANCH/protection 2>/dev/null
   ```

2. **Verify reviewer Apps are installed** on this repo:

   ```bash
   # Check that MaxwellMergeSlam and KelvinBitBrawler GitHub Apps are installed
   MAXWELL_TOKEN=$(~/.enspyr-claude-skills/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO" 2>/dev/null) && echo "MaxwellMergeSlam App: installed" || echo "MaxwellMergeSlam App: NOT installed"
   KELVIN_TOKEN=$(~/.enspyr-claude-skills/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO" 2>/dev/null) && echo "KelvinBitBrawler App: installed" || echo "KelvinBitBrawler App: NOT installed"
   ```

   If either App is not installed, print the install URL and stop:
   ```bash
   if [ -z "$MAXWELL_TOKEN" ] || [ -z "$KELVIN_TOKEN" ]; then
     echo "Reviewer GitHub Apps must be installed on this repo."
     [ -z "$MAXWELL_TOKEN" ] && echo "  Install MaxwellMergeSlam: https://github.com/apps/maxwellmergeslam/installations/new"
     [ -z "$KELVIN_TOKEN" ] && echo "  Install KelvinBitBrawler: https://github.com/apps/kelvinbitbrawler/installations/new"
     echo "After installing, re-run /ship."
     exit 1
   fi
   ```

3. **Create CI workflow** (based on config):

   Check `.claude/ship-config.md` for CI settings. If not specified, auto-detect:
   - Has `pubspec.yaml` → Flutter
   - Has `package.json` → Node.js
   - Neither → skip CI
   - `.github/workflows/` exists → don't overwrite

   **All CI templates should include:**
   - Trigger on push/PR to main
   - Docs-skip: detect if only .md/.txt/LICENSE changed, skip build/test if so
   - Run appropriate build, lint, and test commands for the stack
   - Job name: `test` (for branch protection)

   | Stack | Key steps |
   |-------|-----------|
   | Node.js | `npm ci`, `npm run build`, `npm run test:coverage` |
   | Flutter | `flutter pub get`, `flutter analyze`, `flutter test --coverage` |

   Commit the CI file as part of setup.

4. **Configure coverage threshold:**

   If CI was created (not `ci: none` or `ci: skip`), ask the user what coverage threshold they want:

   > "What minimum coverage threshold should be enforced? (e.g., 50, 80, or 'none' to skip)"

   If the user provides a number, configure the project's test runner:

   **Vitest** (`vitest.config.ts` or `vitest.config.js`):
   - If the file exists, add or update the `test.coverage.thresholds` section
   - If no vitest config exists but `package.json` has vitest as a dependency, create `vitest.config.ts`:
     ```typescript
     import { defineConfig } from 'vitest/config';

     export default defineConfig({
       test: {
         coverage: {
           provider: 'v8',
           thresholds: {
             lines: <threshold>,
             functions: <threshold>,
             branches: <threshold>,
             statements: <threshold>,
           },
         },
       },
     });
     ```

   **Jest** (`jest.config.js` or `jest.config.ts` or `package.json` jest section):
   - Add `coverageThreshold.global` with `branches`, `functions`, `lines`, `statements` set to the threshold

   **Flutter** (`pubspec.yaml` project):
   - Coverage thresholds aren't built into `flutter test`. Note this to the user — they can use a package like `very_good_cli` or add a coverage check script to CI.

   If the user says "none", skip. Store the chosen threshold in `.claude/ship-config.md`:
   ```markdown
   ## Test Settings

   coverage-threshold: 50
   ```

5. **Enable auto-merge** on the repository:
   ```bash
   gh api repos/$REPO -X PATCH -f allow_auto_merge=true
   ```
   This allows PRs to be queued for merge while CI is still running, avoiding the need
   for `--admin` overrides.

6. **Set up branch protection** (if missing):

   If CI was created, require it to pass:
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

   If no CI (ci: none), skip the status checks requirement:
   ```bash
   gh api repos/$REPO/branches/$BASE_BRANCH/protection -X PUT \
     -H "Accept: application/vnd.github+json" \
     -f "required_pull_request_reviews[required_approving_review_count]=1" \
     -f "required_pull_request_reviews[dismiss_stale_reviews]=true" \
     -f "enforce_admins=false" \
     -f "required_status_checks=null" \
     -f "restrictions=null"
   ```

7. **Create initialization marker:**
   ```bash
   mkdir -p .claude
   echo "initialized=$(date -Iseconds)" > .claude/ship-initialized
   echo "reviewer=claude-reviewer-max" >> .claude/ship-initialized
   echo "ci=node|none|custom|skip" >> .claude/ship-initialized
   git add .claude/ship-initialized
   # If CI was created, also add it:
   git add .github/workflows/ci.yml 2>/dev/null || true
   ```

**Report setup status:**
- [x] Verified reviewer Apps installed (MaxwellMergeSlam + KelvinBitBrawler)
- [x] CI: created/skipped/existing (based on config)
- [x] Enabled branch protection (1 required review, +CI if applicable)
- [x] Created .claude/ship-initialized marker

### Step 1: Analyze Changes

Check what needs to be committed:

```bash
git status
git diff --stat
git diff --cached --stat
```

If there are no changes (staged or unstaged), report that there's nothing to ship and stop.

### Step 2: Run Tests

Before committing, run the local test suite to catch failures early (avoids a CI round-trip).

1. Check `.claude/ship-config.md` for `test-command` setting
2. If not configured, auto-detect:
   - Has `package.json` with `test:coverage` script → `npm run test:coverage`
   - Has `package.json` with `test` script only → `npm run test`
   - Has `pubspec.yaml` → `flutter test`
   - `test-command: none` or nothing detected → skip
3. Run the command. **If it exits non-zero, stop and fix before proceeding.** Do NOT commit broken code.

### Step 3: Create Commit

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

### Step 4: Push to Remote

Ensure the branch is pushed:

```bash
# Check if branch has upstream
if ! git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null; then
  git push -u origin $CURRENT_BRANCH
else
  git push
fi
```

### Step 5: Create Pull Request

Check if a PR already exists for this branch:

```bash
EXISTING_PR=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")
```

If no PR exists, create one **as the bot** so the human developer can approve:

```bash
GH_TOKEN=$MAXWELL_TOKEN gh pr create --title "PR title based on changes" --body "$(cat <<'EOF'
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

### Step 5.5: File Overlap Warning

Check if any other open PRs touch the same files as this one. This catches potential merge conflicts early — when they're cheapest to resolve.

```bash
# Get files changed in this PR
OUR_FILES=$(gh pr view $PR_NUMBER --json files --jq '[.files[].path] | sort | .[]')

# Check all other open PRs for overlapping files
gh pr list --state open --json number,title,headRefName,files \
  --jq ".[] | select(.number != $PR_NUMBER)" | while IFS= read -r pr; do
  OTHER_NUM=$(echo "$pr" | jq -r '.number')
  OTHER_TITLE=$(echo "$pr" | jq -r '.title')
  OTHER_FILES=$(echo "$pr" | jq -r '[.files[].path] | sort | .[]')
  OVERLAP=$(comm -12 <(echo "$OUR_FILES") <(echo "$OTHER_FILES"))
  if [ -n "$OVERLAP" ]; then
    echo "⚠️  File overlap with PR #$OTHER_NUM ($OTHER_TITLE):"
    echo "$OVERLAP" | sed 's/^/   /'
  fi
done
```

If overlaps are found, warn the user:
- **If the other PR is approved/ready to merge:** suggest merging it first to avoid conflicts.
- **If both PRs make the same change to overlapping files:** note that the conflict will be trivial.
- **If the changes diverge:** suggest extracting the shared change into its own micro-PR.

This is advisory only — do not block shipping.

### Step 6: Review the PR

Wait briefly for CI to start, then determine the review approach based on change size:

```bash
CHANGED_FILES=$(gh pr view $PR_NUMBER --json files --jq '.files | length')
CHANGED_LINES=$(gh pr view $PR_NUMBER --json additions,deletions --jq '.additions + .deletions')
```

**If large change (10+ files or 500+ lines changed):** before reviewing, run the "Pre-Step: Ensure Dual Review Setup" from `ship-major-feature.md` to bump required reviews to 2 and verify both reviewer Apps are installed. Then run `/cage-match $PR_NUMBER`. After merging, run the "Post-Merge: Restore Branch Protection" step from `ship-major-feature.md` to restore required reviews back to 1.

**Otherwise:** run `/pr-review $PR_NUMBER`

Both will post review(s) to GitHub and return a verdict (APPROVE, REQUEST_CHANGES, or COMMENT). For cage match, both reviewers must APPROVE.

### Step 7: Handle Review Feedback

**STOP. Always present review feedback to the user before taking action.**

**If the review verdict is REQUEST_CHANGES:**

1. Show each review comment/change request to the user
2. Ask the user: "Should I address these changes? Which ones do you want to fix?"
3. Wait for the user's response before proceeding
4. If the user agrees, run `/review-respond $PR_NUMBER` to address the agreed-upon comments
5. Commit and push the fixes
6. Re-request review and loop back to Step 6

Repeat until the review verdict is APPROVE.

**If the review verdict is APPROVE but there are suggestions:**

1. Show the suggestions to the user and ask if they want to address them before merging
2. If yes, run `/review-respond $PR_NUMBER`, commit, push, and re-request review
3. If no, continue to Step 9

### Step 8: Pre-Merge Gate (MANDATORY)

**STOP. Do NOT skip this step. Review suggestions are often valuable.**

Before merging, you MUST check:
- If verdict is **REQUEST_CHANGES** → go back to Step 7, do NOT merge
- If verdict is **APPROVE with suggestions** → list each suggestion to the user and ask "Do you want to address any of these before merging?" Wait for their answer. Do NOT auto-merge.
- If verdict is **APPROVE with no suggestions** → proceed to merge

### Step 9: Merge

**Only merge after the pre-merge gate is satisfied.**

If approved:

1. Check CI status:
   ```bash
   gh pr checks $PR_NUMBER
   ```

2. Check for stacked PRs:
   ```bash
   PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName -q '.headRefName')
   DOWNSTREAM_PRS=$(gh pr list --base "$PR_BRANCH" --json number -q '.[].number' 2>/dev/null)
   ```

3. Attempt the merge **using the admin PAT** to bypass branch protection (bot approvals
   don't count toward required reviews). If CI is still running, use `--auto` to queue.
   **Only reach this point after the pre-merge gate (Step 8) is fully satisfied** — the
   user has reviewed all suggestions and given the go-ahead.
   ```bash
   if [ -n "$DOWNSTREAM_PRS" ]; then
     # Stacked PRs exist — merge WITHOUT deleting branch, retarget downstream, then delete
     if ! GH_TOKEN=$ENSPYR_ADMIN_PAT gh pr merge $PR_NUMBER --squash --admin 2>/dev/null; then
       echo "CI pending — queuing auto-merge..."
       GH_TOKEN=$ENSPYR_ADMIN_PAT gh pr merge $PR_NUMBER --squash --admin --auto
     fi
     for downstream in $DOWNSTREAM_PRS; do
       gh pr edit $downstream --base $BASE_BRANCH
     done
     git push origin --delete "$PR_BRANCH" 2>/dev/null || true
   else
     # No stacked PRs — safe to delete branch on merge
     if ! GH_TOKEN=$ENSPYR_ADMIN_PAT gh pr merge $PR_NUMBER --squash --delete-branch --admin 2>/dev/null; then
       echo "CI pending — queuing auto-merge..."
       GH_TOKEN=$ENSPYR_ADMIN_PAT gh pr merge $PR_NUMBER --squash --delete-branch --admin --auto
     fi
   fi
   ```
   The `--auto` flag is only used as a fallback when the immediate merge fails due to
   pending CI. By this point the user has already reviewed all feedback (Step 8), so
   the only remaining gate is CI completing.

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

**Multiple PRs (stacked):**
- When shipping multiple related PRs that are stacked (each PR's base is the previous PR's branch), merge them in order
- Before deleting a merged branch, check if any open PRs use it as their base
- If so: merge without `--delete-branch`, retarget downstream PRs to the base branch (e.g., `main`), then delete the branch
- This prevents downstream PRs from being auto-closed by GitHub when their base branch disappears

**Multiple open PRs with file overlap:**
- When shipping multiple PRs that touch the same files, merge them sequentially (not in parallel) to avoid repeated merge conflicts
- Prefer merging the smaller/simpler PR first — this minimizes the conflict surface for the larger PR
- If both PRs make the same change (e.g., a shared bug fix), consider extracting that change into its own micro-PR, merging it first, then rebasing both feature branches

**Reviewer App not installed:**
- Skip the formal review posting
- Still analyze the code and report findings
- Proceed to merge if self-review looks good (with warning)
- Print the App install URL so the user can fix it for next time

**Cannot set up branch protection (not repo admin):**
- Skip the setup step
- Warn that reviews won't be enforced
- Still post advisory reviews and proceed

**Reviewer Apps not installed and no admin access:**
- Run `github-app-token.sh` to check — if it fails, the App isn't installed
- Print the GitHub App install URLs for the user
- Reviews can still be posted once Apps are installed (one-time setup per repo)

**Repo already has branch protection:**
- Don't modify existing rules, except: verify `dismiss_stale_reviews` is enabled
- If not enabled, update it:
  ```bash
  DISMISS_STALE=$(gh api repos/$REPO/branches/$BASE_BRANCH/protection/required_pull_request_reviews 2>/dev/null | jq '.dismiss_stale_reviews')
  ```
  If `DISMISS_STALE` is not `true`, use the targeted PATCH endpoint to update just the review settings without touching other protection rules:
  ```bash
  GH_TOKEN=$ENSPYR_ADMIN_PAT gh api repos/$REPO/branches/$BASE_BRANCH/protection/required_pull_request_reviews --method PATCH -F dismiss_stale_reviews=true
  ```
- Verify Apps installed
- Mark as initialized

## Interactive Mode

If `$ARGUMENTS` is empty or unclear, ask the user:

1. What should the commit message be?
2. Should we auto-merge if review passes, or stop for manual approval?
