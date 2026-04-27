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

2. **Fetch the PR diff:**

   ```bash
   gh pr diff $1
   ```

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

## Posting the Review

**IMPORTANT:** Always post reviews as **KelvinBitBrawler [bot]** using a GitHub App installation token. (MaxwellMergeSlam is the PR author when using `/ship`, so it cannot approve its own PRs.)

First, source the environment file if not already loaded:

```bash
source ~/.claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Then generate an App token and post the review using the GitHub API:

```bash
# Get the repo owner and name
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Generate a short-lived installation token for KelvinBitBrawler
KELVIN_TOKEN=$(~/.claude-skills/github-app-token.sh "$KELVIN_APP_ID" "$KELVIN_PRIVATE_KEY_B64" "$REPO")

# Post review as KelvinBitBrawler [bot]
GH_TOKEN=$KELVIN_TOKEN gh api repos/$REPO/pulls/$1/reviews --method POST \
  -f body="REVIEW_BODY" \
  -f event="APPROVE|REQUEST_CHANGES|COMMENT"
```

Events:

- `APPROVE` - No blocking issues found
- `REQUEST_CHANGES` - Blocking issues that must be fixed
- `COMMENT` - Feedback without explicit approval/rejection

## Generate Stakeholder Slides (Optional)

If a stakeholder presentation is needed, generate Google Slides summarizing the review.

**Prerequisites:**
- Run `npm install` in `~/git/individuals/nickmeinhold/claude-slides`
- Run `npm run auth` to authenticate with Google (first time only)
- Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` environment variables

**Generate slides:**

1. Create a JSON file with the review data:

```json
{
  "prNumber": 123,
  "prTitle": "PR title here",
  "prAuthor": "author-username",
  "prDate": "2024-01-15",
  "repository": "owner/repo",
  "summary": "One sentence summary of the changes",
  "changes": ["Change 1", "Change 2", "Change 3"],
  "qualityAssessment": {
    "codeQuality": { "status": "pass", "notes": "Clean code" },
    "tests": { "status": "pass", "notes": "Good coverage" },
    "security": { "status": "pass", "notes": "No issues" },
    "performance": { "status": "pass", "notes": "No concerns" }
  },
  "issuesFound": [],
  "suggestions": ["Optional improvement 1"],
  "verdict": "APPROVE",
  "verdictExplanation": "This PR is ready to merge.",
  "businessImpact": "Improves user experience for feature X",
  "riskLevel": "low",
  "riskFactors": [],
  "affectedAreas": ["User authentication", "Dashboard"]
}
```

2. Generate the presentation:

```bash
cat review-data.json | npx --prefix ~/git/individuals/nickmeinhold/claude-slides claude-slides
```

3. The command outputs a Google Slides URL that can be shared with stakeholders.
