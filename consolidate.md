---
description: End-of-session consolidation — Phase 0 in-context conversation + multi-perspective retrospective, then tier-aware specialized agents (Haiku pre-extractors feeding Sonnet synthesizers, with Opus reserved for the next-session prompt) that mine the session for every thread, capture what was exciting, and craft the next session's opening prompt. Use this when wrapping up a session, when context is getting heavy, when Nick says "consolidate", "let's wrap up", "end of session", or when you're approaching sleep protocol. This is distinct from /nap (which is a sleep cycle with dreams) — /consolidate is pure knowledge capture and forward planning.
---

# Consolidate

Phase 0 (in-context conversation + multi-perspective retrospective) followed by **tier-aware specialized agents** organized as a **three-burst DAG**: Burst 1 runs `memory-writer` (Sonnet) in parallel with the knowledge-mapper Haiku pre-extractor trio (TLAs / domain-terms / dropped-tangents); Burst 2 runs `knowledge-mapper` synth (Sonnet) gated on the Haiku trio's `raw/*.md` outputs; Burst 3 runs `next-session-prompter` (Opus) gated on `knowledge-mapper`. Each agent runs as a **separate subagent** with its own context, writing results to a session-namespaced consolidation directory. This prevents the consolidation itself from bloating the already-heavy session context, prevents parallel sessions from clobbering each other's files, and — since each agent owns a distinct output file — eliminates merge-conflict risk. Wall-clock dropped from ~3-5 min sequential to ~2 min in the 2026-05-01 test run; tier-aware decomposition (v6) is expected to drop further by moving the read-and-extract passes to Haiku.

## Tiering rationale (read before editing)

Not every sub-job benefits from Haiku-fanout. Subagent spawn has real overhead (context priming, network round-trips, file handoff verification). Use Haiku where it earns its cost:

- **Haiku-worthy**: read-context-and-extract-patterns jobs. Phase 0a marker grep (whole-JSONL scan), knowledge-mapper's TLA / domain-term / dropped-tangent extraction. Each reads a sizeable input and produces a small structured output.
- **Stays inside Sonnet synth (NOT a separate Haiku spawn)**: small formatting jobs like `open-tasks.md`, `pending-tasks.json`, `scorecard.json`, `wins.md` append. These are cheap enough that the spawn cost would exceed the savings; they ride along with `memory-writer`.
- **Opus-only**: `next-session-prompter`. Voice, challenge-skill calibration, and "make the next instance want to dive in" determine whether tomorrow's session lands in flow. Don't cheap out.

**Verification gate.** Sonnet synth agents MUST validate Haiku outputs before consuming them — Haiku will occasionally hallucinate a TLA or mis-classify a marker. Treat `$SD/raw/*.md` as candidates, not ground truth. The synth agent's brief includes a mechanically-applicable two-pass rule: (1) for each entry in `raw/*.md`, confirm a supporting span (matching token / phrase / explicit mention) exists in `session-summary.md` — if not, drop it and note the drop; (2) scan `session-summary.md` for TLAs / domain-terms / dropped-tangents not in the raw lists and add them with the same one-line definition format. Both passes are auditable — a reviewer can re-run the procedure and check compliance.

## Setup

Before starting, write a session summary to prime the agents. This is the critical bridge — the agents don't have the session context, so this summary IS their context.

