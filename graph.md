---
description: Audit the memory graph and render an interactive HTML visualization
---

# Graph

Audit the memory graph (orphans, hubs, components, broken edges) and render an
interactive vis-network visualization plus a Mermaid fallback.

## Steps

### 1. Run the audit

```bash
python3 ~/.claude/scripts/memory_graph_audit.py
```

This prints a topology report and writes
`~/.claude/scripts/output/memory_graph_audit.txt`.

### 2. Render the visualization

```bash
python3 ~/.claude/scripts/memory_graph_render.py
```

This writes:
- `~/.claude/scripts/output/memory_graph.html` — interactive vis-network graph
- `~/.claude/scripts/output/memory_graph.mmd` — Mermaid version for pasting into mermaid.live

### 3. Report

Summarize the audit for Nick:
- Files missing from index, phantom subjects, broken edges
- Orphans count
- Top hubs (in-degree) and top derivatives (out-degree)
- Number and shape of connected components

Then point him at the rendered files. Offer to open the HTML:

```bash
open ~/.claude/scripts/output/memory_graph.html
```

## Notes

- Outputs land in `~/.claude/scripts/output/` (persistent), not `/tmp` (which gets wiped).
- If `$ARGUMENTS` is provided, treat it as a focus filter — e.g. a filename or
  prefix Nick wants to inspect — and highlight matching nodes in the report.
