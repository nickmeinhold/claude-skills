---
description: Audit the memory graph and render an interactive HTML visualization
---

# Graph

Audit the memory graph (orphans, hubs, components, broken edges) and render an
interactive vis-network visualization plus a Mermaid fallback.

## Steps

### 1. Run the audit

```bash
python3 ~/.claude/scripts/memory_graph_audit.py "$ARGUMENTS"
```

This prints a topology report and writes
`~/.claude/scripts/output/memory_graph_audit.txt`. If `$ARGUMENTS` is non-empty
(e.g. `/graph snes`), the report ends with a `FOCUSED ON: <arg>` section listing
files whose names contain the substring (case-insensitive) along with their
parents and children.

### 2. Render the visualization

```bash
python3 ~/.claude/scripts/memory_graph_render.py "$ARGUMENTS"
```

This writes:
- `~/.claude/scripts/output/memory_graph.html` — interactive vis-network graph.
  When `$ARGUMENTS` is provided, matching nodes get a red border and bumped size
  so they pop visually; the page header shows the focus term and match count.
- `~/.claude/scripts/output/memory_graph.mmd` — Mermaid version for pasting into mermaid.live

### 3. Report

Summarize the audit for Nick:
- Files missing from index, phantom subjects, broken edges
- Orphans count
- Top hubs (in-degree) and top derivatives (out-degree)
- Number of components and the size of the largest
- If `$ARGUMENTS` was provided, also surface the matched files and their immediate neighborhoods from the `FOCUSED ON` section

Then point him at the rendered files. Offer to open the HTML:

```bash
open ~/.claude/scripts/output/memory_graph.html
```

## Notes

- Outputs land in `~/.claude/scripts/output/` (persistent), not `/tmp` (which gets wiped).
- The `$ARGUMENTS` focus filter is matched as a case-insensitive substring against
  filenames. Use it to zoom in on a project (`/graph snes`), a memory type
  (`/graph concept_`), or any prefix you care about. With no argument, the full
  graph is reported and rendered as before.
- If you change either script's output format, update Step 3 above so the recipe
  doesn't drift from the reality of what the scripts produce.

## Contract with the audit/render scripts

The two scripts at `~/.claude/scripts/memory_graph_audit.py` and
`memory_graph_render.py` are intentionally personal infrastructure and are
**not** synced through this repo — they reference local memory paths that
shouldn't leave the machine.

This skill assumes both scripts accept an optional positional `$ARGUMENTS`
for focus filtering. On a machine where the scripts predate the `$ARGUMENTS`
wiring (or are missing the focus feature entirely), the focus argument is
silently ignored and the skill still produces a full-graph audit and render.
That's expected graceful degradation, not a bug — the full-graph path is the
floor.

If the divergence ever bites (e.g. focus filtering becomes load-bearing on a
machine without it), the deferred option is to generalize the scripts and
bring them into this repo. For now the ceremony isn't worth it — the
scripts reference local memory paths that shouldn't leave the machine.
