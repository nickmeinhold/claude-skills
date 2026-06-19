# Claude Skills

Claude Code skills for AI-assisted development.

## Team Setup

Four steps to get started:

```bash
# 1. Clone the repo
git clone git@github.com:nickmeinhold/claude-skills.git

# 2. Symlink skills to Claude Code (from repo root)
cd claude-skills
ln -s "$(pwd)/skills" ~/.claude/skills
# (or, if you already have your own ~/.claude/skills dir:
#  ln -s "$(pwd)"/skills/* ~/.claude/skills/)

# 3. Install the helper-script symlinks into ~/.claude/scripts
#    (github-app-token.sh + the /consolidate scripts). Idempotent — re-run
#    after any pull that adds or moves a script. REQUIRED on every fresh clone.
bash scripts/install-symlinks.sh

# 4. Add the App credentials to your main Claude env, ~/.claude/.env
#    (get the values from the team lead). Append to an existing env, or seed
#    a new one from the template:
cat .env.example >> ~/.claude/.env
# then edit ~/.claude/.env and fill in the real values
```

> **Where things live:** secrets go in `~/.claude/.env` (your single env file) and
> the helper scripts are symlinked into `~/.claude/scripts/` by
> `install-symlinks.sh`. (Pre-2026-06-19 this repo used a separate
> `~/.claude-skills/` dir for both — that's been retired.)

Then install the reviewer GitHub Apps on your repos (one-time per repo):
- [Install MaxwellMergeSlam](https://github.com/apps/maxwellmergeslam/installations/new)
- [Install KelvinBitBrawler](https://github.com/apps/kelvinbitbrawler/installations/new)

That's it. Skills are now available as `/pr-review`, `/ship`, `/cage-match`, etc.

**Why symlink?** Claude Code looks for skills in `~/.claude/skills/` (each skill is a `<name>/SKILL.md` directory). Symlinking means `git pull` updates skills instantly.

## Setup (Your Own Projects)

Want to use `/ship`, `/pr-review`, or `/cage-match` on your own repos? You'll need to register your own GitHub Apps to act as reviewers.

### Step 1: Clone & symlink skills

```bash
git clone git@github.com:nickmeinhold/claude-skills.git
cd claude-skills
ln -s "$(pwd)/skills" ~/.claude/skills
bash scripts/install-symlinks.sh   # symlinks github-app-token.sh into ~/.claude/scripts
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

### Step 4: Add credentials to `~/.claude/.env`

Credentials live in your main Claude env file. Append to an existing
`~/.claude/.env`, or seed a new one from the template:

```bash
cat .env.example >> ~/.claude/.env
```

Fill in the 4 required values:

```bash
MAXWELL_APP_ID=<your Claude reviewer App ID>
MAXWELL_PRIVATE_KEY_B64=<base64-encoded private key>
KELVIN_APP_ID=<your Gemini reviewer App ID>
KELVIN_PRIVATE_KEY_B64=<base64-encoded private key>
```

### Step 5: Helper script (already done)

`bash scripts/install-symlinks.sh` from Step 1 already symlinked
`github-app-token.sh` into `~/.claude/scripts/`. The skills call it there to
generate short-lived installation tokens from your App credentials at runtime —
no separate step needed.

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
| `/cage-match <pr>` | Three-way adversarial review: Maxwell [bot] (Claude) vs Kelvin [bot] (Gemini) vs Carnot (Codex/GPT) |
| `/review-respond` | Address PR review comments |
| `/pm` | Project management (issues, boards) |
| `/research` | Deep research with web search |
| `/slides` | Generate Google Slides |

## Optional Setup

### `/pm` skill
Add `CLAUDE_PM_PAT` to your `.env` (PAT for claude-pm-enspyr account).

### `/slides` skill
Requires Google OAuth setup - see `.env.example` for details.

### Admin
If you have `ENSPYR_ADMIN_PAT`, `/ship` will automatically configure branch protection. Only needed by repo admins — team members and external users don't need this.

## License

MIT
