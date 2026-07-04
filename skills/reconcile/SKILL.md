---
description: Reconcile every substrate where an artifact drifts from the home it'll be looked for in — open task issues, the memory graph, CLAUDE.md + READMEs, and un-backed work — against reality. Close already-done work with evidence, fix stale descriptions, dedupe, relabel strays, re-home lost memories, patch stale/orphaned docs, and flag important artifacts with no git home. Use when Nick says "audit tasks", "reconcile tasks", "clean up the backlog", "re-home memories", "does anything need rehoming", or when restored tasks/memories/docs smell stale.
---

# Reconcile

Reconcile artifacts against reality — starting with the task backlog in
`nickmeinhold/claude-tasks`. Tasks routinely outlive their own completion: work
finishes in one session and the issue never gets closed (2026-06-11 audit: 4
finished-but-open tasks, 19 migration duplicates, 8 mislabels across 300 open
issues). This skill is the deliberate version of that accidental audit.

**Reconciliation spans substrates — "task" was just substrate #1** (this skill was
born as `task-audit`, renamed once its scope outgrew the name). A mislabeled task,
a mis-homed memory, a CLAUDE.md that points at
a moved file, and a design doc that lives only on local disk are the **same move
on different substrates**: a thing physically filed where it won't be found (or
survive) when it's needed. The verdict vocabulary transfers — ORPHANED (real
thing, no index pointer), DANGLING (pointer, no thing), MIS-HOMED (right thing,
wrong home) recur on every substrate. So this skill has parts, one per substrate:

- **Part A** — task backlog (`nickmeinhold/claude-tasks`)
- **Part B** — the memory graph (per-project `MEMORY.md` + memory files)
- **Part C** — CLAUDE.md + READMEs (instruction/doc drift)
- **Part D** — durability sweep (important artifacts with no git home)
- plus a **light consolidation-keying** check (session summaries mis-keyed to the
  wrong project)

Run all by default; if Nick names one ("audit tasks" vs "re-home memories" vs
"check the docs"), do just that part.

But the substrates **re-home asymmetrically**, and that asymmetry is load-bearing
for Part B: a *task* has ONE owner, so relabel = delivery and the fix is always a
move. A *memory* is KNOWLEDGE that can be needed in **several** sessions' recall
at once, and recall is **per-dir** — so a memory's "right home" may be *plural*,
and the move that fixes a task *blinds the source* when applied to a shared
memory. Hence Part B has a verdict Part A doesn't: **SHARED** (mirror or
pointer-deliver), distinct from **MIS-HOMED** (move). CLAUDE.md (Part C) inherits
the same asymmetry for a global-vs-project rule.

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
   - **MISLABELED** → two cases, both "filed where the owning session won't
     restore it":
     - **Bare/stray label** → carries `project:git` (or an `agent-*` label) but
       clearly belongs to a specific project. Relabel to
       `project:<repo-basename>` (create the label if needed). `~/git` keeps
       genuinely cross-project / business tasks only.
     - **Cross-project mislabel** → carries a *legit-looking* project label that
       its own **title/body scope contradicts**. The label records where the
       *session sat*, not what the task is *about* — so a server-build task
       (title literally `Gateway:…`, a row-lock / migration / backend-policy
       body) sitting under `project:aiko_chat_app`, or an app-only task
       (entitlement plist, Flutter widget, store metadata) sitting under the
       gateway label, is mis-routed and will **strand in the wrong session's
       restore** (the "label is delivery" rule). Verdict is *content vs label*,
       not *bare label* — a real project label is not a free pass. Relabel to
       the project the content names; comment the move + why. (Caught
       2026-07-01: #1432 "Gateway: row-lock…" + #1441 moderation-backend both
       sat under `project:aiko_chat_app` and the bare-label rule walked past
       them.)
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
its index can outlive the file. Four verdicts: ORPHANED / DANGLING / MIS-HOMED
mirror Part A's DONE / STALE / MISLABELED; **SHARED** is the one with no Part A
twin (a memory needed in several recalls at once — the task/memory asymmetry).

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
   # The Bash tool runs zsh, where an unmatched glob ERRORS (bash expands to the
   # literal); enable null_glob so no-match just yields an empty loop, either shell.
   cd "$MEM"; setopt null_glob 2>/dev/null || shopt -s nullglob 2>/dev/null
   # Check ALL index files, not just MEMORY.md — some dirs shard the index
   # (this community graph splits into MEMORY.community.md + MEMORY.roster.md);
   # grepping only MEMORY.md false-flags every person_*.md as orphaned.
   INDEXES=$(ls MEMORY*.md 2>/dev/null)
   for f in memory_*.md concept_*.md feedback_*.md reference_*.md person_*.md bridge_*.md; do
     grep -qF "$f" $INDEXES || echo "ORPHANED $f"
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

