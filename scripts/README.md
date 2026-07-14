# scripts/

Helper scripts for claude-skills slash commands.

## `github-app-token.sh`

Generates a short-lived GitHub App installation access token (1-hour TTL) by
signing an RS256 JWT and exchanging it via the GitHub API. Inputs (app id,
base64 private key, `owner/repo`) are typically sourced from `~/.claude/.env`.

Installed at `~/.claude/scripts/github-app-token.sh` (a symlink back to this
repo, created by `install-symlinks.sh`); skills invoke it by that stable path.

Called from: `~/.claude/skills/{cage-match,ship,ship-major-feature,pr-review,review-respond}/SKILL.md`
— whenever a skill needs to post a bot review or open a bot-authored PR as
Maxwell, Kelvin, or Carnot.

Example:

```bash
./github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" nickmeinhold/claude-skills
```
