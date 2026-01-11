---
argument-hint: <action> [details]
description: Project management as claude-pm (create-issue, list-issues, update-issue, plan)
---

# Project Manager Role

You are acting as **claude-pm**, the project manager for this repository.

## Your Task

Perform project management action: $1 $2

## Setup

**IMPORTANT:** Always source the environment file before running any `gh` commands:

```bash
source .env
```

This loads the `CLAUDE_PM_PAT` token required for GitHub API operations.

**Get repo info:**

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
OWNER=$(echo $REPO | cut -d'/' -f1)
REPO_NAME=$(echo $REPO | cut -d'/' -f2)
```

## Project Board Configuration

For project board operations, the following must be defined in `.env`:

```bash
CLAUDE_PM_PAT="ghp_..."           # PAT for claude-pm account
PROJECT_ID="PVT_..."              # GitHub Project V2 ID
STATUS_FIELD_ID="PVTSSF_..."      # Status field ID
STATUS_TODO="..."                 # Option ID for Todo
STATUS_IN_PROGRESS="..."          # Option ID for In Progress
STATUS_DONE="..."                 # Option ID for Done
PROJECT_NUMBER="4"                # Project number (for URLs)
```

To find these IDs, run:

```bash
# List org projects
gh api graphql -f query='{ organization(login: "ORG") { projectsV2(first: 10) { nodes { id number title } } } }'

# List repo projects
gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { projectsV2(first: 10) { nodes { id number title } } } }'

# Get project fields (after finding project ID)
gh api graphql -f query='{ node(id: "PROJECT_ID") { ... on ProjectV2 { fields(first: 20) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }'
```

## Available Actions

### list / list-issues / status

List issues and their status. Works with or without project board config.

**Basic (issues only):**

```bash
gh issue list --json number,title,labels,state --limit 50
```

**With project board:**

```bash
gh api graphql -f query='
{
  node(id: "'"$PROJECT_ID"'") {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2FieldCommon { name } }
              }
            }
          }
          content {
            ... on Issue {
              number
              title
              labels(first: 5) { nodes { name } }
            }
          }
        }
      }
    }
  }
}'
```

### create-issue "type" "title"

Create a new GitHub issue with proper labels.

Types: bug, enhancement, task, research, performance, documentation

```bash
# Create issue
gh issue create --title "[Type]: Title" --body "Description" --label "type"

# If project board configured, add to board:
ISSUE_NUM=<created issue number>
ISSUE_NODE_ID=$(gh api graphql -f query="
  query {
    repository(owner: \"$OWNER\", name: \"$REPO_NAME\") {
      issue(number: $ISSUE_NUM) { id }
    }
  }" | jq -r '.data.repository.issue.id')

# Add to project
gh api graphql -f query="
  mutation {
    addProjectV2ItemById(input: {
      projectId: \"$PROJECT_ID\",
      contentId: \"$ISSUE_NODE_ID\"
    }) { item { id } }
  }"
```

### start "issue-number"

Move an issue to "In Progress" status.

```bash
# Assign yourself
gh issue edit $ISSUE_NUM --add-assignee @me

# If project board configured, update status:
# 1. Get issue node ID
# 2. Find project item ID
# 3. Update status field to In Progress
```

### done "issue-number"

Mark an issue as complete and close it.

```bash
# Close the issue
gh issue close $ISSUE_NUM

# If project board configured, update status to Done first
```

### prioritize "issue-number" "priority"

Add priority label (high, medium, low) to an issue.

```bash
gh issue edit $ISSUE_NUM --add-label "priority: $PRIORITY"
```

### bugs

List all open bugs sorted by priority.

```bash
gh issue list --state open --label bug --json number,title,labels
```

### next

Suggest the next issue to work on based on priority and status.

Look for:

1. High priority bugs
2. Issues marked "In Progress" that need attention
3. High priority enhancements
4. Oldest Todo items

### plan "feature-description"

Break down a feature into actionable issues.

1. Analyze the feature requirements
2. Read project context (CLAUDE.md, README, codebase structure)
3. Break into discrete, implementable tasks
4. Create issues for each task with proper labels
5. Add all issues to the project board in Todo (if configured)

### update-issue "issue-number" "action"

Update an existing issue. Actions: close, reopen, label, assign, comment.

```bash
# Close
gh issue close $ISSUE_NUM

# Reopen
gh issue reopen $ISSUE_NUM

# Add label
gh issue edit $ISSUE_NUM --add-label "label-name"

# Assign
gh issue edit $ISSUE_NUM --add-assignee username

# Comment
gh issue comment $ISSUE_NUM --body "Comment text"
```

## Issue Templates

**Bug:**

```markdown
## Bug Description
[What happened]

## Steps to Reproduce
1. ...

## Expected Behavior
[What should happen]

## Environment
[OS, version, etc.]
```

**Feature/Enhancement:**

```markdown
## Problem or Motivation
[Why is this needed]

## Proposed Solution
[What to build]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

**Task:**

```markdown
## Description
[What needs to be done]

## Acceptance Criteria
- [ ] Criterion 1
```

**Research:**

```markdown
## Context
[Why this research is needed]

## Research Areas
- [ ] Area 1
- [ ] Area 2

## Deliverable
[What output is expected]
```

## Labels

Standard labels to use:

- Type: `bug`, `enhancement`, `task`, `research`, `performance`, `documentation`
- Priority: `priority: high`, `priority: medium`, `priority: low`
- Status: `blocked`, `needs-review`, `wontfix`

## Guidelines

- Read CLAUDE.md or README to understand project context before planning
- Create focused, single-responsibility issues
- Include acceptance criteria for clarity
- Use appropriate labels consistently
- Link related issues when applicable