3. **MIS-HOMED** — a memory useful in **exactly one** place, and it's the wrong
   one: content/usage-scope belongs to a *different single* project than the dir
   it sits in (or sits in a global dir like `-Users-nick` but is
   project-specific). The true "re-home" case; judgment, not a grep: read the
   file, ask *where would this load be useful* (the
   `feedback_memory_home_matches_usage_scope` test). Signals: the body/name
   centres on another repo; `[[links]]` point mostly into another dir's cluster;
   it describes a fix/feature that lives in repo X.
   **Action = REPORT + CONFIRM, then move (never auto).**

   **First disqualify SHARED.** Before calling a memory MIS-HOMED, ask whether
   it's useful in **more than one** session's recall. A move *blinds the source*
   — and tasks and memory **re-home asymmetrically**: a task has ONE owner, so a
   label flip *is* delivery; a memory is KNOWLEDGE that can be needed in several
   sessions at once, so "move it" is wrong when the source still needs it.

4. **SHARED** — a memory legitimately useful in **two or more** sessions' recall
   (e.g. a vision/architecture/design memory the app-tab *steers* and the
   gateway-tab *builds* — `project_federation_north_star`,
   `project_identity_personhood_vs_reputation`, `project_moderation_architecture`).
   Recall is **per-dir**, so a memory in dir A never surfaces at session-start in
   dir B no matter how relevant. MIS-HOMED's *move* is the wrong fix (it blinds
   A). Two correct deliveries, by who owns the target:
   - **Co-driven targets (dirs you drive yourself, e.g. the `~/git` hub + a
     sibling repo)** → **MIRROR**: keep the canonical copy AND duplicate to each
     dir that needs recall, each with its own `MEMORY.md` pointer. Re-run
     `heal-memory-dir.sh` on every copy. Note in each that siblings exist so a
     later edit updates all.
   - **Peer-owned targets (a project with its OWN live Claude session, e.g. the
     gateway)** → **POINTER-DELIVER, don't reach in**: do NOT `cp` into the peer
     session's memory dir (that's the memory twin of editing a peer-owned repo —
     let the owning session govern what enters its recall). Instead file a
     **target-labeled task** (`project:<peer-slug>`) telling that session to pull
     /mirror the memory itself, naming the canonical path. (2026-07-01: app-tab
     filed gateway task #1572 to mirror the identity/sybil + federation vision
     memories rather than writing the gateway's recall dir from the app side.)
   **Action = REPORT + CONFIRM**, then mirror (co-driven) or file the pull-task
   (peer-owned). Never a blinding move.

### Move procedure (migrate-then-delink, fail-safe ordering)

**Gate first — this procedure is for MIS-HOMED only (a single wrong home), and
only when YOU drive the target dir.** If the verdict was SHARED, don't move —
mirror or file a pull-task (above). If the target is a **peer-owned** session's
dir, do NOT write it from here; file a `project:<peer-slug>` pull-task instead.
This `cp`-then-delink path is for relocating a genuinely mis-homed memory between
dirs you own.

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
removed) with the file; then the **MIS-HOMED** proposals as a move confirm-list
(`<file>  <current dir> → <proposed dir>  — <one-line why>`) and the **SHARED**
proposals as a delivery confirm-list (`<file>  needs recall in <dirs>  —
MIRROR | pull-task to project:<peer-slug>`). Move/mirror/file only what Nick
greenlights.

## Part C — CLAUDE.md + README reconciliation

Instruction/doc files drift exactly like tasks and memories, and the cost is
per-session mis-orientation (a CLAUDE.md is loaded into *every* session's
context — a stale line there misleads more often than any single memory).
Same three verdicts, plus one coupling Part B creates.

**Scope.** The CURRENT project's `CLAUDE.md` (repo root), its parent monorepo's
`CLAUDE.md` if nested, plus the READMEs of the project's own dirs. Global
`~/.claude/CLAUDE.md` only on an "all"/"everything" run — it's high blast-radius
and usually Nick's hand.

### Verdicts

