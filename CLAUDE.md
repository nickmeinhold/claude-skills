# CLAUDE.md

Guidance for Claude Code when working on this repository.

## Reminders

- Check out issue #26 — multiplayer audience voting game for `/live-qa` (PWA + quiz show style). A fun feature idea worth exploring when the time is right.

## Project Overview

This repo contains **Claude Code Skills** — each skill is a `skills/<name>/SKILL.md` file defining a custom slash command.

The Google Slides build that powers `/slides` and `/live-qa` lives in the sibling repo
[`nickmeinhold/claude-slides`](https://github.com/nickmeinhold/claude-slides). See that
repo's `CLAUDE.md` for CLI architecture, OAuth setup, EMU/layout details, and build/test
commands. Skills in this repo invoke it via `npx --prefix "$CLAUDE_SLIDES_PATH" claude-slides ...`.

## Common Commands

```bash
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

- **Source**: `skills/<name>/SKILL.md` in this repo
- **Symlinked to**: `~/.claude/skills/`

To install skills globally (from repo root):
```bash
ln -s "$(pwd)/skills" ~/.claude/skills
```

## Testing Changes

After modifying skills:
1. Skills are loaded fresh each invocation — no restart needed
2. Test with `/skillname` in Claude Code

## File Conventions

- Skills: `skills/<name>/SKILL.md`
- Tokens/credentials: Not committed (in `.gitignore`)

## Environment Variables

The `.env` file (not committed) should contain:

```bash
# For /ship, /pr-review, /cage-match - GitHub App credentials for AI reviewers
MAXWELL_APP_ID=123456                    # MaxwellMergeSlam App (Claude reviewer)
MAXWELL_PRIVATE_KEY_B64=base64-pem...    # base64-encoded private key
KELVIN_APP_ID=789012                     # KelvinBitBrawler App (Gemini reviewer)
KELVIN_PRIVATE_KEY_B64=base64-pem...     # base64-encoded private key
CARNOT_APP_ID=345678                     # CarnotCodeCarver App (Codex/GPT reviewer)
CARNOT_PRIVATE_KEY_B64=base64-pem...     # base64-encoded private key
TESLA_APP_ID=901234                      # TeslaArcProphet App (Grok reviewer) — optional; falls back to gh pr comment
TESLA_PRIVATE_KEY_B64=base64-pem...      # base64-encoded private key
WU_APP_ID=567890                         # WuParityBreaker App (Kimi K3 reviewer) — optional; falls back to gh pr comment
WU_PRIVATE_KEY_B64=base64-pem...         # base64-encoded private key

# For /ship - admin PAT for branch protection setup (optional, admin-only)
ENSPYR_ADMIN_PAT=ghp_...

# For /pm skill - GitHub PAT for project management bot
CLAUDE_PM_PAT=ghp_...

# For /slides + /live-qa - path to the sibling claude-slides repo
CLAUDE_SLIDES_PATH=/path/to/claude-slides
```

Skills source this file from `.env` in the repo root (or `~/.claude-skills/.env`). App tokens are generated on-the-fly via `scripts/github-app-token.sh` (short-lived, 1-hour TTL).

Google OAuth credentials for `/slides` (`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`) live in the `claude-slides` repo's `.env`. See that repo's `CLAUDE.md`.

## Available Skills

| Skill | Description |
|-------|-------------|
| `/ship` | Commit, push, create PR, review, merge - auto-escalates to cage match for large changes |
| `/ship-major-feature` | Like /ship but with dual adversarial review (cage match) |
| `/pr-review <pr>` | Code review a PR as MaxwellMergeSlam (Claude) |
| `/cage-match <pr>` | Adversarial review: Maxwell (Claude) vs Kelvin (Gemini) vs Carnot (GPT) vs Tesla (Grok) vs Wu (Kimi K3) |
| `/review-respond [pr]` | Respond to PR review comments with user input |
| `/pm <action>` | Project management (issues, planning) |
| `/slides` | Generate Google Slides presentations (delegates to sibling `claude-slides` build) |
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
- **CarnotCodeCarver [bot]** - Codex/GPT instance (GitHub App, uses `CARNOT_APP_ID` + `CARNOT_PRIVATE_KEY_B64`)
- **TeslaArcProphet [bot]** - Grok instance via `grok` CLI (App optional — `TESLA_APP_ID` + `TESLA_PRIVATE_KEY_B64`; posts a plain comment without it)
- **WuParityBreaker [bot]** - Kimi K3 instance via `kimi` CLI (App optional — `WU_APP_ID` + `WU_PRIVATE_KEY_B64`; posts a plain comment without it). Requires `kimi login` (OAuth) once; unauthenticated Wu degrades to "unavailable" at the gate.

Avatar art for all five lives in `assets/avatars/` (`<name>.svg` source → 512px `<name>.png` via `rsvg-convert -w 512 -h 512 <name>.svg -o <name>.png`) — upload the PNG as each GitHub App's display picture.

**Setup:** Add App credentials to `.env`, install the reviewer GitHub Apps on your repos (Maxwell/Kelvin/Carnot required for /ship; Tesla/Wu optional — they degrade to plain comments), and symlink the helper script. CLI prerequisites per seat: `gemini` (Kelvin), `codex` (Carnot), `grok` (Tesla), `kimi` via `uv tool install kimi-cli` + `kimi login` OAuth (Wu).

## Development Workflow

This repo uses `/ship` for all changes:

1. **Branch protection** on `main`:
   - 1 approving review required (2 when using `/ship-major-feature`)
   - `dismiss_stale_reviews` enforced (ensures new commits invalidate old approvals)
2. **First run in a new repo**: `/ship` auto-configures:
   - Verifies MaxwellMergeSlam and KelvinBitBrawler Apps are installed
   - Sets up branch protection
   - Creates `.claude/ship-initialized` marker
