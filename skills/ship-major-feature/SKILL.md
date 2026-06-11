---
argument-hint: [commit-message]
description: Ship major features with adversarial dual review (cage match)
---

# Ship Major Feature

Follow the `/ship` workflow (see ship.md) with the following overrides:

## Pre-Step: Ensure Dual Review Setup

**Always run this before Step 0**, regardless of whether `.claude/ship-initialized` exists.

1. **Verify both reviewer Apps are installed:**

```bash
source ~/.claude-skills/.env 2>/dev/null || source .env 2>/dev/null
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
BASE_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name')

# Check that both GitHub Apps are installed on this repo
MAXWELL_TOKEN=$(~/.claude-skills/github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" "$REPO" 2>/dev/null) && echo "MaxwellMergeSlam App: installed" || echo "MaxwellMergeSlam App: NOT installed"
KELVIN_TOKEN=$(~/.claude-skills/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO" 2>/dev/null) && echo "KelvinBitBrawler App: installed" || echo "KelvinBitBrawler App: NOT installed"
```

If either App is not installed, print the install URL and stop:
```bash
if [ -z "$MAXWELL_TOKEN" ] || [ -z "$KELVIN_TOKEN" ]; then
  echo "Both reviewer GitHub Apps must be installed for cage match."
  [ -z "$MAXWELL_TOKEN" ] && echo "  Install MaxwellMergeSlam: https://github.com/apps/maxwellmergeslam/installations/new"
  [ -z "$KELVIN_TOKEN" ] && echo "  Install KelvinBitBrawler: https://github.com/apps/kelvinbitbrawler/installations/new"
  exit 1
fi
```

2. **Bump required reviews to 2 for the cage match:**

```bash
PR_REVIEW_CONFIG=$(gh api repos/$REPO/branches/$BASE_BRANCH/protection/required_pull_request_reviews 2>/dev/null)
CURRENT_REVIEW_COUNT=$(echo "$PR_REVIEW_CONFIG" | jq '.required_approving_review_count')
```

If `CURRENT_REVIEW_COUNT` is not `2`, use the targeted PATCH endpoint (not the full PUT, which can fail on scoped tokens and risks clobbering other protection settings):

```bash
GH_TOKEN=$ENSPYR_ADMIN_PAT gh api repos/$REPO/branches/$BASE_BRANCH/protection/required_pull_request_reviews --method PATCH \
  -F required_approving_review_count=2 -F dismiss_stale_reviews=true
```

3. **Update initialization marker:**

```bash
mkdir -p .claude
grep -q "reviewer=maxwell+kelvin" .claude/ship-initialized 2>/dev/null || echo "reviewer=maxwell+kelvin" >> .claude/ship-initialized
```

Then continue with the `/ship` workflow (Step 0 will be skipped if already initialized, which is fine — we've handled what it would miss).

## Override: Review Step (Step 5)

Instead of `/pr-review`, run the cage match:

```
/cage-match $PR_NUMBER
```

This sends the PR through both Maxwell (Claude) and Kelvin (Gemini) for independent reviews, cross-critiques, and dual GitHub review postings.

## Override: Merge Requirement (Step 7)

**Both reviewers must APPROVE** before merging. If either reviewer returns REQUEST_CHANGES, follow the Step 6 feedback handling flow and then re-run `/cage-match` (not just `/pr-review`).

## Post-Merge: Restore Branch Protection

After merging, restore required reviews back to 1 so normal `/ship` PRs aren't blocked:

```bash
GH_TOKEN=$ENSPYR_ADMIN_PAT gh api repos/$REPO/branches/$BASE_BRANCH/protection/required_pull_request_reviews --method PATCH \
  -F required_approving_review_count=1 -F dismiss_stale_reviews=true
```

**Important:** Always use the targeted `PATCH .../required_pull_request_reviews` endpoint, not the full `PUT .../protection`. The full PUT requires broader token scopes and risks clobbering other protection settings (status checks, restrictions, etc.).