1. **ORPHANED (coverage gap)** — a real subproject/dir exists but no parent
   index mentions it. Detect: list the child dirs that look like projects (have
   their own `.git`, `package.json`, `pubspec.yaml`, or `CLAUDE.md`) and grep the
   parent `CLAUDE.md`'s subprojects table for each. **Match the exact backticked
   `` `dir/` `` token, not a bare substring** — `community` substring-matches the
   `community-grants/` row and yields a false in-table (caught 2026-07-03). A dir
   present on disk but absent from the table is invisible to a session that reads
   only the parent.
   **Fix (auto — reversible via git):** add the table row / index line.
   (Caught 2026-07-03: `community/` — its own repo — was missing from the
   imagineering monorepo's subprojects table.)

2. **DANGLING (stale reference)** — CLAUDE.md/README names a **file, flag, path,
   function, or dir that no longer exists**. This is the memory rule "if one names
   a file/function/flag, verify it still exists" applied to the doc. Detect: extract
   backticked paths and `<!-- dir-id: … -->` / file references, test each for
   existence (`ls`, or grep the symbol in-repo). **Action:** a dead *path* ref is
   auto-fixable (drop or repoint); a dead *behavioural* claim ("the daemon does X")
   is judgment → REPORT + CONFIRM.

3. **MIS-HOMED (wrong altitude)** — a rule in the *project* CLAUDE.md that is
   really global (belongs in `~/.claude/CLAUDE.md`), or a global rule that only
   ever applies to one project. Same global-vs-project asymmetry as a SHARED
   memory: a genuinely cross-project rule wants the global file (recall in every
   session), a project-specific one wants the local file. **Action = REPORT +
   CONFIRM**, never auto — CLAUDE.md edits change every future session's behaviour.

4. **DANGLING dir-id (the Part B coupling)** — `~/.claude/CLAUDE.md` is threaded
   with `<!-- dir-id: … -->` pointers into memory files. **Part B moves memories
   between dirs, which can silently orphan those pointers.** So any run that does a
   Part B move MUST, in the same pass, grep the global CLAUDE.md for a reference to
   the moved file's slug and re-point or flag it. Part C without this leaves a hole
   Part B opens. (This is why extending the audit to CLAUDE.md isn't optional once
   Part B exists.)

### READMEs (light only)

Cheap checks, not a does-it-match-the-code review (that's too expensive for a
routine audit — name it out of scope):
- **Missing** — a project dir with real code and no `README.md`. Surface; offer
  to stub. Not auto.
- **Dangling refs** — README names a build command / script / path that no longer
  exists. Same detect as Part C DANGLING. Auto-fixable path refs; judgment for prose.

## Part D — Durability sweep (un-backed work)

The one substrate with **no Part A/B twin and no existing tool** (`/graph`,
`heal-memory-dir.sh`, this skill's other parts all assume the artifact is already
in a repo). Here the drift isn't *mis-recall* — it's **data loss**: an important
artifact that exists only on local disk with no durable git home. Cost is
categorically worse (a mis-filed memory is *findable-with-effort*; an un-backed
file is *gone* on one `rm -rf` or disk failure), so this part flags loudly and
early even though its fixes need Nick's call.

**Scope.** The CURRENT project's repo + any sibling dirs the session touched.
On "all", sweep `~/git/**` one level deep.

### Verdict: UNBACKED

Detect, cheap → expensive:
1. **No git at all** — a dir with substantive files (`data/`, `*.md` designs,
   scripts) and no `.git`. (Caught 2026-07-03: `~/git/experiments/augur/` — a 30KB
   design doc + README, no repo.)
2. **Repo, zero commits** — `git -C <dir> rev-parse HEAD` fails / "does not have
   any commits yet". The work is staged-in-reality but never snapshotted. (Caught
   2026-07-03: the `community/` repo — a PII-bearing 183-person roster, uncommitted.)
3. **Commits, no remote** — `git -C <dir> remote -v` empty. Local history exists
   but one disk failure ends it. Weight by **sensitivity**: a PII roster with no
   off-machine backup is P0; a scratch experiment is a shrug.
4. **Committed but un-pushed for a long time** — `git -C <dir> log
   @{upstream}.. ` non-empty (ahead of remote). Lower urgency; note it.

**Action = REPORT + CONFIRM (never auto — `git init`/commit/push/remote-create
are Nick's call, and a *private* artifact must not be pushed to a public remote).**
For each: name the artifact, the exposure (what's lost + how sensitive), and the
one-command fix (`git init && commit`, `git remote add`, `gh repo create --private`).
**PII / private artifacts default to a PRIVATE remote — assert the visibility
before proposing a push** (the "social/consent boundary before publishing" rule).

## Light check — consolidation keying

Session summaries live in `~/.claude/consolidation/<ts>/`, each keyed to a project
by `memory-path.txt`. Parallel tabs make this wrong daily (wake-up already warns
of it). Cheap check on a scoped run: read the newest consolidation whose
`memory-path.txt` == this project's MEM; if the newest consolidation *by mtime*
points at a **different** project than its content is about (grep the
`next-session-prompt.md` for another project's repo name), flag it as a MIS-KEYED
summary. REPORT + CONFIRM only — don't rewrite a consolidation's key silently.

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
- **(Part C) A CLAUDE.md edit changes every future session — treat it like a
  global rule change.** Auto-fix only mechanical facts (a dead path, a missing
  table row); any behavioural/prose claim or altitude move is REPORT + CONFIRM.
- **(Part D) Never push a private artifact to a public remote to "back it up".**
  Assert repo visibility first; PII/private defaults to `--private`. The fix for
  un-backed work is Nick's call, always — this part *flags*, it does not `git init`.
- **(Verification) A negative from a search tool is only as good as its
  traversal.** `find`/`rg`/`grep -r` stop at **symlink** boundaries by default, so
  a symlinked subtree is invisible to them while `ls`/`cat` walk right in
  (2026-07-03: this very skill lives under `~/.claude/skills` → a symlink into
  `nickmeinhold/claude-skills`; a plain `find`/`rg` "couldn't find it" and I
  wrongly concluded it wasn't a SKILL.md). When a search says "absent" for
  something that should exist, suspect the instrument's blind spots — symlinks,
  `.gitignore`, hidden files, perms — with `ls`/`-L`/`--no-ignore --hidden`,
  before trusting the absence. Naming that this skill's *own home* is a symlinked
  git repo also matters for Part D: edits here ARE version-controlled — commit them.
