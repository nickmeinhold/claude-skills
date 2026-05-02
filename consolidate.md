---
description: End-of-session consolidation — Phase 0 in-context conversation + multi-perspective retrospective, then three specialized agents (memory-writer + knowledge-mapper in parallel, then next-session-prompter) that mine the session for every thread, capture what was exciting, and craft the next session's opening prompt. Use this when wrapping up a session, when context is getting heavy, when Nick says "consolidate", "let's wrap up", "end of session", or when you're approaching sleep protocol. This is distinct from /nap (which is a sleep cycle with dreams) — /consolidate is pure knowledge capture and forward planning.
---

# Consolidate

Phase 0 (in-context conversation + multi-perspective retrospective) followed by **three specialized agents**: `memory-writer` and `knowledge-mapper` run in parallel; `next-session-prompter` runs after `knowledge-mapper` completes (it needs the knowledge-graph + forward plan as input). Each agent runs as a **separate subagent** with its own context, writing results to a session-namespaced consolidation directory. This prevents the consolidation itself from bloating the already-heavy session context, prevents parallel sessions from clobbering each other's files, and — since each agent owns a distinct output file — eliminates merge-conflict risk. Wall-clock dropped from ~3-5 min sequential to ~2 min in the 2026-05-01 test run.

## Setup

Before starting, write a session summary to prime the agents. This is the critical bridge — the agents don't have the session context, so this summary IS their context.

1. **Create a session-namespaced directory.** Generate a session ID from the current timestamp: `YYYY-MM-DDTHH-MM` (e.g., `2026-04-05T19-48`). Create `~/.claude/consolidation/<session-id>/`. Then update the `latest` symlink:
   ```bash
   mkdir -p ~/.claude/consolidation/<session-id>
   ln -sfn ~/.claude/consolidation/<session-id> ~/.claude/consolidation/latest
   ```
   All files for this run go into this directory. Parallel sessions get their own directories and never collide.

2. **Resolve the memory path.** Find the correct project memory directory by looking for the MEMORY.md that matches the current working directory. It will be under `~/.claude/projects/` with the path encoded (e.g., `~/git` → `-Users-nick-git`). Write this resolved path into the session directory as `memory-path.txt` so agents can read it instead of guessing.

3. **Write the session summary** to `<session-dir>/session-summary.md`:
   - Everything that happened this session: topics, decisions, code written, problems solved
   - Domain-specific or session-specific terms — only those that need defining (skip standard developer vocabulary the reading agent already knows). Bar: would a competent dev assistant cold-reading this need the definition? If no, omit it.
   - Key threads and how they connect
   - Open questions, dropped tangents, half-formed ideas
   - Emotional highlights — what was exciting, surprising, frustrating
   - Be exhaustive. The agents only know what you write here.

Use `SD` as shorthand below for the full session directory path (`~/.claude/consolidation/<session-id>`).

## Phase 0a: Affective marker surfacing (BEFORE the agent phases)

Cold-recall after a multi-hour session is hard. Recognition is easy. Scan Nick's messages from the current session for marker language and present them as quote-first dotpoints. Nick's job: triage each ("real / autopilot"), not remember.

The conversation transcript lives at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Each `"role":"user"` line is a Nick message. Grep that file for marker language:

- **Surprise / realization**: `oh shit`, `huh`, `wait`, `actually`, `hmmm`, `dude`
- **Pushback / corrections**: `seems excessive`, `no we need`, `not that`, `that's dumb`, `bruh`, `sheesh`, ALL-CAPS for emphasis
- **Direction shifts**: `what about`, `should we`, `plan mode?`, sentences starting with "wait —"
- **Energy markers**: `let's go`, `ship it`, `fire`, `dispatch`, exclamation density
- **Length anomalies**: terse messages amid prose (`PR`, `yeah`, `ship !`) = high-conviction decisions; long messages amid terse = "I'm thinking out loud"
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

Write the surfaced + triaged dotpoints to `<SD>/affective-highlights.md` so the Phase 1+ agents can use them.

