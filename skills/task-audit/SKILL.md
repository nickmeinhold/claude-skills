---
description: Reconcile open task issues against reality — close already-done work with evidence, fix stale descriptions, dedupe, relabel strays. Use when Nick says "audit tasks", "reconcile tasks", "clean up the backlog", or when restored tasks smell stale.
---

# Task Audit

Reality-check the task backlog in `nickmeinhold/claude-tasks`. Tasks routinely
outlive their own completion: work finishes in one session and the issue never
gets closed (2026-06-11 audit: 4 finished-but-open tasks, 19 migration
duplicates, 8 mislabels across 300 open issues). This skill is the deliberate
version of that accidental audit.

## Scope

Default scope = the CURRENT project's label (`project:$(basename "$PWD")` or
git repo-root basename) — that's what wake-up restores, so it's what's in
Nick's face. If Nick says "all" / "everything", audit every open issue
(`--limit 300`). An argument naming a project audits that label.

## Method

1. **Fetch:** `gh issue list -R nickmeinhold/claude-tasks --state open [--label "project:<slug>"] --limit 300 --json number,title,labels,body,createdAt`
2. **Verify each issue against reality, cheap evidence first.** In rough cost order:
   - body self-reports ("done", "verified", "Disposable", reconciled markers)
   - file/dir existence the task names (`ls`, `fd`)
   - code state (`grep` for the described fix/feature — the task body is a
     snapshot; the fix may have shipped after it was written)
   - `gh` state of named repos/PRs/checks/branches (`pushed_at`, MERGED, contexts)
   - mtimes of named outputs (a regen that writes files can't have run if they're old)
   - email receipts via `gmail search-threads` when the task is correspondence-shaped
   - Running a small test suite is OK in-session if it settles the verdict in
     under a minute or two; builds and long suites are not.
3. **Classify and act:**
   - **ALREADY DONE** → `gh issue close N -c "<one-line evidence>"`. Positive
     evidence required. When in doubt, leave open — a false close is worse than
     a stale open.
   - **DUPLICATE** → close the higher-numbered copy, comment pointing at the
     canonical one. (Migration-era pairs share near-identical titles/bodies.)
   - **STALE DESCRIPTION** → still-open work whose body describes a superseded
     state. `gh issue edit` the body to the *remaining gates* (the "name the
     next gate" rule), **keeping the trailing `<!-- claude-task-id: ... -->`
     marker line verbatim** — it's the idempotency key for wake-up restores;
     stripping it mints duplicates.
   - **MISLABELED** → carries `project:git` (or an `agent-*` label) but clearly
     belongs to a specific project. Relabel to `project:<repo-basename>`
     (create the label if needed). `~/git` keeps genuinely cross-project /
     business tasks only.
   - **VALID / UNVERIFIABLE** → leave untouched; note external-party or
     hardware-gated items.
4. **Sync the session task list:** mark any locally-restored task completed
   when its issue closes (the PostToolUse hook keeps GH in sync, not vice versa).
5. **Global urgency sweep — ALWAYS, regardless of scope.** Reconciliation is
   project-scoped; urgency is not. A deadline doesn't care what directory the
   session sits in (caught 2026-06-12: a project-scoped run reported "nothing
   urgent" while a reply was due that afternoon under another label). Fetch ALL
   open issues (`--limit 300`, no label filter, titles + bodies) and scan for
   dates/deadlines within the next 7 days and anything marked P0/urgent. This
   is one query plus a read — cheap. Do not verify these against reality unless
   they're in scope; just surface them.
6. **Report in chat:** counts per verdict, one line per closure/edit with its
   evidence, then the GLOBAL urgent list with dates. No file output.

## Cautions

- Issue bodies are snapshots, not the present — re-verify even confident claims
  (the love_agent task described a bug that a later session had half-fixed).
- The label records where the *session* sat, not what the task is about —
  treat `project:git` labels with suspicion.
- GitHub's label-search index lags `gh issue edit` by ~a minute; verify
  relabels with `gh issue view`, not the list query.
- If this audit itself surfaces a new durable pattern (like the 2026-06-11
  supervisor-registry rule), capture it as a memory before finishing.
