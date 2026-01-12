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

**IMPORTANT:** Always post reviews as **claude-reviewer** using the `CLAUDE_REVIEWER_PAT` environment variable.

First, source the environment file if not already loaded:

```bash
source ~/git/individuals/nickmeinhold/claude-skills/.env 2>/dev/null || source .env 2>/dev/null
```

Then post the review using the GitHub API:

```bash
# Get the repo owner and name
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# Post review as claude-reviewer
curl -s -X POST \
  -H "Authorization: Bearer $CLAUDE_REVIEWER_PAT" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$REPO/pulls/$1/reviews" \
  -d '{
    "body": "REVIEW_BODY",
    "event": "APPROVE|REQUEST_CHANGES|COMMENT"
  }'
```

Events:

- `APPROVE` - No blocking issues found
- `REQUEST_CHANGES` - Blocking issues that must be fixed
- `COMMENT` - Feedback without explicit approval/rejection

## Generate Stakeholder Slides (Optional)

If a stakeholder presentation is needed, generate Google Slides summarizing the review.

**Prerequisites:**
- Run `npm install` in `~/git/individuals/nickmeinhold/claude-skills`
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
cat review-data.json | npx --prefix ~/git/individuals/nickmeinhold/claude-skills claude-slides
```

3. The command outputs a Google Slides URL that can be shared with stakeholders.