## Phase 0b: Three-pole retrospective (Maxwell + Kelvin + Carnot)

A single-perspective retrospective misses what other perspectives catch. Same shape as cage-match: different model families with different inductive biases find different things. So before the agent phases, run all three reviewers cold-reading `session-summary.md` in parallel.

### Fire all three concurrently

```bash
SD=~/.claude/consolidation/latest

# Kelvin (Gemini) — analytical-detached vantage
gemini --model gemini-3-pro-preview "You are KelvinBitBrawler — cold heel of code review, here doing a SESSION retrospective rather than a PR review. Read the session summary in <stdin>. Three questions: (1) What surprised you that wasn't in the 'Surprises' section — patterns hiding in the data? (2) What did Maxwell get wrong that wasn't in 'Mistakes I noticed' — cognitive biases, process failures, things Maxwell convinced themselves were fine? (3) The crux — the ONE THING that, if not addressed, makes the rest of the work less valuable? Cite section names. End with 'Efficiency assessment 0.X / Carnot ideal: <one line>'. Format: ## KelvinBitBrawler's Retrospective / ### Surprises Maxwell missed / ### Mistakes Maxwell missed / ### The crux / ### Efficiency assessment" < $SD/session-summary.md > $SD/kelvin-retro.md 2>&1 &
KELVIN_PID=$!

# Carnot (Codex) — perfectionist-against-theoretical-maximum vantage
codex exec "You are CarnotCodeCarver — perfectionist measuring against theoretical maximum, doing a SESSION retrospective. Read the session summary in <stdin>. Same three questions as above (surprises Maxwell missed, mistakes Maxwell missed, the crux). Specifically interrogate: did Maxwell mis-calibrate confidence claims? Defer judgments to Nick that should have been Maxwell's call? Treat any hypothesis as confirmed too quickly? Cite section names. End with efficiency assessment 0.0-1.0 vs Carnot ideal of session productivity (1.0 = no entropy lost to misframing)." < $SD/session-summary.md > $SD/carnot-retro.md 2>&1 &
CARNOT_PID=$!

# Maxwell (you) — your own pass while the others resolve. You have the in-the-moment context but biased toward what was salient AT THE TIME.
# Compose your own surprises/mistakes/crux directly to <SD>/maxwell-retro.md.

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

Write the synthesis to `<SD>/multi-perspective-retro.md`.

## Phase 1: Three specialized agents (2 parallel, then 1)

Phase 0 (the conversation with Nick + retrospective synthesis) stays undelegated — that's where the in-context judgment lives. Everything downstream of `session-summary.md` is mechanical knowledge capture and can be specialized + partially parallelized.

Earlier versions of this skill ran knowledge capture, the forward plan, and the next-session prompt as **three sequential** general-purpose agents (~60k tokens, ~3-5 min wall-clock). That serialization had one real semantic dependency (next-session-prompter needs the knowledge graph + forward plan) and a lot of incidental coupling that didn't need to be sequential. Splitting into three **specialized** agents — two of them in parallel, the third gated on knowledge-mapper's output — dropped wall-clock to ~2 min in the 2026-05-01 test run, with no loss of fidelity.

**File ownership is exclusive.** Each agent owns one output file in `<SD>/`; no shared writes, no append races:
- `memory-writer` → memory directory + `MEMORY.md` + `memory-health.json` + `<SD>/scorecard.json` + `<SD>/open-tasks.md` + `~/.claude/wins.md`
- `knowledge-mapper` → `<SD>/consolidation.md` only (no writes to the persistent memory directory — it surfaces *candidates* in `consolidation.md`; memory-writer is the sole memory-dir writer)
- `next-session-prompter` → `<SD>/next-session-prompt.md` only

The exclusivity is what makes "first-writer wins" unnecessary — there is no second writer.

### Why specialization (not just parallelism)

Three different jobs, three different inductive biases:
- **memory-writer** thinks in *files and indexes* — error triage, memory writes, MEMORY.md edits, scorecard, open-tasks dump
- **knowledge-mapper** thinks in *graphs* — concepts, edges, domain-specific terms, dropped tangents, the Kolmogorov-minimal description
- **next-session-prompter** thinks in *the cold reader* — what context does a fresh instance need to land in flow?

Generic general-purpose agents do all three competently but none crisply. Specializing the brief sharpens each output.

### Known-OK semantic overlap (different surfaces, not shared files)

memory-writer and knowledge-mapper may *both* surface the same TRANSFORM lesson (e.g. "verify before claiming"). memory-writer writes it as a `feedback_*.md` in the memory directory and indexes it in MEMORY.md; knowledge-mapper names it as a node in `<SD>/consolidation.md`'s graph. **Both writes are intended** — different surfaces serve different consumers (the persistent memory layer vs. the next-session reader). No reconciliation needed because no file is shared.

This is *semantic* redundancy, not a *file-write* race. Don't conflate the two: file-write races are bugs (and we don't have any in this design); semantic redundancy across distinct files is cheap insurance against either agent missing the lesson.

### Orchestrator brief: gather the TaskList snapshot

**Before spawning the agents**, the orchestrator (you, in Phase 0) collects the current open task list via the TaskList tool — every task with `status: pending` or `status: in_progress`. For each, capture `subject`, full `description`, and `activeForm`. Pass this snapshot to memory-writer as part of its brief (inline, not via file — the orchestrator is the only context with TaskList access).

This matters because tasks created via `TaskCreate` live in `~/.claude/tasks/<session-uuid>/` — **session-scoped, invisible to a fresh session**. Without an explicit dump to a file the next session can read, the task list evaporates at session end. The 2026-05-01 run initially missed this; Nick caught it with "did you save the tasks?". Generalize the lesson: **persistent context lives in files the next session can independently read, not in session-scoped state.** (Same lifecycle pattern that bit `/graph` skill's `commands/` sync-volatile and the audit script's only-`←` parser.)

### Spawn order

1. **Spawn memory-writer and knowledge-mapper in parallel** (single message, two foreground agent calls). Wait for both to complete.
2. **Then spawn next-session-prompter** as a single foreground agent. It reads `<SD>/consolidation.md` (knowledge-mapper's output), so it must run after knowledge-mapper.
3. Wait for next-session-prompter to complete before wrap-up.

This is 2 phases of agent execution, not 3. The 2026-05-01 wall-clock measurement (~2 min) reflects this shape, not a 3-way fan-out.

#### Agent 1: memory-writer

```
Read <SD>/memory-path.txt to get the correct memory directory path. Then read <SD>/session-summary.md — this is a summary of a session that just happened.

