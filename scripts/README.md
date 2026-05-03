# scripts/

Helper scripts for claude-skills slash commands.

## `github-app-token.sh`

Generates a short-lived GitHub App installation access token (1-hour TTL) by
signing an RS256 JWT and exchanging it via the GitHub API. Inputs (app id,
base64 private key, `owner/repo`) are typically sourced from
`~/.claude-skills/.env`.

Called from: `~/.claude/commands/{cage-match,ship,cage-match-eval}.md` —
whenever a skill needs to post a bot review or open a bot-authored PR as
Maxwell or Kelvin.

Example:

```bash
./github-app-token.sh "$MAXWELL_APP_ID" "$MAXWELL_PRIVATE_KEY_B64" nickmeinhold/claude-skills
```

## `eval-tally.sh`

Settles the cage-match persona A/B experiment after the 10-PR cohort closes.
Walks `~/.claude/persona-eval/claude-skills-PR-*/outcomes.json`, joins with
each sibling `mapping.json`, and writes `~/.claude/persona-eval/tally.md`
with per-set accept/defer/reject rates and unique-finding counts. Skips
incomplete PRs (any finding with a null action) and lists them at the top
of the report. Requires bash 4+ and `jq`.

claude-skills-only by design: cross-repo eval dirs (e.g. `tech_world-PR-310/`)
are observational data points and intentionally excluded from the cohort.

Called from: post-cohort, by hand. Symlinked at
`~/.claude/persona-eval/eval-tally.sh` for convenience.
