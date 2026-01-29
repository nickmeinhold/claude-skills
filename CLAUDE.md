# CLAUDE.md

Guidance for Claude Code when working on this repository.

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
npm run test:coverage     # Run with coverage (must be ≥50%)

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

- **Source**: `~/git/individuals/nickmeinhold/claude-skills/*.md`
- **Symlinked to**: `~/.claude/commands/`

To install skills globally:
```bash
ln -s ~/git/individuals/nickmeinhold/claude-skills/*.md ~/.claude/commands/
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

## Available Skills

| Skill | Description |
|-------|-------------|
| `/ship` | Commit, push, create PR, review, merge - full workflow |
| `/review <pr>` | Code review a PR as claude-reviewer-max |
| `/pm <action>` | Project management (issues, planning) |
| `/slides` | Generate Google Slides presentations |
| `/research` | Background research agent |

## Development Workflow

This repo uses `/ship` for all changes:

1. **Branch protection** on `main`:
   - 1 approving review required (from `claude-reviewer-max`)
   - CI must pass (tests + 50% coverage)

2. **First run in a new repo**: `/ship` auto-configures:
   - Adds `claude-reviewer-max` as collaborator
   - Sets up branch protection
   - Creates `.claude/ship-initialized` marker

3. **CI** (`.github/workflows/ci.yml`):
   - Runs on push and PR to main
   - Build → Test with coverage
   - Fails if coverage < 50%

## Testing

Coverage threshold: **50% minimum** (enforced by CI)

```bash
npm run test              # Quick test run
npm run test:coverage     # With coverage report
```

Current coverage: ~96% on core modules (`templates.ts`, `config-loader.ts`)