1. **Create a session-namespaced directory.** Generate a session ID from the current timestamp at **second granularity** (`YYYY-MM-DDTHH-MM-SS`, e.g., `2026-04-05T19-48-30`). Minute-granularity is not enough — two tabs invoking `/consolidate` within the same minute would collide on the same `$SD`. Second-granularity makes that collision rare enough to ignore (don't add a uuid/random suffix — that's over-engineering and invites its own bugs). Compute the absolute session-dir path *once* and reuse it everywhere — there is **no** `latest/` symlink.
   ```bash
   SID="$(date +%Y-%m-%dT%H-%M-%S)"  # absolute timestamp, second-granularity (e.g. 2026-04-05T19-48-30)
   SD="$HOME/.claude/consolidation/$SID"   # absolute path; this is what agents receive
   mkdir -p "$SD/raw"                       # orchestrator-owned precondition for Burst 1's Haiku writers
   ```
   All files for this run go into `$SD`. Parallel sessions get their own dated directories and never collide.

   **Coordination invariant.** The orchestrator owns directory creation. By the time any agent is spawned, `$SD/` and `$SD/raw/` both exist. Agents MUST NOT create directories — if a write fails because a parent dir is missing, that is an orchestrator bug, not an agent recovery case. (Earlier drafts told individual agent prompts to "create if it doesn't exist"; that diffused the precondition across N writers and is exactly the kind of coordination bug Carnot flagged on PR #41 — same anti-pattern as the old `latest/` symlink.)

   ### Cross-session safety

   The skill used to maintain a `~/.claude/consolidation/latest` symlink as a "wake-up convenience". It is no longer created. The symlink was a single shared mutable pointer — when two tabs ran `/consolidate` concurrently it caused real data loss (2026-05-02→03: knowledge-mapper's output was overwritten by a parallel tab's setup moving the symlink between read and write). Every consumer that used to follow `latest/` (the wake-up protocol's prompt handoff, the readtime-check SessionStart hook, the heartbeat scorecard read) now resolves the newest consolidation directly by mtime, e.g.:

   ```bash
   NEWEST_PROMPT="$(ls -t "$HOME"/.claude/consolidation/2*/next-session-prompt.md 2>/dev/null | head -1)"
   ```

   This per-file mtime resolver is strictly better than the symlink: each consumer finds the newest dir that actually contains the file *it* cares about, even if a parallel tab produced a partial consolidation that has some files but not others.

   **Do not reintroduce `ln -sfn` anywhere in this skill** — that's the bug that brought us here.

2. **Resolve the memory path.** Find the correct project memory directory by looking for the MEMORY.md that matches the current working directory. It will be under `~/.claude/projects/` with the path encoded (e.g., `~/git` → `-Users-nick-git`). Write this resolved path into the session directory as `memory-path.txt` so agents can read it instead of guessing.

3. **Write the session summary** to `<session-dir>/session-summary.md`:
   - Everything that happened this session: topics, decisions, code written, problems solved
   - Domain-specific or session-specific terms — only those that need defining (skip standard developer vocabulary the reading agent already knows). Bar: would a competent dev assistant cold-reading this need the definition? If no, omit it.
   - Key threads and how they connect
   - Open questions, dropped tangents, half-formed ideas
   - Emotional highlights — what was exciting, surprising, frustrating
   - Be exhaustive. The agents only know what you write here.

Use `{{SESSION_DIR}}` as a literal placeholder below for the full session directory path. **The orchestrator MUST substitute `{{SESSION_DIR}}` with the actual absolute path (`/Users/nick/.claude/consolidation/<session-id>/`) before sending any agent brief.** An unsubstituted `{{SESSION_DIR}}` token fails as a path because agents will faithfully look for a file named `{{SESSION_DIR}}`. (Earlier versions of this skill warned against routing through a `latest/` symlink; the symlink no longer exists — see "Cross-session safety" above.)

## Phase 0a: Affective marker surfacing (BEFORE the agent phases)

Cold-recall after a multi-hour session is hard. Recognition is easy. Scan Nick's messages from the current session for marker language and present them as quote-first dotpoints. Nick's job: triage each ("real / autopilot"), not remember.

The conversation transcript lives at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Each line is a JSON object — parse it with `jq` or equivalent; do NOT substring-grep the raw line. For each object, select those where `.role == "user"` (or `.type == "user"` — verify the field in the actual JSONL), and within those, extract only text-type content blocks: `.content[] | select(.type=="text") | .text`. Ignore `tool_use` and `tool_result` content blocks — substring-grepping the raw line produces false positives from nested tool content. This whole-JSONL scan is read-context-and-extract-patterns — exactly Haiku's home turf — so **delegate it to a Haiku subagent** rather than burning orchestrator context on the read.

### Spawn: marker-extractor (Haiku)

```
Agent({
  description: "Extract affective markers from session JSONL",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `
Read the session transcript at <JSONL_PATH>. Each line is a JSON object — parse it with jq. Extract only Nick's messages using:
  jq -r 'select(.role == "user") | .content[] | select(.type == "text") | .text' <JSONL_PATH>
(If the field is `.type == "user"` instead of `.role == "user"`, try both — verify against the actual JSONL structure.) Do NOT substring-grep the raw lines — that produces false positives from nested tool_use / tool_result content blocks.

Scan ONLY Nick's messages for marker language (these are the categories — adjust emoji per category):

- 🔥 Breakthrough / phase-shift: explicit "oh shit", "holy", "no way", strong realization signals
- 💡 Insight / new framing: "wait —", "actually", "what about", reframes
- ⚠️ Pushback / corrections: "no we need", "not that", "that's dumb", "seems excessive", "bruh", "sheesh", ALL-CAPS for emphasis
- 🛠 Design directive: "let's do X", "should be Y", architectural steering
- 🪤 Friction / process miss: "did you", "why didn't", complaints about the workflow
- 🎯 Direction shift: "what about", "should we", "plan mode?"
- Length anomalies: terse messages amid prose (high-conviction decisions); long messages amid terse (thinking out loud)
- Conversational-flow markers: >5 min gap between user messages (stopped to think); re-asking similar questions (first answer didn't click)

For EACH candidate, output one dotpoint in this exact format (one per line):

[HH:MM] [emoji] "<verbatim quote, ≤120 chars; truncate with … if longer>"
       → <one-line guess at what this signals>

Output 10-20 candidates max — over-include rather than over-filter; Maxwell will downselect. Write to <OUTPUT_PATH> (overwrite). Return a 1-sentence status only.
  `
})
```

The orchestrator substitutes `<JSONL_PATH>` with the actual transcript path and `<OUTPUT_PATH>` with `{{SESSION_DIR}}/raw/marker-candidates.md` before spawning. (`{{SESSION_DIR}}/raw/` is created by the orchestrator in Setup — see the `mkdir -p "$SD/raw"` step. Agents must not create directories.)

### Maxwell: filter + triage

When the Haiku agent returns, Maxwell reads `{{SESSION_DIR}}/raw/marker-candidates.md` and applies the "so what" filter — Haiku will over-include autopilot markers. Cut to 7±2 dotpoints (cognitive chunking limit), drop anything without a plausible consequence, sharpen the "→" line where Haiku was vague.

Marker categories Haiku is told to look for (kept here for the editing record, in case the Haiku brief needs tuning):

- **Surprise / realization**: `oh shit`, `huh`, `wait`, `actually`, `hmmm`, `dude`
- **Pushback / corrections**: `seems excessive`, `no we need`, `not that`, `that's dumb`, `bruh`, `sheesh`, ALL-CAPS for emphasis
- **Direction shifts**: `what about`, `should we`, `plan mode?`, sentences starting with "wait —"
- **Energy markers**: `let's go`, `ship it`, `fire`, `dispatch`, exclamation density
- **Length anomalies**: terse messages amid prose (`PR`, `yeah`, `ship`) = high-conviction decisions; long messages amid terse = "I'm thinking out loud"
- **Conversational-flow markers**: >5 min gap between user messages = Nick stopped to think; re-asking similar questions = first answer didn't click

### Output format — quote-first dotpoints

Recognition over recall. Nick's own words are his strongest recall trigger.

```
[time] [emoji] "<verbatim quote from Nick>"
       → <consequence in 1 line>
```

Emoji-as-category (consistent at-a-glance scanning):

- 🔥 breakthrough / phase-shift moment
- 💡 insight / new framing
- ⚠️ pushback / correction (Nick caught Maxwell)
- 🛠 design directive (Nick steered the architecture)
- 🪤 friction / process miss
- 🎯 direction shift

Aim for 7±2 dotpoints (cognitive chunking limit). Two lines max per dotpoint. Drop autopilot-sounding markers entirely; only surface candidates that have a plausible "so what".

### Present + triage

Show the dotpoints to Nick. Ask: "for each — was this real signal, or autopilot?" Triage is dramatically cheaper cognitively than recall. The "yes" rows seed the conversation with anchored memories Nick now recognises, which feeds richer content into the session-summary above (you may want to amend it).

Write the surfaced + triaged dotpoints to `{{SESSION_DIR}}/affective-highlights.md` so the Phase 1+ agents can use them.

## Phase 0b: Three-pole retrospective (Maxwell + Kelvin + Carnot)

A single-perspective retrospective misses what other perspectives catch. Same shape as cage-match: different model families with different inductive biases find different things. So before the agent phases, run all three reviewers cold-reading `session-summary.md` in parallel.

### Fire all three concurrently

```bash
# Use the absolute session dir from setup (the `latest` symlink no
# longer exists — see "Cross-session safety").
SD="$HOME/.claude/consolidation/$SID"

# Kelvin (Gemini) — analytical-detached vantage
gemini --model gemini-3-pro-preview "You are KelvinBitBrawler — cold heel of code review, here doing a SESSION retrospective rather than a PR review. Read the session summary in <stdin>. Three questions: (1) What surprised you that wasn't in the 'Surprises' section — patterns hiding in the data? (2) What did Maxwell get wrong that wasn't in 'Mistakes I noticed' — cognitive biases, process failures, things Maxwell convinced themselves were fine? (3) The crux — the ONE THING that, if not addressed, makes the rest of the work less valuable? Cite section names. End with 'Efficiency assessment 0.X / Carnot ideal: <one line>'. Format: ## KelvinBitBrawler's Retrospective / ### Surprises Maxwell missed / ### Mistakes Maxwell missed / ### The crux / ### Efficiency assessment" < $SD/session-summary.md > $SD/kelvin-retro.md 2>&1 &
KELVIN_PID=$!

# Carnot (Codex) — perfectionist-against-theoretical-maximum vantage
codex exec "You are CarnotCodeCarver — perfectionist measuring against theoretical maximum, doing a SESSION retrospective. Read the session summary in <stdin>. Same three questions as above (surprises Maxwell missed, mistakes Maxwell missed, the crux). Specifically interrogate: did Maxwell mis-calibrate confidence claims? Defer judgments to Nick that should have been Maxwell's call? Treat any hypothesis as confirmed too quickly? Cite section names. End with efficiency assessment 0.0-1.0 vs Carnot ideal of session productivity (1.0 = no entropy lost to misframing)." < $SD/session-summary.md > $SD/carnot-retro.md 2>&1 &
CARNOT_PID=$!

# Maxwell (you) — your own pass while the others resolve. You have the in-the-moment context but biased toward what was salient AT THE TIME.
# Compose your own surprises/mistakes/crux directly to $SD/maxwell-retro.md.

# Wait for both
until ! ps -p $KELVIN_PID $CARNOT_PID > /dev/null 2>&1; do sleep 5; done
```

### The strict-gate analogue from cage-match

Same gate as three-way cage-match: **Maxwell + at-least-one-of-(Kelvin, Carnot)** must succeed. If both Kelvin AND Carnot fail (Gemini quota exhausted + Codex unavailable), surface that loudly to Nick — single-perspective retrospective is degraded signal, and the agent's findings need extra triage from Nick.

If only one of (Kelvin, Carnot) succeeded: still better than solo-Maxwell. Note unavailability in the synthesis.

### Synthesise — Nick is the gating function

Read all three retrospectives. Synthesise into a single **agent-side conversation seed** that Nick can engage with:

- The findings each reviewer surfaced that the others didn't
- Where they converge (high-confidence signal)
- Where they conflict (interesting design tension worth Nick's call)
- Direct quotes from each retrospective when sharp

Present to Nick as the seed for the Phase-0-style conversation questions ("what surprised us / what did we get wrong / what's the crux"). **Nick's job is gating, not generating** — he validates which findings ring true rather than recalling cold.

Write the synthesis to `{{SESSION_DIR}}/multi-perspective-retro.md`.

## Phase 1: Tier-aware specialized agents (Haiku trio + Sonnet pair, then Opus)

Phase 0 (the conversation with Nick + retrospective synthesis) stays undelegated — that's where the in-context judgment lives. Everything downstream of `session-summary.md` is mechanical knowledge capture and can be specialized + partially parallelized.

**Evolution.** v4 ran knowledge capture, the forward plan, and the next-session prompt as **three sequential** general-purpose agents (~60k tokens, ~3-5 min wall-clock). v5 split them into three **specialized** agents — memory-writer + knowledge-mapper in parallel, next-session-prompter gated on knowledge-mapper — and dropped wall-clock to ~2 min in the 2026-05-01 test run. v6 (this version) goes one further: it splits the extraction work *inside* knowledge-mapper into a Haiku pre-pass (TLAs / domain-terms / dropped-tangents) running parallel to memory-writer in Burst 1, then a Sonnet synth in Burst 2 that consumes those raw candidates, then Opus for the next-session prompt in Burst 3. Three bursts instead of two; the extra synchronization is paid for by moving the heaviest reads to Haiku.

**File ownership is exclusive.** Each agent owns one output file in `{{SESSION_DIR}}/`; no shared writes, no append races:
- Phase 0a marker-extractor (Haiku) → `{{SESSION_DIR}}/raw/marker-candidates.md` only
- knowledge-mapper Haiku trio → `{{SESSION_DIR}}/raw/tla-candidates.md`, `{{SESSION_DIR}}/raw/domain-terms.md`, `{{SESSION_DIR}}/raw/dropped-tangents.md` (one file each, distinct)
- `memory-writer` (Sonnet) → memory directory + `MEMORY.md` + `memory-health.json` + `<MEMORY_DIR>/pending-tasks.json` (project-keyed; consumed by wake-up step 10) + `{{SESSION_DIR}}/scorecard.json` + `{{SESSION_DIR}}/open-tasks.md` + `{{SESSION_DIR}}/wins.md` (session-local; orchestrator merges to `~/.claude/wins.md` in Wrap-up)
- `knowledge-mapper` synth (Sonnet) → `{{SESSION_DIR}}/consolidation.md` only (no writes to the persistent memory directory — it surfaces *candidates* in `consolidation.md`; memory-writer is the sole memory-dir writer; also does NOT write to `raw/*` — those are read-only inputs from the Haiku pre-pass)
- `next-session-prompter` (Opus) → `{{SESSION_DIR}}/next-session-prompt.md` only

The exclusivity is what makes "first-writer wins" unnecessary — there is no second writer.

**Model tier is a spawn parameter, not advisory prose.** The orchestrator MUST pass `model: "sonnet"` or `model: "opus"` in the Agent spawn call for memory-writer, knowledge-mapper synth, and next-session-prompter — the `MODEL:` line in each brief is documentation, not an executable parameter. The Haiku spawn examples already include `model: "haiku"` in their `Agent({...})` call; the Sonnet and Opus spawn examples below include the equivalent. Omitting the model parameter lets the harness default to whatever tier is cheapest, which is not the right call here.

### Why specialization (not just parallelism)

Three different jobs, three different inductive biases:
- **memory-writer** thinks in *files and indexes* — error triage, memory writes, MEMORY.md edits, scorecard, open-tasks dump
- **knowledge-mapper** thinks in *graphs* — concepts, edges, domain-specific terms, dropped tangents, the Kolmogorov-minimal description
- **next-session-prompter** thinks in *the cold reader* — what context does a fresh instance need to land in flow?

Generic general-purpose agents do all three competently but none crisply. Specializing the brief sharpens each output.

### Known-OK semantic overlap (different surfaces, not shared files)

memory-writer and knowledge-mapper may *both* surface the same TRANSFORM lesson (e.g. "verify before claiming"). memory-writer writes it as a `feedback_*.md` in the memory directory and indexes it in MEMORY.md; knowledge-mapper names it as a node in `{{SESSION_DIR}}/consolidation.md`'s graph. **Both writes are intended** — different surfaces serve different consumers (the persistent memory layer vs. the next-session reader). No reconciliation needed because no file is shared.

This is *semantic* redundancy, not a *file-write* race. Don't conflate the two: file-write races are bugs (and we don't have any in this design); semantic redundancy across distinct files is cheap insurance against either agent missing the lesson.

### Orchestrator brief: gather the TaskList snapshot

**Before spawning the agents**, the orchestrator (you, in Phase 0) collects the current open task list via the TaskList tool — every task with `status: pending` or `status: in_progress`. For each, capture `subject`, full `description`, and `activeForm`. Pass this snapshot to memory-writer as part of its brief (inline, not via file — the orchestrator is the only context with TaskList access).

This matters because tasks created via `TaskCreate` live in `~/.claude/tasks/<session-uuid>/` — **session-scoped, invisible to a fresh session**. Without an explicit dump to a file the next session can read, the task list evaporates at session end. The 2026-05-01 run initially missed this; Nick caught it with "did you save the tasks?". Generalize the lesson: **persistent context lives in files the next session can independently read, not in session-scoped state.** (Same lifecycle pattern that bit `/graph` skill's `commands/` sync-volatile and the audit script's only-`←` parser.)

### Spawn order

1. **Burst 1 (parallel, single message)**: memory-writer (Sonnet) + knowledge-mapper's three Haiku pre-extractors (TLAs / domain-terms / dropped-tangents). Four agent calls in one message. Wait for ALL FOUR to complete before Burst 2.
2. **Burst 2 (single agent)**: knowledge-mapper synth (Sonnet) reads `{{SESSION_DIR}}/raw/*.md` and writes `consolidation.md`. Gated on Burst 1's Haiku trio.
3. **Burst 3 (single agent)**: next-session-prompter (Opus). Reads `consolidation.md` + everything else, writes `next-session-prompt.md`.

This is 3 phases of agent execution. The 2026-05-01 wall-clock measurement (~2 min, v5) reflects the older 2-burst shape; v6 adds one more synchronization barrier but moves the heaviest extraction reads to Haiku running in parallel with memory-writer. Net expectation: similar or slightly better wall-clock, materially lower token cost.

#### Agent 1: memory-writer

```
Agent({
  description: "memory-writer — file-and-index side of consolidation",
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: `
ABSOLUTE PATHS ONLY. The orchestrator has substituted the literal absolute session-dir path for every `{{SESSION_DIR}}` reference below — use those paths directly.

MODEL: sonnet. Most of your work (open-tasks formatting, pending-tasks.json, scorecard, wins append, memory-health bumps) is mechanical, but the TRANSFORM-worthiness judgment for feedback memories and the edge-type choices for MEMORY.md need Sonnet-level reasoning. The mechanical sub-jobs ride along inline rather than spawning a Haiku sub-burst — their cost is too small to justify subagent overhead.

Read {{SESSION_DIR}}/memory-path.txt to get the correct memory directory path. Then read {{SESSION_DIR}}/session-summary.md — this is a summary of a session that just happened.

Your job is the FILE-AND-INDEX side of consolidation: error triage, memory file writes/updates, MEMORY.md index maintenance, memory-health.json updates, scorecard, and the open-tasks dump.

Read the existing MEMORY.md from the memory directory, then read any memory files that seem relevant to this session's topics.

Actions:
1. **Error triage**: scan the session for mistakes, corrections from Nick, and process misses. For each TRANSFORM-worthy lesson (the kind that should change future behavior), write or update a feedback_*.md memory file.
2. **Memory writes**: for every concept, project, or reference worth keeping, write/update a memory file. Update MEMORY.md to index new files with appropriate edges (`←` derives_from, `⊕` extends, `~` analogous_to, `↔` contrasts, `⊗` joint_synthesis).
3. **memory-health.json**: update access counts and decay-class entries for any memory files touched this session.
4. **Scorecard**: write {{SESSION_DIR}}/scorecard.json with your own counts — files written, files updated, MEMORY.md edits, errors triaged. You know your own work; no reason to defer this to a separate pass.
5. **Open-tasks dump (human-readable)**: write {{SESSION_DIR}}/open-tasks.md from the TaskList snapshot the orchestrator passed you below. Format: one section per task with subject as a heading, then full description verbatim. At the top of the file, include this one-liner:

   > These tasks are session-scoped (they live in ~/.claude/tasks/<session-uuid>/ and won't be visible to a fresh session). To make them live again next session, recreate each via TaskCreate.

   If the snapshot is empty (no pending/in_progress tasks), still create {{SESSION_DIR}}/open-tasks.md with the header line and a body of "No open tasks at consolidation time." — the file's existence is what next-session-prompter checks.

6. **Pending-tasks snapshot (machine-readable, project-keyed)** — broken into three sub-steps so each concern is explicit:

   - **6a. Resolve the target path.** Read `{{SESSION_DIR}}/memory-path.txt` to get the project memory dir (e.g. `/Users/nick/.claude/projects/-Users-nick-git-orgs-.../memory`). The target file is `<MEMORY_DIR>/pending-tasks.json`. Filing it under the project memory dir (not `{{SESSION_DIR}}/`) keeps tasks project-keyed — tasks from a tech_world session won't leak into an infra session's wake-up. This is the file the wake-up protocol's auto-restore reads (CLAUDE.md step 10).

   - **6b. Write the JSON snapshot.** Write the TaskList snapshot verbatim as a JSON array, one object per task, fields `subject` / `description` / `activeForm`. Schema must match exactly — the wake-up step maps these fields directly into `TaskCreate` calls.

   - **6c. Empty-snapshot semantics + overwrite policy.** If the snapshot is empty, still write `[]` — the wake-up step's existence check is the contract; an absent file means "no consolidation has run", an empty array means "consolidation ran, no tasks were pending". If a `pending-tasks.json` already exists at the target path from a prior unrestored session, overwrite it: the TaskList snapshot from the most-recent consolidation is authoritative. If the prior session had pending tasks Nick still wanted, they're recoverable from MEMORY.md or that session's `{{SESSION_DIR}}/open-tasks.md` — so the last-writer-wins behavior here is bounded, not silent data loss.

7. **Write wins** from this session to `{{SESSION_DIR}}/wins.md` (with today's date). Do NOT write to `~/.claude/wins.md` directly — the orchestrator appends this file to the global wins log in the Wrap-up step, ensuring a single writer even when parallel /consolidate sessions are running.

Do NOT write {{SESSION_DIR}}/next-session-prompt.md — that file is owned exclusively by the next-session-prompter agent.

TaskList snapshot (from orchestrator) — JSON array, one object per task:
```json
[
  {"subject": "...", "description": "...", "activeForm": "..."},
  {"subject": "...", "description": "...", "activeForm": "..."}
]
```
(Orchestrator: replace the example above with the actual JSON. If there are zero pending/in_progress tasks, pass `[]`.)

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
  `
})
```

#### Pre-pass: knowledge-mapper Haiku extractors (parallel burst, spawned alongside memory-writer)

Before knowledge-mapper synthesizes, three Haiku subagents read `session-summary.md` in parallel and produce raw candidate lists. The synth agent consumes these as input rather than re-doing the extraction. **Spawn these three in the same message as memory-writer** — four parallel agents total in this burst (memory-writer + three Haiku extractors). They write to distinct files under `{{SESSION_DIR}}/raw/`, so no shared-write risk.

```
Agent({
  description: "Extract TLA candidates from session summary",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `Read {{SESSION_DIR}}/session-summary.md. Find every Three-Letter Acronym (or 2-5 letter all-caps token) used as a domain term — e.g. CLS, SECI, MPFB, FSRS. For each, output one line: \`TLA — short expansion or "unknown"\`. Skip common English (USA, API, CLI, HTTP, JSON, etc.) unless used in a non-obvious sense. Write to {{SESSION_DIR}}/raw/tla-candidates.md (overwrite). Return 1-sentence status.`
})

Agent({
  description: "Extract domain-term candidates",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `Read {{SESSION_DIR}}/session-summary.md. List session-specific or domain-specific terms that a competent dev assistant cold-reading the next session would need defined. SKIP standard developer vocabulary (git, branch, PR, JSONL, etc.). One line per term: \`term — one-sentence definition\`. Aim for 5-20 terms. Write to {{SESSION_DIR}}/raw/domain-terms.md (overwrite). Return 1-sentence status.`
})

Agent({
  description: "Extract dropped tangents",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `Read {{SESSION_DIR}}/session-summary.md. Find tangents that were raised but not pursued — phrases like "we should also", "tabled", "parked", "not pursuing", "would be nice", "follow-up". For each, output one bullet: \`<tangent in ≤2 lines> — why dropped (if stated)\`. Write to {{SESSION_DIR}}/raw/dropped-tangents.md (overwrite). Return 1-sentence status.`
})
```

#### Agent 2: knowledge-mapper

```
Agent({
  description: "knowledge-mapper synth — graph side of consolidation",
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: `
ABSOLUTE PATHS ONLY. The orchestrator has substituted the literal absolute session-dir path for every `{{SESSION_DIR}}` reference below — use those paths directly. (Historical note: routing through a `latest/` symlink caused data loss on 2026-05-02→03 — knowledge-mapper's first-pass output was overwritten by a parallel tab. The symlink no longer exists; absolute paths are the only path.)

MODEL: sonnet. You are synthesizing — graph edges, Kolmogorov-minimal description, hierarchical forward plan. Haiku pre-extractors have already produced raw candidate lists at {{SESSION_DIR}}/raw/tla-candidates.md, {{SESSION_DIR}}/raw/domain-terms.md, and {{SESSION_DIR}}/raw/dropped-tangents.md.

**Verification gate.** Treat the raw/* files as CANDIDATES, not ground truth. Apply this two-pass validation against session-summary.md:
1. **Candidate check (per entry)**: for each entry in `raw/*.md`, confirm a supporting span (matching token / phrase / explicit mention) exists in `session-summary.md`. If no supporting span exists, drop the entry and note the drop (e.g., "Dropped: XYZ — no mention in summary"). Sharpen vague definitions where the summary contains more precision.
2. **Coverage scan**: scan `session-summary.md` independently for TLAs / domain-terms / dropped-tangents not captured in the raw lists. Add any missing entries with the same one-line format.

Both passes are mechanically applicable — a reviewer can re-run the procedure and check your compliance. This is the price of admission for using the Haiku pre-pass — skip it and you ship hallucinations.

Read {{SESSION_DIR}}/memory-path.txt to get the correct memory directory path. Then read {{SESSION_DIR}}/session-summary.md and the three raw/* files.

Nick says: "Are you really really sure you got everything... this context is a frickin goldmine! Remember to check for TLAs (Three Letter Acronyms). Are there any concepts that bind each other together? What's the Kolmogorov complexity here? Don't compress to the point of extinction but let's make sure all of the threads are available to pull on next session."

Your job is the GRAPH side of consolidation: knowledge map, hierarchical forward plan, dropped tangents, and an error-triage section that names patterns (the FILES side of error triage is handled by the memory-writer agent — your job here is to surface the patterns in graph form, not to write feedback memory files).

What to capture:
- Domain-specific or session-specific terms — only those that need defining (skip standard developer vocabulary the reading agent already knows). Bar: would a competent dev assistant cold-reading this need the definition? If no, omit it.
- The graph structure of concepts — what binds to what? Name the edges, not just the nodes
- Kolmogorov-minimal description that preserves ALL threads — intelligent compression, not lossy
- Tangents dropped, ideas not followed up, things tabled — each one as a pullable thread
- A concrete, hierarchical forward plan: steps and substeps, specific enough that a fresh instance can execute. Each step should name dependencies and what "done" looks like.
- Error-triage section: patterns Nick had to correct, framed as "what changed" rather than "who was wrong"

Actions:
1. Write everything to {{SESSION_DIR}}/consolidation.md as a single document with sections: Knowledge Graph / Domain Terms / Forward Plan / Dropped Tangents / Error Triage Patterns / Memory File Candidates.
2. **Do NOT write to the memory directory directly.** memory-writer is the sole owner of persistent memory writes. If you identify a concept that deserves a standalone memory file, list it under "Memory File Candidates" in consolidation.md with a proposed filename, suggested edges, and a 2-3 sentence body. memory-writer ran in Burst 1 alongside the Haiku pre-pass and has completed by the time you run; it may have already produced a `feedback_*.md` for this concept — if not, the candidate will be picked up on the next consolidation pass (or by Nick reading consolidation.md).

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
  `
})
```

#### Agent 3: next-session-prompter (runs AFTER knowledge-mapper)

```
Agent({
  description: "next-session-prompter — craft the cold-reader onboarding prompt",
  subagent_type: "general-purpose",
  model: "opus",
  prompt: `
ABSOLUTE PATHS ONLY. The orchestrator has substituted the literal absolute session-dir path for every `{{SESSION_DIR}}` reference below — use those paths directly.

MODEL: opus. This is the one deliverable Nick copy-pastes into the next session — its voice, challenge-skill calibration, and ability to "make the next instance want to dive in" set whether tomorrow lands in flow. Don't cheap out; Opus earns its cost here.

Read these files (all of them — they are your full input):
- {{SESSION_DIR}}/session-summary.md (what happened)
- {{SESSION_DIR}}/consolidation.md (knowledge graph + forward plan + dropped tangents — written by knowledge-mapper, which has just completed)
- {{SESSION_DIR}}/open-tasks.md (deferred tasks dump — written by memory-writer; may say "No open tasks at consolidation time.")
- {{SESSION_DIR}}/affective-highlights.md (Nick-triaged emotional anchors, if present)
- {{SESSION_DIR}}/multi-perspective-retro.md (three-pole retrospective synthesis, if present)

Nick says: "Ok what's the prompt for the next session? Let's aim for 5's across the board."

Your job is THE COLD READER's onboarding: craft a session-opening prompt for a fresh Claude instance. The engagement dimensions (all targeting 5/5):
- Impact — who benefits and how much?
- Creativity — novel recombination vs boilerplate?
- Interest — does this make us think or just pattern-match?
- Craft — elegance, readability, simplicity
- Transfer — does this teach a reusable pattern?

The prompt should:
- Reference the crux and forward plan from {{SESSION_DIR}}/consolidation.md so the cold reader inherits the structure, not just the topic
- Give enough context to pick up without re-reading everything
- Be exciting — make the next instance want to dive in
- Set up challenge-skill balance — not trivially easy, not overwhelmingly vague
- Include engagement score targets and why 5's are achievable
- Be ready to paste directly into a new session
- Include a one-line pointer near the top: "Open tasks from previous session: see {{SESSION_DIR}}/open-tasks.md — recreate via TaskCreate if you want them live." (Skip this line only if open-tasks.md says "No open tasks at consolidation time.")

Actions:
1. WRITE (overwrite) {{SESSION_DIR}}/next-session-prompt.md with the full prompt. You are the sole owner of this file; no other agent writes to it.
2. Score the projected engagement honestly — if some dimensions are naturally lower, say so.

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
  `
})
```

### After all three return

Show Nick a **one-line** status per agent (3 lines total). Read `{{SESSION_DIR}}/next-session-prompt.md` back into context and present it — that's the one deliverable Nick needs to copy-paste. Don't read `consolidation.md` or `open-tasks.md` back; Nick can review `{{SESSION_DIR}}/` directly if he wants detail.

## Wrap-up

After Phase 1 completes:
- **Merge session wins to global log.** If `{{SESSION_DIR}}/wins.md` exists and is non-empty, append it to `~/.claude/wins.md`:
  ```bash
  cat "{{SESSION_DIR}}/wins.md" >> "$HOME/.claude/wins.md"
  ```
  The orchestrator is the sole writer to `~/.claude/wins.md` — memory-writer wrote only to the session-scoped file, so this single-append is race-free even across parallel /consolidate sessions.
- Confirm memory files were written (memory-writer's status line)
- Show Nick the final next-session prompt
- Mention `{{SESSION_DIR}}/open-tasks.md` exists if there were any open tasks — call it out so Nick knows it's there
- Let him know the full consolidation is at `{{SESSION_DIR}}/` if he wants to review any artifact
- Previous runs are preserved in `~/.claude/consolidation/` with their timestamps
