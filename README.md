# Claude Skills

Claude Code skills and tools for AI-assisted development.

## Skills

Markdown-based skills that extend Claude Code with custom commands:

| Skill | Command | Description |
|-------|---------|-------------|
| **Project Management** | `/pm` | Manage GitHub project boards, issues, and priorities |
| **Research** | `/research` | Deep research with web search and source synthesis |
| **Review** | `/review` | Comprehensive PR reviews with optional slide generation |
| **Slides** | `/slides` | Generate Google Slides with AI-created content |

### Installation

Skills are installed by symlinking to `~/.claude/commands/`:

```bash
ln -s ~/git/individuals/nickmeinhold/claude-skills/*.md ~/.claude/commands/
```

### Usage

Once installed, use skills as slash commands in Claude Code:

```bash
/pm list                           # Show project board status
/research "topic" --depth thorough # Research a topic
/review 123                        # Review PR #123
/slides 5 pitch deck for my app    # Generate 5-slide presentation
```

## Setup

### 1. Create `.env` file

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

### 2. Google Slides (for `/slides`)

1. Go to https://console.cloud.google.com/apis/credentials
2. Create a new OAuth 2.0 Client ID (Desktop app)
3. Add `http://localhost:3847/callback` as authorized redirect URI
4. Add credentials to `.env`
5. Run `npm install && npm run build && npm run auth` to authenticate

### 3. PR Reviews (for `/review`)

The `/review` command uses a separate GitHub account (claude-reviewer-max) to approve PRs.

1. Create a PAT at https://github.com/settings/tokens (logged in as claude-reviewer-max)
2. Required scopes: `repo`
3. Add to `.env`: `CLAUDE_REVIEWER_PAT=ghp_your_token_here`

#### Adding claude-reviewer-max to a new repo

1. Add claude-reviewer-max as collaborator with Write access in repo settings
2. Accept the invite via API:
   ```bash
   source ~/git/individuals/nickmeinhold/claude-skills/.env
   # List pending invites
   curl -s -H "Authorization: Bearer \$CLAUDE_REVIEWER_PAT" \
     "https://api.github.com/user/repository_invitations" | jq
   # Accept invite (replace INVITE_ID)
   curl -s -X PATCH -H "Authorization: Bearer \$CLAUDE_REVIEWER_PAT" \
     "https://api.github.com/user/repository_invitations/INVITE_ID"
   ```

## Claude Slides CLI

Node.js tool for generating Google Slides presentations.

### Usage

```bash
npx claude-slides --config slides.json
npx claude-slides --template review.json --data pr-data.json
```

## Project Structure

```
claude-skills/
├── pm.md              # Project management skill
├── research.md        # Research skill  
├── review.md          # PR review skill
├── slides.md          # Slides generation skill
├── .env               # Local config (not committed)
├── .env.example       # Template for .env
├── src/               # Slides CLI source
└── dist/              # Compiled output
```

## License

MIT
