---
argument-hint: <path-to-markdown-file> [--draft] [--tags "ai,memory"]
description: Publish a markdown blog post to Dev.to and Medium (cross-post everywhere)
---

# Publish Blog Post

Cross-post a markdown file to multiple platforms. Canonical version on GitHub, syndicated to Dev.to (API) and Medium (browser automation).

**File to publish:** $ARGUMENTS

## Workflow

### Step 1: Parse the markdown file

Read the file. Extract:
- **Title**: First `# heading` in the file
- **Subtitle**: First line of italic text (`*...*`) after the title, if any
- **Tags**: From `--tags` argument, or infer 3-5 from content
- **Draft mode**: If `--draft` flag is present, publish as draft on all platforms

If the file has YAML frontmatter (`---` delimited), use `title`, `tags`, `canonical_url`, `description` fields from there.

### Step 2: Commit and push to GitHub (canonical)

- Ensure the file is committed and pushed to its repo
- The canonical URL is the GitHub rendered markdown URL (e.g., `https://github.com/org/repo/blob/main/path/to/post.md`)
- Tell the user the canonical URL

### Step 3: Publish to Dev.to

Use the Dev.to API. The API key should be in the environment variable `DEVTO_API_KEY`.

If not set, tell the user:
> Get your API key from https://dev.to/settings/extensions — scroll to "DEV Community API Keys", generate one, then:
> `export DEVTO_API_KEY=your_key`

API call (use curl via Bash tool):

```
POST https://dev.to/api/articles
Header: api-key: $DEVTO_API_KEY
Header: Content-Type: application/json
Body: {
  "article": {
    "title": "<title>",
    "body_markdown": "<full markdown content>",
    "published": <true unless --draft>,
    "tags": [<tags array, max 4>],
    "canonical_url": "<github URL from step 2>"
  }
}
```

Report the Dev.to URL back to the user.

### Step 4: Import to Medium via Playwright

Use the Playwright MCP tools to automate Medium's "Import a story" feature:

1. `browser_navigate` to `https://medium.com/p/import`
2. `browser_snapshot` to check the page state
3. If not logged in, tell the user to log in manually and wait
4. Find the URL input field and `browser_fill_form` with the canonical URL from Step 2
5. Click the import button
6. Wait for import to complete
7. `browser_snapshot` to confirm the draft was created
8. Report the Medium draft URL back to the user

**Important:** Medium imports create DRAFTS — the user still needs to review and publish manually on Medium. This is a feature, not a bug: Medium formatting sometimes needs tweaks.

### Step 5: Summary

Print a summary:

```
Published: <title>

Canonical:  <github URL>
Dev.to:     <dev.to URL> [draft/published]
Medium:     <medium draft URL> [draft — review before publishing]
```

## Error Handling

- If Dev.to API fails, continue with Medium (don't abort the whole flow)
- If Medium import fails (not logged in, page changed), report it and suggest manual import
- If the file hasn't been committed/pushed yet, offer to do it

## Notes

- Dev.to tags are limited to 4, lowercase, no spaces (use hyphens)
- Dev.to `body_markdown` supports their liquid tags but standard markdown works fine
- Medium import works best from a clean HTML page — GitHub rendered markdown is fine
- The `canonical_url` on Dev.to tells search engines the GitHub version is the original
