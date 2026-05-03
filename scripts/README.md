# scripts/

Helper scripts for claude-skills slash commands.

## `github-app-token.sh`

Generates a short-lived GitHub App installation access token (1-hour TTL) by
signing an RS256 JWT and exchanging it via the GitHub API. Used by `/cage-match`
and `/ship` when posting bot reviews or creating bot-authored PRs as Maxwell
or Kelvin. Inputs (app id, base64 private key, `owner/repo`) are typically
sourced from `~/.claude-skills/.env`.

## `eval-tally.sh`

Settles the cage-match persona A/B experiment after the 10-PR cohort closes.
Walks `~/.claude/persona-eval/claude-skills-PR-*/outcomes.json`, joins with
each sibling `mapping.json`, and writes `~/.claude/persona-eval/tally.md`
with per-set accept/defer/reject rates and unique-finding counts. Skips
incomplete PRs (any finding with a null action) and lists them at the top
of the report. Requires bash 4+ and `jq`.
