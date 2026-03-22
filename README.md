# Claude Skills

Claude Code skills for AI-assisted development.

## Team Member Setup

Four steps to get started:

```bash
# 1. Clone the repo
git clone git@github.com:nickmeinhold/claude-skills.git

# 2. Symlink skills to Claude Code (from repo root)
cd claude-skills
ln -s "$(pwd)"/*.md ~/.claude/commands/

# 3. Symlink the helper script
mkdir -p ~/.claude-skills
ln -s "$(pwd)/scripts/github-app-token.sh" ~/.claude-skills/github-app-token.sh

# 4. Create .env with App credentials (get from team lead)
cp .env.example ~/.claude-skills/.env
# Edit ~/.claude-skills/.env with actual values
```

Then install the reviewer GitHub Apps on your repos (one-time per repo):
- [Install MaxwellMergeSlam](https://github.com/apps/maxwellmergeslam/installations/new)
- [Install KelvinBitBrawler](https://github.com/apps/kelvinbitbrawler/installations/new)

That's it. Skills are now available as `/pr-review`, `/ship`, `/cage-match`, etc.

**Why symlink?** Claude Code looks for skills in `~/.claude/commands/`. Symlinking means `git pull` updates skills instantly.

## Available Skills

| Skill | Description |
|-------|-------------|
| `/ship` | Commit, push, create PR, review, and merge |
| `/pr-review <pr>` | Code review as MaxwellMergeSlam [bot] (Claude) |
| `/cage-match <pr>` | Adversarial review: Maxwell [bot] vs Kelvin [bot] (Gemini) |
| `/review-respond` | Address PR review comments |
| `/pm` | Project management (issues, boards) |
| `/research` | Deep research with web search |
| `/slides` | Generate Google Slides |

## Optional Setup

### `/pm` skill
Add `CLAUDE_PM_PAT` to your `.env` (PAT for claude-pm-enspyr account).

### `/slides` skill
Requires Google OAuth setup - see `.env.example` for details.

### Admin: Setting up new repos
If you have `ENSPYR_ADMIN_PAT`, `/ship` will automatically configure branch protection on new repos. Team members don't need this — they just need to install the reviewer Apps on their repos.

## License

MIT