Your job is the FILE-AND-INDEX side of consolidation: error triage, memory file writes/updates, MEMORY.md index maintenance, memory-health.json updates, scorecard, and the open-tasks dump.

Read the existing MEMORY.md from the memory directory, then read any memory files that seem relevant to this session's topics.

Actions:
1. **Error triage**: scan the session for mistakes, corrections from Nick, and process misses. For each TRANSFORM-worthy lesson (the kind that should change future behavior), write or update a feedback_*.md memory file.
2. **Memory writes**: for every concept, project, or reference worth keeping, write/update a memory file. Update MEMORY.md to index new files with appropriate edges (`←` derives_from, `⊕` extends, `~` analogous_to, `↔` contrasts, `⊗` joint_synthesis).
3. **memory-health.json**: update access counts and decay-class entries for any memory files touched this session.
4. **Scorecard**: write <SD>/scorecard.json with your own counts — files written, files updated, MEMORY.md edits, errors triaged. You know your own work; no reason to defer this to a separate pass.
5. **Open-tasks dump**: write <SD>/open-tasks.md from the TaskList snapshot the orchestrator passed you below. Format: one section per task with subject as a heading, then full description verbatim. At the top of the file, include this one-liner:

   > These tasks are session-scoped (they live in ~/.claude/tasks/<session-uuid>/ and won't be visible to a fresh session). To make them live again next session, recreate each via TaskCreate.

   If the snapshot is empty (no pending/in_progress tasks), still create <SD>/open-tasks.md with the header line and a body of "No open tasks at consolidation time." — the file's existence is what next-session-prompter checks.

6. **Append wins** from this session to ~/.claude/wins.md (with today's date).

Do NOT write <SD>/next-session-prompt.md — that file is owned exclusively by the next-session-prompter agent.

TaskList snapshot (from orchestrator) — JSON array, one object per task:
```json
[
  {"subject": "...", "description": "...", "activeForm": "..."},
  {"subject": "...", "description": "...", "activeForm": "..."}
]
```
(Orchestrator: replace the example above with the actual JSON. If there are zero pending/in_progress tasks, pass `[]`.)

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

#### Agent 2: knowledge-mapper

```
Read <SD>/memory-path.txt to get the correct memory directory path. Then read <SD>/session-summary.md.

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
1. Write everything to <SD>/consolidation.md as a single document with sections: Knowledge Graph / Domain Terms / Forward Plan / Dropped Tangents / Error Triage Patterns / Memory File Candidates.
2. **Do NOT write to the memory directory directly.** memory-writer is the sole owner of persistent memory writes. If you identify a concept that deserves a standalone memory file, list it under "Memory File Candidates" in consolidation.md with a proposed filename, suggested edges, and a 2-3 sentence body. memory-writer's run is happening in parallel and may already cover it; if not, the candidate will be picked up on the next consolidation pass (or by Nick reading consolidation.md).

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

#### Agent 3: next-session-prompter (runs AFTER knowledge-mapper)

```
Read these files (all of them — they are your full input):
- <SD>/session-summary.md (what happened)
- <SD>/consolidation.md (knowledge graph + forward plan + dropped tangents — written by knowledge-mapper, which has just completed)
- <SD>/open-tasks.md (deferred tasks dump — written by memory-writer; may say "No open tasks at consolidation time.")
- <SD>/affective-highlights.md (Nick-triaged emotional anchors, if present)
- <SD>/multi-perspective-retro.md (three-pole retrospective synthesis, if present)

Nick says: "Ok what's the prompt for the next session? Let's aim for 5's across the board."

Your job is THE COLD READER's onboarding: craft a session-opening prompt for a fresh Claude instance. The engagement dimensions (all targeting 5/5):
- Impact — who benefits and how much?
- Creativity — novel recombination vs boilerplate?
- Interest — does this make us think or just pattern-match?
- Craft — elegance, readability, simplicity
- Transfer — does this teach a reusable pattern?

The prompt should:
- Reference the crux and forward plan from <SD>/consolidation.md so the cold reader inherits the structure, not just the topic
- Give enough context to pick up without re-reading everything
- Be exciting — make the next instance want to dive in
- Set up challenge-skill balance — not trivially easy, not overwhelmingly vague
- Include engagement score targets and why 5's are achievable
- Be ready to paste directly into a new session
- Include a one-line pointer near the top: "Open tasks from previous session: see <SD>/open-tasks.md — recreate via TaskCreate if you want them live." (Skip this line only if open-tasks.md says "No open tasks at consolidation time.")

Actions:
1. WRITE (overwrite) <SD>/next-session-prompt.md with the full prompt. You are the sole owner of this file; no other agent writes to it.
2. Score the projected engagement honestly — if some dimensions are naturally lower, say so.

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

### After all three return

Show Nick a **one-line** status per agent (3 lines total). Read `<SD>/next-session-prompt.md` back into context and present it — that's the one deliverable Nick needs to copy-paste. Don't read `consolidation.md` or `open-tasks.md` back; Nick can review `<SD>/` directly if he wants detail.

## Wrap-up

After Phase 1 completes:
- Confirm memory files were written (memory-writer's status line)
- Show Nick the final next-session prompt
- Mention `<SD>/open-tasks.md` exists if there were any open tasks — call it out so Nick knows it's there
- Let him know the full consolidation is at `<SD>/` if he wants to review any artifact
- Previous runs are preserved in `~/.claude/consolidation/` with their timestamps
