# Claude Skills

Claude Code skills for AI-assisted development.

## Team Setup (enspyrco)

Four steps to get started:

```bash
# 1. Clone the repo
git clone git@github.com:enspyrco/claude-skills.git

# 2. Symlink skills to Claude Code (from repo root)
cd claude-skills
ln -s "$(pwd)"/*.md ~/.claude/commands/

# 3. Symlink the helper script
mkdir -p ~/.enspyr-claude-skills
ln -s "$(pwd)/scripts/github-app-token.sh" ~/.enspyr-claude-skills/github-app-token.sh

# 4. Create .env with App credentials (get from team lead)
cp .env.example ~/.enspyr-claude-skills/.env
# Edit ~/.enspyr-claude-skills/.env with actual values
```

Then install the reviewer GitHub Apps on your repos (one-time per repo):
- [Install MaxwellMergeSlam](https://github.com/apps/maxwellmergeslam/installations/new)
- [Install KelvinBitBrawler](https://github.com/apps/kelvinbitbrawler/installations/new)

That's it. Skills are now available as `/pr-review`, `/ship`, `/cage-match`, etc.

**Why symlink?** Claude Code looks for skills in `~/.claude/commands/`. Symlinking means `git pull` updates skills instantly.

## Setup (Your Own Projects)

Want to use `/ship`, `/pr-review`, or `/cage-match` on your own repos? You'll need to register your own GitHub Apps to act as reviewers.

### Step 1: Clone & symlink skills

```bash
git clone git@github.com:enspyrco/claude-skills.git
cd claude-skills
ln -s "$(pwd)"/*.md ~/.claude/commands/
```

### Step 2: Register two GitHub Apps

Go to [GitHub Settings > Developer Settings > GitHub Apps](https://github.com/settings/apps) and create two Apps:

| App | Purpose | Example name |
|-----|---------|--------------|
| Claude reviewer | `/pr-review`, `/ship`, `/cage-match` | `my-claude-reviewer` |
| Gemini reviewer | `/cage-match` (optional) | `my-gemini-reviewer` |

For each App:
- **Permissions:** `Pull requests: Read & Write`
- **Webhooks:** Disable (uncheck "Active")
- **OAuth / Device flow:** Disable
- **Install target:** Any account

After creating each App, note the **App ID** from the App's settings page.

### Step 3: Generate & encode private keys

On each App's settings page, click **Generate a private key**. Then base64-encode it:

```bash
base64 -i your-app.pem
```

Copy the output — you'll need it for `.env`. Delete the `.pem` files after encoding.

### Step 4: Create `.env`

```bash
mkdir -p ~/.enspyr-claude-skills
cp .env.example ~/.enspyr-claude-skills/.env
```

Fill in the 4 required values:

```bash
MAXWELL_APP_ID=<your Claude reviewer App ID>
MAXWELL_PRIVATE_KEY_B64=<base64-encoded private key>
KELVIN_APP_ID=<your Gemini reviewer App ID>
KELVIN_PRIVATE_KEY_B64=<base64-encoded private key>
```

### Step 5: Symlink helper script

```bash
ln -s "$(pwd)/scripts/github-app-token.sh" ~/.enspyr-claude-skills/github-app-token.sh
```

This script generates short-lived installation tokens from your App credentials at runtime.

### Step 6: Install Apps on your repos

For each App, visit:

```
https://github.com/apps/<your-app-slug>/installations/new
```

Select the repos you want the reviewer to have access to.

### Step 7 (optional): Install Gemini CLI

Required for `/cage-match` (the Gemini/Kelvin reviewer). See [Gemini CLI docs](https://github.com/google-gemini/gemini-cli) for installation.

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

### Admin (enspyrco)
If you have `ENSPYR_ADMIN_PAT`, `/ship` will automatically configure branch protection on enspyrco repos. Only needed by org admins — team members and external users don't need this.

## License

MIT
