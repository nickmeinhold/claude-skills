# CLAUDE.md

Guidance for Claude Code when working on this repository.

## Reminders

- Check out issue #26 — multiplayer audience voting game for `/live-qa` (PWA + quiz show style). A fun feature idea worth exploring when the time is right.

## Project Overview

This repo contains two main components:

1. **Claude Code Skills** - Markdown files that define custom slash commands
2. **Claude Slides CLI** - Node.js tool for generating Google Slides

## Common Commands

```bash
# Build
npm run build

# Test
npm run test              # Run tests
npm run test:coverage     # Run with coverage (thresholds in vitest.config.ts)

# CLI
npm run auth              # Google OAuth flow
npm run dev -- --config example.json

# Ship changes (uses /ship skill)
/ship [commit-message]    # commit → push → PR → review → merge
```

## Skills Development

Skills are markdown files with YAML frontmatter:

```markdown
---
argument-hint: <args>
description: What the skill does
---

# Skill Name

Instructions for Claude to follow...
```

### Key Patterns

- **Local config support**: Skills should check for `.claude/<skill>-config.md` in the project root for project-specific customization
- **Arguments**: Use `$ARGUMENTS` placeholder for user-provided arguments
- **Structured output**: Define clear output formats (JSON, markdown tables, etc.)

### Skill Locations

- **Source**: `*.md` files in this repo root
- **Symlinked to**: `~/.claude/commands/`

To install skills globally (from repo root):
```bash
ln -s "$(pwd)"/*.md ~/.claude/commands/
```

## Claude Slides CLI

### Architecture

```
src/
├── cli.ts              # Entry point, argument parsing
├── auth/
│   ├── oauth.ts        # OAuth2 flow with browser redirect
│   └── token-store.ts  # Token persistence (~/.claude-slides/tokens.json)
└── slides/
    ├── types.ts        # SlideConfig, SlideElement interfaces
    ├── config-loader.ts # Load JSON configs, interpolate variables
    ├── generator.ts    # Google Slides API calls
    └── templates.ts    # Color helpers, status emoji
```

### Key Concepts

- **EMU (English Metric Units)**: Google Slides uses EMU for positioning. Convert points: `points * 12700`
- **Slide dimensions**: Standard 16:9 is ~720 x 405 points
- **Color references**: Configs can use color names that resolve to RGB via theme.colors
- **Batch requests**: API limits ~100 requests per batch, code uses 50 for safety

### Authentication

OAuth tokens stored at `~/.claude-slides/tokens.json`.

**Setup (one-time):**
1. Add credentials to `.env`:
   ```
   GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
   GOOGLE_CLIENT_SECRET=your-client-secret
   ```
2. Run authentication:
   ```bash
   source .env
   export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET
   npx claude-slides --auth
   ```

**Note:** The CLI requires environment variables to be exported (not just in `.env`). After initial auth, tokens auto-refresh from `~/.claude-slides/`.

### Config Modes

1. **Static** (`--config`): Direct JSON with slide content
2. **Template** (`--template` + `--data`): JSON with `{{variables}}` interpolated from data file
3. **Legacy** (stdin): ReviewData JSON for PR review slides

## Testing Changes

After modifying skills:
1. Skills are loaded fresh each invocation - no restart needed
2. Test with `/skillname` in Claude Code

After modifying CLI:
```bash
npm run build
npx claude-slides --config test.json
```

## File Conventions

- Skills: `*.md` in repo root
- Source: `src/**/*.ts`
- Tests: `src/__tests__/*.test.ts`
- Build output: `dist/`
- Tokens/credentials: Not committed (in `.gitignore`)

## Environment Variables

The `.env` file (not committed) should contain:

```bash
# For /ship, /pr-review, /cage-match - GitHub App credentials for AI reviewers
MAXWELL_APP_ID=123456                    # MaxwellMergeSlam App (Claude reviewer)
MAXWELL_PRIVATE_KEY_B64=base64-pem...    # base64-encoded private key
KELVIN_APP_ID=789012                     # KelvinBitBrawler App (Gemini reviewer)
KELVIN_PRIVATE_KEY_B64=base64-pem...     # base64-encoded private key

# For /ship - admin PAT for branch protection setup (optional, admin-only)
ENSPYR_ADMIN_PAT=ghp_...

# For /pm skill - GitHub PAT for project management bot
CLAUDE_PM_PAT=ghp_...

# For /slides skill - Google OAuth credentials
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=your-client-secret
```

Skills source this file from `.env` in the repo root (or `~/.claude-skills/.env`). App tokens are generated on-the-fly via `scripts/github-app-token.sh` (short-lived, 1-hour TTL).

## Available Skills

| Skill | Description |
|-------|-------------|
| `/ship` | Commit, push, create PR, review, merge - auto-escalates to cage match for large changes |
| `/ship-major-feature` | Like /ship but with dual adversarial review (cage match) |
| `/pr-review <pr>` | Code review a PR as MaxwellMergeSlam (Claude) |
| `/cage-match <pr>` | Adversarial review: Maxwell (Claude) vs Kelvin (Gemini) |
| `/review-respond [pr]` | Respond to PR review comments with user input |
| `/pm <action>` | Project management (issues, planning) |
| `/slides` | Generate Google Slides presentations |
| `/research` | Background research agent |
| `/live-qa <question>` | Research a question and append a Q&A slide to a live presentation |

### Review Skills Details

**`/pr-review`** - Single reviewer (Maxwell/Claude) posts review via GitHub API.

**`/cage-match`** - Adversarial review workflow:
1. Maxwell (Claude) reviews the PR
2. Kelvin (Gemini CLI) reviews independently
3. Both critique each other's reviews
4. Both post their reviews to GitHub under their own accounts
5. Summary of agreements/disagreements provided

**Reviewers:**
- **MaxwellMergeSlam [bot]** - Claude instance (GitHub App, uses `MAXWELL_APP_ID` + `MAXWELL_PRIVATE_KEY_B64`)
- **KelvinBitBrawler [bot]** - Gemini instance (GitHub App, uses `KELVIN_APP_ID` + `KELVIN_PRIVATE_KEY_B64`)

**Setup:** Add App credentials to `.env`, install both GitHub Apps on your repos, and symlink the helper script. Requires Gemini CLI installed (`brew install gemini` or similar).

## Development Workflow

This repo uses `/ship` for all changes:

1. **Branch protection** on `main`:
   - 1 approving review required (2 when using `/ship-major-feature`)
   - `dismiss_stale_reviews` enforced (ensures new commits invalidate old approvals)
   - CI must pass (tests + coverage thresholds)

2. **First run in a new repo**: `/ship` auto-configures:
   - Verifies MaxwellMergeSlam and KelvinBitBrawler Apps are installed
   - Sets up branch protection
   - Creates `.claude/ship-initialized` marker

3. **CI** (`.github/workflows/ci.yml`):
   - Runs on push and PR to main
   - Build → Test with coverage
   - Fails if coverage below thresholds (see `vitest.config.ts`)

## Testing

Coverage thresholds are defined in `vitest.config.ts` and enforced by both CI and `/ship`.

```bash
npm run test              # Quick test run
npm run test:coverage     # With coverage report
```
