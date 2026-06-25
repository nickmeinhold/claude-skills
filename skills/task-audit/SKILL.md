---
description: Reconcile open task issues AND the memory graph against reality — close already-done work with evidence, fix stale descriptions, dedupe, relabel strays, and re-home lost memories. Use when Nick says "audit tasks", "reconcile tasks", "clean up the backlog", "re-home memories", or when restored tasks/memories smell stale.
---

# Task Audit

Reality-check the task backlog in `nickmeinhold/claude-tasks`. Tasks routinely
outlive their own completion: work finishes in one session and the issue never
gets closed (2026-06-11 audit: 4 finished-but-open tasks, 19 migration
duplicates, 8 mislabels across 300 open issues). This skill is the deliberate
version of that accidental audit.

Tasks and **memories** drift the same way — and a mislabeled task and a
mis-homed memory are the *same* move on two substrates (a thing physically
filed where it won't be found when it's needed). So this skill has two parts:
**Part A** reconciles the task backlog; **Part B** re-homes lost memories. Run
both by default; if Nick names one ("audit tasks" vs "re-home memories"),
do just that part.

## Scope

Default scope = the CURRENT project's label (`project:$(basename "$PWD")` or
git repo-root basename) — that's what wake-up restores, so it's what's in
Nick's face. If Nick says "all" / "everything", audit every open issue
(`--limit 300`). An argument naming a project audits that label.

## Part A — Task reconciliation

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

## Part B — Memory re-home

Reconcile the memory **graph** against reality the same way Part A reconciles
issues: a memory can outlive its home (filed where its index never loads it) or
its index can outlive the file. Three verdicts, mirroring Part A's
DONE / STALE / MISLABELED.

**Scope.** Default = the CURRENT project's memory dir, derived the same way
wake-up derives it:

```bash
MEM="$HOME/.claude/projects/$(echo "$PWD" | sed 's|[/_]|-|g')/memory"
```

If Nick says "all" / "everything", widen to every `~/.claude/projects/*/memory/`
dir. Mis-home detection is inherently cross-dir (you need to see the other dirs
to propose a home), so even the default run reads the *list* of other memory
dirs, but only mutates the in-scope one unless a confirmed move says otherwise.

**Relationship to `/graph` and `heal-memory-dir.sh`.** `/graph` *detects*
orphans/broken-edges but is read-only and single-graph; `heal-memory-dir.sh`
repairs frontmatter *within* one dir and hard-refuses cross-dir paths. Neither
*moves* a memory between project dirs — that gap is Part B's whole job. After
any move, run `~/.claude/scripts/heal-memory-dir.sh <TARGET_MEM>` on the
destination to certify the moved file's schema/provenance.

### Verdicts

1. **ORPHANED** — a `memory_*.md`/`concept_*.md`/`feedback_*.md`/`reference_*.md`
   file on disk with **no pointer line in `MEMORY.md`**. Invisible at session
   start (only `MEMORY.md` is loaded into context). Detect — iterate the memory
   prefixes (not bare `*.md`, which would mis-flag a future `MEMORY-*.md`
   sub-index), and match the pointer as a fixed string:
   ```bash
   cd "$MEM" && for f in memory_*.md concept_*.md feedback_*.md reference_*.md; do
     [ -e "$f" ] || continue   # no-match globs expand to the literal pattern
     grep -qF "($f)" MEMORY.md || echo "ORPHANED $f"
   done
   ```
   **Fix (auto — same dir, reversible via git):** read the file's frontmatter
   `description:` and append a one-line pointer under the right section of
   `MEMORY.md`: `- [Title](file.md) — <hook from description>`.

2. **DANGLING** — a `MEMORY.md` pointer to a file that **no longer exists**.
   Detect by extracting each `(file.md)` target and testing existence.
   **Before removing, disambiguate** — a missing file is either *deleted* or
   *moved*: grep every other memory dir for the same basename.
   - found elsewhere → it was re-homed; this is the **inbound half of a move**.
     Don't delete the pointer — either the file belongs back here (pull it back)
     or the pointer is stale (the file's new home is correct). Surface as a
     move-completion, confirm direction with Nick.
   - found nowhere → genuinely deleted. **Fix (auto):** remove the dead pointer
     line from `MEMORY.md`.

3. **MIS-HOMED** — a memory whose **content/usage-scope belongs to a different
   project** than the dir it sits in (or sits in a global dir like
   `-Users-nick` but is project-specific). This is the true "re-home" case and
   needs judgment, not a grep: read the file, ask *where would this load be
   useful* (the `feedback_memory_home_matches_usage_scope` test). Signals: the
   body/name centres on another repo; `[[links]]` point mostly into another
   dir's cluster; it describes a fix/feature that lives in repo X.
   **Action = REPORT + CONFIRM, then move (never auto).**

### Move procedure (migrate-then-delink, fail-safe ordering)

Cross-dir moves are higher blast-radius than anything in Part A — they touch
files two project dirs share with possibly-live peer sessions. So the order is
**add-at-target → verify → remove-from-source**, never the reverse (a
delete-first crash orphans the content). For each confirmed mis-home:

1. Resolve `TARGET_MEM` = `~/.claude/projects/<target-slug>/memory/`.
2. `cp "$MEM/$f" "$TARGET_MEM/$f"` (copy, don't move yet).
3. Add the pointer line to `$TARGET_MEM/MEMORY.md`.
4. **Verify:** the file exists at target AND its pointer is in target's index.
5. `~/.claude/scripts/heal-memory-dir.sh "$TARGET_MEM" --written "$f"` — certify
   schema at the new home.
6. **Only now** remove `$MEM/$f` and its pointer line from `$MEM/MEMORY.md`.
7. Note any **inbound `[[links]]`** from the source dir that now dangle — links
   resolve within a dir, so a move can strand back-references. Surface them; fix
   or re-point as Nick directs.

### Report

Counts per verdict; one line per auto-fix (orphan re-indexed / dangling pointer
removed) with the file; then the MIS-HOMED proposals as a confirm-list
(`<file>  <current dir> → <proposed dir>  — <one-line why>`). Move only what
Nick greenlights.

## Cautions

- Issue bodies are snapshots, not the present — re-verify even confident claims
  (the love_agent task described a bug that a later session had half-fixed).
- The label records where the *session* sat, not what the task is about —
  treat `project:git` labels with suspicion.
- GitHub's label-search index lags `gh issue edit` by ~a minute; verify
  relabels with `gh issue view`, not the list query.
- If this audit itself surfaces a new durable pattern (like the 2026-06-11
  supervisor-registry rule), capture it as a memory before finishing.
- **(Part B) A cross-dir memory move is a peer-instance exposure.** Other
  Claude sessions can hold either project's memory dir open; a move is not
  atomic across two dirs. The add-at-target-before-remove-from-source ordering
  bounds the damage (worst case is a transient duplicate, never a lost memory),
  but don't fire a batch of moves and walk away — verify each move landed
  (file + both indexes) before the next, the same way Part A verifies a relabel
  with `gh issue view`.
- **(Part B) A dangling pointer is a hypothesis, not a delete order.** Always
  run the "found elsewhere?" grep before removing — the leading way to *lose* a
  memory is to delete the index pointer to a file that was actually moved, not
  deleted.
