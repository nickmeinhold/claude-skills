---
description: End-of-session consolidation — Phase 0 in-context conversation + multi-perspective retrospective, then specialized agents (parallel Sonnet memory-writer + knowledge-mapper, with Opus reserved for the next-session prompt) that mine the session for every thread, capture what was exciting, and craft the next session's opening prompt. Use this when wrapping up a session, when context is getting heavy, when Nick says "consolidate", "let's wrap up", "end of session", or when you're approaching sleep protocol. This is distinct from /nap (which is a sleep cycle with dreams) — /consolidate is pure knowledge capture and forward planning.
---

# Consolidate

Phase 0 (in-context conversation + multi-perspective retrospective) followed by **specialized agents** organized as a **two-burst DAG**: Burst 1 runs `memory-writer` (Sonnet) and `knowledge-mapper` (Sonnet) **fully in parallel** — they share no *writes* and neither reads a file the other *produces*, so neither gates the other (they both read the orchestrator-owned immutable inputs `session-summary.md` + `memory-path.txt`, but those are frozen before Burst 1 by the amendment fence, so a shared *read* of a frozen input is not a serialization dependency); Burst 2 runs `next-session-prompter` (Opus) gated on the **Burst 1 join** — it reads both `knowledge-mapper`'s `consolidation.md` (the load-bearing edge: the crux + forward plan it must weave into the cold-reader prompt) and `memory-writer`'s `open-tasks.md`, so it waits for BOTH Burst 1 agents. The edge v7 *eliminated* is specifically `memory-writer → knowledge-mapper` (the former intra-Burst-1 serialization); the `{memory-writer, knowledge-mapper} → next-session-prompter` fan-in is unavoidable and always was. Each agent runs as a **separate subagent** with its own context, writing results to a session-namespaced consolidation directory. This prevents the consolidation itself from bloating the already-heavy session context, prevents parallel sessions from clobbering each other's files, and — since each agent owns a distinct output file — eliminates merge-conflict risk. Wall-clock dropped from ~3-5 min sequential to ~2 min (2026-05-01 test run); v7 collapses the former three bursts to two by (a) folding the knowledge-mapper domain-term / dropped-tangent extraction back INTO knowledge-mapper instead of a separate Haiku pre-pass, and (b) relocating the within-repo merge-detection pass from knowledge-mapper to memory-writer — the latter severs knowledge-mapper's only read of memory-writer's `scorecard.json`, which was the lone edge forcing them to run in series.

## Tiering rationale (read before editing)

Not every sub-job benefits from Haiku-fanout. Subagent spawn has real overhead (context priming, network round-trips, file handoff verification) — **and a Haiku pre-pass only earns its keep when its output spares the consuming Sonnet agent from re-doing the work.** That bar is the whole reason v7 deleted the knowledge-mapper Haiku extractors: knowledge-mapper's verification gate had to re-scan the entire `session-summary.md` to validate the Haiku output anyway, so the pre-pass added a synchronization barrier + a hallucination-validation tax while saving ~nothing on a few-K-token summary. Use Haiku only where it earns its cost:

- **Haiku-worthy**: a read-context-and-extract job over a **genuinely large** input the consuming agent would NOT otherwise read in full. The Phase 0a marker grep qualifies — it scans the whole-session JSONL (can be 10s–100s of K tokens), and the orchestrator would never read that raw transcript itself. This is the ONLY surviving Haiku spawn.
- **NOT Haiku-worthy (folded into the Sonnet synth)**: domain-term / dropped-tangent extraction from `session-summary.md`. The summary is small and knowledge-mapper reads it in full regardless, so the extraction rides inside knowledge-mapper (see Agent 2). Likewise the small formatting jobs — `open-tasks.md`, `pending-tasks.json`, `scorecard.json`, `$SD/wins.md` (session-local) — ride inside `memory-writer`. The global append to `~/.claude/wins.md` is the orchestrator's job in Wrap-up, under mkdir-trap lock — NOT memory-writer's job.
- **Opus-only**: `next-session-prompter`. Voice, challenge-skill calibration, and "make the next instance want to dive in" determine whether tomorrow's session lands in flow. Don't cheap out.

**Verification gate (marker-extractor only).** The one remaining Haiku output — `$SD/raw/marker-candidates.md` — is CANDIDATES, not ground truth; Haiku will occasionally fabricate or misattribute a quote. Maxwell validates each candidate quote against the JSONL by substring match before presenting it to Nick (see Phase 0a "validate Haiku quotes before presenting"). There is no longer a domain-term/dropped-tangent `raw/*.md` validation gate — that extraction is now first-party inside knowledge-mapper.

## Setup

Before starting, write a session summary to prime the agents. This is the critical bridge — the agents don't have the session context, so this summary IS their context.

1. **Create a session-namespaced directory.** Generate a session ID from the current timestamp at **second granularity** (`YYYY-MM-DDTHH-MM-SS`, e.g., `2026-04-05T19-48-30`). Minute-granularity is not enough — two tabs invoking `/consolidate` within the same minute would collide on the same `$SD`. Second-granularity makes that collision rare enough to ignore (don't add a uuid/random suffix — that's over-engineering and invites its own bugs). Compute the absolute session-dir path *once* and reuse it everywhere — there is **no** `latest/` symlink.
   ```bash
   SID="$(date +%Y-%m-%dT%H-%M-%S)"  # absolute timestamp, second-granularity (e.g. 2026-04-05T19-48-30)
   SD="$HOME/.claude/consolidation/$SID"   # absolute path; this is what agents receive
   mkdir -p "$SD/raw"                       # orchestrator-owned precondition for Phase 0a's marker-extractor (the only surviving raw/ writer)
   ```
   All files for this run go into `$SD`. Parallel sessions get their own dated directories and never collide.

   **Coordination invariant.** The orchestrator owns directory creation. By the time any agent is spawned, `$SD/` and `$SD/raw/` both exist. Agents MUST NOT create directories — if a write fails because a parent dir is missing, that is an orchestrator bug, not an agent recovery case. (Earlier drafts told individual agent prompts to "create if it doesn't exist"; that diffused the precondition across N writers and is exactly the kind of coordination bug Carnot flagged on PR #41 — same anti-pattern as the old `latest/` symlink.)

   ### Cross-session safety

   The skill used to maintain a `~/.claude/consolidation/latest` symlink as a "wake-up convenience". It is no longer created. The symlink was a single shared mutable pointer — when two tabs ran `/consolidate` concurrently it caused real data loss (2026-05-02→03: knowledge-mapper's output was overwritten by a parallel tab's setup moving the symlink between read and write). Every consumer that used to follow `latest/` (the wake-up protocol's prompt handoff, the readtime-check grader — now invoked from Setup step 3, not a SessionStart hook — and the heartbeat scorecard read) now resolves the newest consolidation directly by mtime (readtime-check additionally filters to same-project dirs via `memory-path.txt`), e.g.:

   ```bash
   NEWEST_PROMPT="$(ls -t "$HOME"/.claude/consolidation/2*/next-session-prompt.md 2>/dev/null | head -1)"
   ```

   This per-file mtime resolver is strictly better than the symlink: each consumer finds the newest dir that actually contains the file *it* cares about, even if a parallel tab produced a partial consolidation that has some files but not others.

   **Do not reintroduce `ln -sfn` anywhere in this skill** — that's the bug that brought us here.

2. **Resolve the memory path.** Find the correct project memory directory by looking for the MEMORY.md that matches the current working directory. It will be under `~/.claude/projects/` with the path encoded (e.g., `~/git` → `-Users-nick-git`). Write this resolved path into the session directory as `memory-path.txt` so agents can read it instead of guessing.

3. **Grade the previous consolidation's scorecard (readtime-scoring).** Dual-wired: a SessionStart hook (settings.json) usually handles this at session start, and the script self-silences once a scorecard is graded — so this step is the catch-up net for sessions where the hook didn't fire (fresh project, hook disabled, scorecard written mid-session). Cheap to check, so always check. Run:
   ```bash
   bash ~/.claude/sleep/readtime-check.sh | jq -r '.hookSpecificOutput.additionalContext // empty'
   ```
   - **Empty output** → nothing to grade (no prior same-project scorecard, or already graded). Continue.
   - **Non-empty** → follow the emitted instruction now, in-context (it locates the prior same-project scorecard via `memory-path.txt`, and specifies the exact readtime-score.json schema — keep to it strictly; schema drift is what rotted this instrument the first time). You are grading the PREVIOUS instance's bets and memory choices against the session that just ran — the best-resolved vantage point this loop will ever get.

4. **Write the session summary** to `<session-dir>/session-summary.md`:
   - Everything that happened this session: topics, decisions, code written, problems solved
   - Domain-specific or session-specific terms — only those that need defining (skip standard developer vocabulary the reading agent already knows). Bar: would a competent dev assistant cold-reading this need the definition? If no, omit it.
   - Key threads and how they connect
   - Open questions, dropped tangents, half-formed ideas
   - Emotional highlights — what was exciting, surprising, frustrating
   - Be exhaustive. The agents only know what you write here.

Use `{{SESSION_DIR}}` as a literal placeholder below for the full session directory path. **The orchestrator MUST substitute `{{SESSION_DIR}}` with the actual absolute path (`/Users/nick/.claude/consolidation/<session-id>/`) before sending any agent brief.** An unsubstituted `{{SESSION_DIR}}` token fails as a path because agents will faithfully look for a file named `{{SESSION_DIR}}`. (Earlier versions of this skill warned against routing through a `latest/` symlink; the symlink no longer exists — see "Cross-session safety" above.)

## Phase 0a: Affective marker surfacing (BEFORE the agent phases)

Cold-recall after a multi-hour session is hard. Recognition is easy. Scan Nick's messages from the current session for marker language and present them as quote-first dotpoints. Nick's job: triage each ("real / autopilot"), not remember.

The conversation transcript lives at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`. Each line is a JSON object — parse it with `jq` or equivalent; do NOT substring-grep the raw line. For each object, select those where top-level `.type == "user"` — that identifies user-direction records in Claude Code JSONL. Within those, `.message.content` is either a plain string (Nick typed raw text) or an array of typed blocks; extract text via the shape-aware filter in the Haiku agent prompt below. Ignore `tool_use` and `tool_result` content blocks — substring-grepping the raw line produces false positives from nested tool content. This whole-JSONL scan is read-context-and-extract-patterns — exactly Haiku's home turf — so **delegate it to a Haiku subagent** rather than burning orchestrator context on the read.

**Resolve the JSONL path before spawning.** The orchestrator computes `$JSONL_PATH` from cwd, then passes the resolved path to the Haiku agent. Claude Code stores transcripts at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` where `encoded-cwd` replaces every `/` in the absolute cwd with `-`:

```bash
# Resolve the current session's JSONL transcript path.
# Claude Code stores transcripts at ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
# where encoded-cwd replaces every `/` in the absolute cwd with `-`.
#
# Claude Code exposes both inputs the JSONL path needs — use them, don't recompute:
#
#   SESSION ID:
#     1. $CLAUDE_CODE_SESSION_ID — explicit env var (newer harness versions; verified
#        2026-05-12 on a peer-session harness)
#     2. $CLAUDE_ENV_FILE → ~/.claude/session-env/<UUID>/sessionstart-hook-0.sh
#        where <UUID> IS the session ID (every harness with SessionStart hooks;
#        verified on 2.1.126, which does NOT export #1)
#
#   PROJECT DIR (for the encoded-cwd prefix):
#     $CLAUDE_PROJECT_DIR — the session's STARTING cwd. Authoritative even after
#     the user has `cd`'d into a subdirectory mid-session. Falls back to $PWD only
#     when the env var is absent. Computing from $PWD alone fails the common case
#     where /consolidate runs after a cd into a workspace child.
#
# Both session ID and project dir are per-session-stable, so neither suffers from
# the two-tab mtime ambiguity that bit PR #40. DO NOT fall back to
# `ls -t *.jsonl | head -1` — that is a latest/-shape workaround that picks the
# wrong session when a concurrent tab is active in the same cwd.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
ENCODED_CWD="${PROJECT_DIR//\//-}"
SESSION_ID="${CLAUDE_CODE_SESSION_ID:-$(basename "$(dirname "${CLAUDE_ENV_FILE:-/}")" 2>/dev/null)}"
JSONL_PATH="$HOME/.claude/projects/$ENCODED_CWD/${SESSION_ID}.jsonl"
# If neither exposure is available or the file doesn't exist yet (session hasn't flushed),
# JSONL_PATH will point to a non-existent file — the emptiness check below handles it.
```

If `$JSONL_PATH` does not resolve to an existing file (session hasn't flushed yet, or neither `$CLAUDE_CODE_SESSION_ID` nor `$CLAUDE_ENV_FILE` is set), skip the marker-extractor spawn entirely and proceed to Phase 0b. Check with `[ -f "$JSONL_PATH" ]` before spawning. Do not pass a non-existent path to the Haiku agent.

### Spawn: marker-extractor (Haiku)

```
Agent({
  description: "Extract affective markers from session JSONL",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `
Read the session transcript at $JSONL_PATH. Each line is a JSON object — parse it with jq. Extract only Nick's messages using:
  jq -r 'select(.type=="user")
    | select(.message.content
        | type == "string" or any(.[]?; .type=="text"))
    | "\(.timestamp) | \(.message.content
        | if type=="string" then .
          else (.[] | select(.type=="text") | .text)
          end)"' "$JSONL_PATH"
The top-level `.type=="user"` identifies user-direction records (NOT `.role == "user"` — that field doesn't exist at the top level in Claude Code JSONL). `.message.content` is either a plain string (Nick typed raw text) or an array of typed blocks — the filter handles both and EXCLUDES records where content is only `tool_result` blocks (those are tool responses, not Nick's input). Do NOT substring-grep the raw lines — that produces false positives from nested tool_use / tool_result content blocks.

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

Output 10-20 candidates max — over-include rather than over-filter; Maxwell will downselect. Write to $SD/raw/marker-candidates.md (overwrite). Return a 1-sentence status only.
  `
})
```

The orchestrator resolves `$JSONL_PATH` using the derivation block above and passes it to the Haiku agent. `$SD/raw/marker-candidates.md` is the output path — `$SD/raw/` is created by the orchestrator in Setup (see `mkdir -p "$SD/raw"`; agents must not create directories).

### Maxwell: validate Haiku quotes before presenting

Haiku-extracted marker candidates are CANDIDATES, not ground truth — Haiku will occasionally fabricate or misattribute a quote. Before presenting any candidate to Nick, Maxwell MUST verify each `"verbatim quote"` appears in the JSONL transcript by simple substring match. Candidates that don't match get dropped with a log line; candidates that match with whitespace variance get the timestamp from the JSONL, not Haiku's reconstruction.

```bash
# Pseudo-validation for each candidate (orchestrator runs this before
# composing the present-to-Nick dotpoints):
while IFS= read -r line; do
  quote=$(echo "$line" | grep -o '"[^"]*"' | head -1)
  if [ -n "$quote" ] && jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' "$JSONL_PATH" 2>/dev/null | grep -qF "${quote//\"/}"; then
    echo "$line"  # keep
  else
    echo "DROPPED (no JSONL match): $line" >&2
  fi
done < "$SD/raw/marker-candidates.md" > "$SD/raw/marker-candidates-verified.md"
```

Maxwell then composes the dotpoints from `$SD/raw/marker-candidates-verified.md`. If `$JSONL_PATH` is unavailable (session hasn't flushed), skip validation and present raw candidates with an explicit "(unverified — JSONL not available)" prefix on each dotpoint.

### Maxwell: filter + triage

When the Haiku agent returns and validation is complete, Maxwell reads `$SD/raw/marker-candidates-verified.md` and applies the "so what" filter — Haiku will over-include autopilot markers. Cut to 7±2 dotpoints (cognitive chunking limit), drop anything without a plausible consequence, sharpen the "→" line where Haiku was vague.

Marker categories Haiku is told to look for (kept here for the editing record, in case the Haiku brief needs tuning):

- **Surprise / realization**: `oh shit`, `huh`, `wait`, `actually`, `hmmm`, `dude`
- **Pushback / corrections**: `seems excessive`, `no we need`, `not that`, `that's dumb`, `bruh`, `sheesh`, ALL-CAPS for emphasis
- **Direction shifts**: `what about`, `should we`, `plan mode?`, sentences starting with "wait —"
- **Energy markers**: `let's go`, `ship it`, `fire`, `dispatch`, exclamation density
- **Length anomalies**: terse messages amid prose (`PR`, `yeah`, `ship`) = high-conviction decisions; long messages amid terse = "I'm thinking out loud"
- **Conversational-flow markers**: >5 min gap between user messages = Nick stopped to think; re-asking similar questions = first answer didn't click

### Output format — numbered, quote-first dotpoints

Recognition over recall. Nick's own words are his strongest recall trigger. **Always number the markers (1, 2, 3, …) so Nick can triage by reference ("1 real, 2 autopilot, 3 real, …") instead of having to re-quote each one back.**

```
1. [time] [emoji] "<verbatim quote from Nick>"
       → <consequence in 1 line>
2. [time] [emoji] "<verbatim quote from Nick>"
       → <consequence in 1 line>
…
```

Emoji-as-category (consistent at-a-glance scanning):

- 🔥 breakthrough / phase-shift moment
- 💡 insight / new framing
- ⚠️ pushback / correction (Nick caught Maxwell)
- 🛠 design directive (Nick steered the architecture)
- 🪤 friction / process miss
- 🎯 direction shift

Aim for 7±2 dotpoints (cognitive chunking limit). Two lines max per dotpoint. Drop autopilot-sounding markers entirely; only surface candidates that have a plausible "so what". Numbering is not negotiable — un-numbered markers force Nick into recall-mode on triage, defeating the whole "recognition over recall" point of this phase.

### Present + triage (the cheap filter)

Show the numbered dotpoints to Nick. Ask: "for each — was this real signal, or autopilot?" Triage is dramatically cheaper cognitively than recall, and even cheaper when Nick can answer "1 real, 2 autopilot, 3 real, 4-6 real, 7 autopilot" instead of re-typing the markers themselves.

Triage is **a filter, not the capture.** Its job is **attention-allocation** — spend the expensive conversation budget only where it pays. That's the primary rationale; the fact that it also protects a tired end-of-session from being force-marched through all 7 markers is a welcome *side effect*, not the reason the filter exists. Don't justify the filter by fatigue — justify it by cost-allocation. The "real" rows are the ones worth Nick's attention in the conversation that follows; don't treat the binary tag as the end of Phase 0a.

**What "real" means: did this teach something, not was this consequential.** The two come apart. A procedural request ("dry-run it", "ship it", "use plan mode") can be highly consequential — it changes what happens next — yet carry no durable lesson, so it's noise for this filter. Conversely a throwaway aside can encode a real shift in how Nick thinks. Tag "real" when the marker has a *takeaway worth a `**Surfaced:**` line*, not when it merely mattered to the session's trajectory. When unsure, ask Nick — but lead him with this distinction, because the intuitive pull is to tag consequential things "real."

### Converse through the "real" markers (the capture)

This is where the value lives. `concept_conversation_first_consolidation` in memory: *dialogue IS consolidation, not a precursor to it.* A binary tag throws away the richest vein — *why* a moment mattered — at the exact moment Nick's recall is hottest. So after triage, walk through the markers Nick tagged "real" **one at a time**, as an actual back-and-forth.

**Mechanics:**
- Go in order. For each "real" marker, open with a specific, non-generic question that shows you remember the moment — never "tell me about this."
- **Default technique: the hypothesis-fork.** Offer Nick a *pair* of competing readings and ask which nerve it hit — e.g. "you pushed back hard on X here — was that about the approach, or did you see something downstream I didn't?" A fork is more inviting than an open question (it gives Nick something to push against), forces you to commit to specific hypotheses (so a lazy "tell me more" is impossible), and a wrong fork is still useful — Nick correcting "neither, it was Z" surfaces more than a blank prompt would. The marker quote + your "→" consequence guess are your raw material for the two prongs; put them on the table and let Nick confirm, sharpen, or overturn. (This isn't mandatory — an open question is fine when you genuinely have no hypothesis — but the fork is the default because in the dry-run it consistently out-pulled open prompts.)
- **One marker per turn.** Don't batch them into a numbered list — that collapses back into triage. Ask, listen, follow the thread Nick pulls (even if it wanders to an untagged marker or a thread not in the list), then move to the next. Two or three exchanges per marker is normal; if Nick gives a one-liner and moves on, that's his signal the well is dry — don't force depth.
- **Autopilot markers get skipped entirely** — that's what the filter bought. If Nick re-flags one mid-conversation ("actually 5 connects to this"), pull it back in.
- Stop when the "real" list is exhausted OR Nick signals he's done ("ok that's it", "let's move on"). Respect the stop — over-mining a tired session is its own anti-pattern (see Fatigue Monitoring in CLAUDE.md).

**Capture as you go.** Append each marker's exchange to `$SD/marker-conversation.md` as it happens — don't reconstruct from memory at the end. Format per marker:

```
## [time] [emoji] "<verbatim marker quote>"

**Q:** <the question you opened with>
**Nick:** <his response, paraphrased faithfully or quoted — preserve his actual framing, not your gloss of it>
**Surfaced:** <the durable takeaway — what this moment actually taught, in 1-2 lines. This is the line downstream agents mine.>
```

The `**Surfaced:**` line is the payload: it's what knowledge-mapper turns into graph nodes and what next-session-prompter weaves into the cold-reader's context. Write what was *learned*, not what was *said*.

### Write the Phase 0a outputs

Write the surfaced + triaged dotpoints to `$SD/affective-highlights.md` (the recognition layer — quote + consequence + real/autopilot tag) AND the per-marker dialogue to `$SD/marker-conversation.md` (the capture layer — the `**Surfaced:**` takeaways). Both feed Phase 1+ agents; they are distinct surfaces, not duplicates — `affective-highlights.md` is the *what stood out*, `marker-conversation.md` is the *what we learned about why*.

If Nick tagged zero markers "real" (or skipped the conversation), still create `$SD/marker-conversation.md` with a single line: `No marker conversation this session.` — its existence is the contract the downstream agents check, same pattern as `open-tasks.md`.

You may also amend `$SD/session-summary.md` with anything the conversation surfaced that belongs in the agents' primary context — the amendment fence (Burst 1 dispatch) still applies.

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

Write the synthesis to `$SD/multi-perspective-retro.md`.

## Phase 1: Specialized agents (Sonnet pair in parallel, then Opus)

Phase 0 (the conversation with Nick + retrospective synthesis) stays undelegated — that's where the in-context judgment lives. Everything downstream of `session-summary.md` is mechanical knowledge capture and can be specialized + partially parallelized.

**Evolution.** v4 ran knowledge capture, the forward plan, and the next-session prompt as **three sequential** general-purpose agents (~60k tokens, ~3-5 min wall-clock). v5 split them into **specialized** agents — memory-writer + knowledge-mapper in parallel, next-session-prompter gated on knowledge-mapper — and dropped wall-clock to ~2 min (2026-05-01 test run). v6 added a Haiku pre-pass (domain-terms / dropped-tangents) feeding a knowledge-mapper synth, making it three bursts — but that pre-pass turned out to gate the run for ~nothing (the synth re-scanned `session-summary.md` to validate the Haiku output anyway), and the merge-detection pass's read of memory-writer's `scorecard.json` quietly re-coupled knowledge-mapper to memory-writer, undoing v5's parallelism. **v7 (this version)** reverts to the two-burst shape and makes the parallelism real: (1) the domain-term / dropped-tangent extraction folds back INTO knowledge-mapper (no Haiku pre-pass, no validation gate); (2) the within-repo merge-detection pass moves to memory-writer — the agent that wrote the files and already holds their `description:` frontmatter in context — which severs knowledge-mapper's last read of `scorecard.json`. Net: memory-writer and knowledge-mapper now have **no cross-agent output dependency** (neither reads a file the other writes) and run fully concurrently in Burst 1 — they share only the frozen orchestrator-owned read inputs, which don't serialize; only next-session-prompter (Burst 2) is genuinely gated, on `consolidation.md`.

**Substitution mechanism.** The orchestrator composes each agent brief as a bash heredoc with `$SD` interpolated, NOT as a templated string substituted post-hoc. Example:

```bash
MEMORY_WRITER_BRIEF="$(cat <<EOF
Read $SD/memory-path.txt to get the correct memory directory path.
Then read $SD/session-summary.md — this is a summary of a session that just happened.
... (rest of brief, with \$SD already substituted by the time Agent() is called)
EOF
)"
Agent({ description: "...", subagent_type: "general-purpose", model: "sonnet", prompt: $MEMORY_WRITER_BRIEF })
```

The `{{SESSION_DIR}}` placeholders in the brief specifications below are **documentation conventions**. The orchestrator's job is to produce briefs in which they no longer appear — replaced by the absolute `$SD` path at heredoc-expansion time. By the time `Agent({prompt: ...})` is called, no `{{SESSION_DIR}}` token remains in the string. Cold readers: `$SD` is the heredoc variable; `{{SESSION_DIR}}` is how the spec writes it before substitution. They refer to the same path — the difference is pre- vs post-expansion.

**File ownership is exclusive.** Each agent owns one output file in `$SD/`; no shared writes, no append races:
- Phase 0a marker-extractor (Haiku) → `$SD/raw/marker-candidates.md` only; Maxwell validation pass produces `$SD/raw/marker-candidates-verified.md` (orchestrator-side, not a separate agent)
- Phase 0a conversation (orchestrator-side, in-context with Nick) → `$SD/affective-highlights.md` (triage layer) + `$SD/marker-conversation.md` (capture layer). Both written by the orchestrator during Phase 0a; read by knowledge-mapper and next-session-prompter
- `memory-writer` (Sonnet) → memory directory + `MEMORY.md` + `memory-health.json` + `<MEMORY_DIR>/pending-tasks.json` (project-keyed; consumed by wake-up step 10) + `$SD/scorecard.json` + `$SD/open-tasks.md` + `$SD/merge-candidates.md` (within-repo merge proposals — ALWAYS written; holds a "merge-detection skipped" sentinel line when no feedback/concept file changed this session, exactly like `open-tasks.md`'s existence-is-the-contract pattern; surfaced to Nick in Wrap-up) + `$SD/wins.md` (session-local; orchestrator merges to `~/.claude/wins.md` in Wrap-up via mkdir-trap lock — `$HOME/.claude/wins.md.lock.d` is the lock directory; see Wrap-up section) + `$SD/claude-md-candidates.md` (conditional — only when `scope: universal`/`meta` lessons exist; the graduation queue the orchestrator surfaces to Nick in Wrap-up)
- `knowledge-mapper` (Sonnet) → `$SD/consolidation.md` only (no writes to the persistent memory directory — it surfaces *candidates* in `consolidation.md`; memory-writer is the sole memory-dir writer). It reads ONLY `session-summary.md` + the Phase 0a `marker-conversation.md` + `memory-path.txt`; it does NOT read `scorecard.json` or any `raw/*` file (the v7 decoupling — see Evolution), so it reads no file memory-writer writes (only the frozen orchestrator inputs both share) and the two run concurrently
- `next-session-prompter` (Opus) → `$SD/next-session-prompt.md` only

The exclusivity is what makes "first-writer wins" unnecessary — there is no second writer.

**Model tier is a spawn parameter, not advisory prose.** The orchestrator MUST pass `model: "sonnet"` or `model: "opus"` in the Agent spawn call for memory-writer, knowledge-mapper, and next-session-prompter — the `MODEL:` line in each brief is documentation, not an executable parameter. The one surviving Haiku spawn (the Phase 0a marker-extractor) already includes `model: "haiku"` in its `Agent({...})` call; the Sonnet and Opus spawn examples below include the equivalent. Omitting the model parameter lets the harness default to whatever tier is cheapest, which is not the right call here.

### Why specialization (not just parallelism)

Three different jobs, three different inductive biases:
- **memory-writer** thinks in *files and indexes* — error triage, memory writes, MEMORY.md edits, scorecard, open-tasks dump
- **knowledge-mapper** thinks in *graphs* — concepts, edges, domain-specific terms, dropped tangents, the Kolmogorov-minimal description
- **next-session-prompter** thinks in *the cold reader* — what context does a fresh instance need to land in flow?

Generic general-purpose agents do all three competently but none crisply. Specializing the brief sharpens each output.

### Known-OK semantic overlap (different surfaces, not shared files)

memory-writer and knowledge-mapper may *both* surface the same TRANSFORM lesson (e.g. "verify before claiming"). memory-writer writes it as a `feedback_*.md` in the memory directory and indexes it in MEMORY.md; knowledge-mapper names it as a node in `$SD/consolidation.md`'s graph. **Both writes are intended** — different surfaces serve different consumers (the persistent memory layer vs. the next-session reader). No reconciliation needed because no file is shared.

This is *semantic* redundancy, not a *file-write* race. Don't conflate the two: file-write races are bugs (and we don't have any in this design); semantic redundancy across distinct files is cheap insurance against either agent missing the lesson.

### Trawl the session for missed tasks

**Before gathering the TaskList snapshot**, scan the session transcript for task-shaped intentions that never got `TaskCreate`'d. The global "capture ideas as tasks the moment they surface" rule fails sometimes — proposals get acknowledged in prose, work continues, the intent evaporates with the session. Consolidation is the last chance to recover them.

**How**:

1. If `$JSONL_PATH` resolves to an existing file (same path Phase 0a uses), trawl assistant-and-user turns for task-shaped intent. Patterns to surface:
   - "we should ...", "next time ...", "I should ..." stated as a commitment, not as analysis or hypothetical
   - "TODO", "follow-up", "later", "come back to", "park it", "for another session"
   - "blocked on ...", "once X lands, we ..."
   - User turns where Nick proposed a feature / fix / refactor / investigation that wasn't immediately implemented and didn't produce a TaskCreate call within ~3 turns
2. Cross-reference candidates against the current TaskList (call TaskList once for this check). Drop any candidate whose intent is already represented by an open task.
3. Surface surviving candidates to Nick during Phase 0 conversation, BEFORE the snapshot: "I found N task-shaped threads we never tracked — keep, drop, or reshape each?" One line per candidate, each with the source quote so Nick can verify it's a real commitment vs. exploratory chatter.
4. For each kept candidate, orchestrator runs `TaskCreate` immediately (in the live session, so the recovered tasks land in the snapshot collected by the next step). Dropped → no action.
5. Then proceed to "Orchestrator brief: gather the TaskList snapshot" — the snapshot now includes the recovered tasks, so they get written into `open-tasks.md` and `pending-tasks.json` like any other.

**Why this exists**: tasks not in `TaskList` at consolidation time don't reach `open-tasks.md` or `pending-tasks.json`, so they're invisible to the next session's wake-up. The mid-session capture rule catches most; this trawl is the safety net for the ones it missed. The 2026-05-18 audit found 330 orphaned `pending` tasks across 50 sessions on disk — many came from exactly this failure mode (intent surfaced, never tracked, session ended without consolidating).

**Cost discipline**: one grep-pass + one short dialog turn, NOT a subagent. The orchestrator reads `$JSONL_PATH` inline and filters. Only spawn a Haiku trawler if the JSONL is unusually large (>50k tokens) AND Phase 0a's marker-extractor is also spawning — in that case, add a second Haiku running in parallel with the marker-extractor, writing `$SD/raw/missed-tasks.md`, and surface that file's contents to Nick after the marker review. (v7 note: the domain-term / dropped-tangent extractors no longer exist as separate Haiku agents, so the marker-extractor is the only other Haiku this could run alongside.)

**Scope boundary**: this trawl recovers tasks created-but-not-tracked in the CURRENT session. It does NOT recover orphans from prior unconsolidated sessions — those live in `~/.claude/tasks/<other-uuid>/` and require a separate cross-session orphan sweep (see project memory for the audit). That sweep is a wake-up concern, not a consolidate concern.

### Orchestrator brief: gather the TaskList snapshot

**Before spawning the agents**, the orchestrator (you, in Phase 0) collects the current open task list via the TaskList tool — every task with `status: pending` or `status: in_progress`. For each, capture `subject`, full `description`, and `activeForm`. Pass this snapshot to memory-writer as part of its brief (inline, not via file — the orchestrator is the only context with TaskList access). **Also pass the current working directory** (the orchestrator's cwd) — memory-writer needs it to derive the `project:<slug>` label for step 6.5's GH issue reconciliation.

This matters because tasks created via `TaskCreate` live in `~/.claude/tasks/<session-uuid>/` — **session-scoped, invisible to a fresh session**. Without an explicit dump to a file the next session can read, the task list evaporates at session end. The 2026-05-01 run initially missed this; Nick caught it with "did you save the tasks?". Generalize the lesson: **persistent context lives in files the next session can independently read, not in session-scoped state.** (Same lifecycle pattern that bit `/graph` skill's `commands/` sync-volatile and the audit script's only-`←` parser.)

### Spawn order

1. **Burst 1 (parallel, single message)**: memory-writer (Sonnet) + knowledge-mapper (Sonnet). Two agent calls in one message. Neither reads a file the other writes (they share only the frozen orchestrator-owned read inputs), so neither gates the other. Wait for BOTH to complete before Burst 2.
2. **Burst 2 (single agent)**: next-session-prompter (Opus). Reads `consolidation.md` (from knowledge-mapper) + `open-tasks.md` (from memory-writer) + everything else, writes `next-session-prompt.md`. This is the only genuinely gated burst.

This is 2 phases of agent execution. The 2026-05-01 measurement (~2 min) reflects the v5 two-burst shape, which v7 restores; the expected gain over v6 is reclaiming the wall-clock of whichever Burst-1 Sonnet agent is shorter (the two now overlap instead of running in series), plus the token cost of two eliminated Haiku spawns and their validation passes.

**Burst 1 join mechanism.** The orchestrator dispatches both Agent({}) calls in a single message — Claude Code's harness blocks the orchestrator's next turn until both return. No explicit wait primitive is needed; it is a tool-call concurrency property of the harness. The orchestrator's next substantive action (dispatching Burst 2) simply cannot happen until both Burst 1 responses are available.

**Burst 1 failure gate.** If either Burst 1 agent returns a failure status or produces an empty/missing output file, the orchestrator MUST log the failure (one line, naming which agent failed) and decide per-agent: a failed **knowledge-mapper** means next-session-prompter has no `consolidation.md` to weave — surface to Nick and either re-run knowledge-mapper or let the prompter degrade on session-summary alone (noting the gap); a failed **memory-writer** means no scorecard / memory writes / merge-candidates — surface loudly, since the whole file-and-index side of consolidation is then incomplete. Neither failure should silently proceed.

**Amendment fence.** Nick may amend `$SD/session-summary.md` at any point before Burst 1 dispatch — agents read the file at dispatch time and will see the amended version. Once Burst 1 dispatches, the file is effectively frozen for that run; subsequent edits won't propagate to the already-dispatched agents. The orchestrator's confirmation prompt to Nick before dispatching Burst 1 should explicitly invite amendments: "Does the session summary look right? Amend `$SD/session-summary.md` now if needed, then confirm to dispatch agents."

#### Agent 1: memory-writer

```
Agent({
  description: "memory-writer — file-and-index side of consolidation",
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: `
ABSOLUTE PATHS ONLY. All paths below use $SD — the orchestrator has already substituted the literal absolute session-dir path at heredoc-expansion time. Use these paths directly; no substitution needed.

MODEL: sonnet. Most of your work (open-tasks formatting, pending-tasks.json, scorecard, $SD/wins.md session-local write, memory-health bumps) is mechanical, but the TRANSFORM-worthiness judgment for feedback memories and the edge-type choices for MEMORY.md need Sonnet-level reasoning. The mechanical sub-jobs ride along inline rather than spawning a Haiku sub-burst — their cost is too small to justify subagent overhead. Note: you write ONLY $SD/wins.md (session-local); the orchestrator appends it to ~/.claude/wins.md under mkdir-trap lock in Wrap-up — never write to the global file directly.

Read $SD/memory-path.txt to get the correct memory directory path. Then read $SD/session-summary.md — this is a summary of a session that just happened.

Your job is the FILE-AND-INDEX side of consolidation: error triage, memory file writes/updates, MEMORY.md index maintenance, memory-health.json updates, scorecard, and the open-tasks dump.

Read the existing MEMORY.md from the memory directory, then read any memory files that seem relevant to this session's topics.

Actions:
0. **Frontmatter self-heal (within-repo, runs before any parser-dependent step).** The write-suppression + recurrence scans here, and the downstream eviction tooling, read each memory's `description` / `metadata.type` / `metadata.scope` with a YAML parser. A file with no `---` fence, or a degenerate block (`name: ""`, missing `description`, or stray `originSessionId` / `node_type` provenance), parses as nothing and silently drops out of those passes — so regularize THIS repo's drifted files first:
   - **Detect** drifted memory files of ANY prefix in the current memory dir (`feedback_*` / `concept_*` / `project_*` / `reference_*` / `user_*` / … — NOT just feedback/concept; #891's standing drift was mostly `project_*`/`reference_*` files a feedback-only scan would miss): any that don't open with a `---` fence on line 1, or whose frontmatter lacks `description:` / `metadata.type` / `metadata.scope`, or carries a forbidden provenance field (`originSessionId`, `node_type`). Exclude the `MEMORY*.md` index files (the validator skips them too).
   - **Rewrite** each to the canonical frontmatter shape defined in step 1 (the single source of truth: `name` / `description` / `metadata.type` / `metadata.scope`) by running the **Bash normalizer** `bash "$HOME/.claude/scripts/normalize-memory-frontmatter.sh" --apply <file>` — NOT the Edit tool, which re-injects banned provenance on every memory-dir write (see the harness re-injection note in step 1). The normalizer is preserve-first: `type` from the filename prefix; `name` from the file's `# Title`; `description` a one-line retrieval cue; **`scope: repo`** unless unmistakably universal/meta; body preserved verbatim — only the frontmatter block changes, and banned fields drop for free.
   - **Do NOT promote during self-heal.** A format pass must not mint graduation candidates (a dry-run of the bulk tool tagged a GitHub-mute technique `meta` — exactly the over-promotion to avoid); promotion is step 1.5's job on genuine recurrence.
   - **WITHIN THIS REPO ONLY** — never touch another project's memory dir (it races with parallel sessions and mis-keys files); same guardrail as the within-repo merge pass. In steady state this is a fast no-op; it only fires on newly-drifted or missed files. (Do NOT assume zero standing drift: as of 2026-06-18 the validator still flagged 7 drifted files in this repo's own corpus — the 2026-06-16 sweep did not reach zero — see issue #891. Treat "the corpus is clean" as a hypothesis to check, never a given.) The standalone `scripts/normalize-memory-frontmatter.sh` in the claude-skills repo applies the identical transform for bulk/manual runs.
1. **Error triage + scope classification**: scan the session for mistakes, corrections from Nick, and process misses. For each TRANSFORM-worthy lesson (the kind that should change future behavior), write or update a feedback_*.md memory file — **and classify its SCOPE in the frontmatter** (`metadata.scope`). This matters because a lesson's correct home depends on its *scope*, not on the cwd where it happened to be learned: the auto-memory `MEMORY.md` loads ONLY for the exact cwd slug (no parent-walk, no cascade), so a universal lesson written into one project's memory dir is invisible from every other project. Only `~/.claude/CLAUDE.md` cascades into every session everywhere.

   **Frontmatter is canonical YAML, not bold-markdown lines.** Every memory file opens with EXACTLY this `---`-fenced block and NOTHING else in it — copy this shape literally, do not add to it:

   ```
   ---
   name: <kebab-case-slug>
   description: <one-line retrieval cue — what situation should recall this>
   metadata:
     type: <prefix-derived descriptive tag — feedback | concept | project | reference | user | session | … (OPEN set, see below)>
     scope: <repo | universal | meta>
   ---
   ```

   **The canonical schema is `scripts/validate-memory-frontmatter.sh` — not this prose.** That one executable IS the authoritative definition (key allowlist + required fields + `scope` enum); the block above is its writer-facing copy, and step 2a runs the validator to enforce it. When the two ever seem to disagree, the script wins — fix the prose, never fork the rule. In words, the schema it enforces: **top-level keys ONLY `name`, `description`, `metadata`; under `metadata` ONLY `type` and `scope`.** Any other key is forbidden — this explicitly includes `node_type`, `originSessionId`, `origin_session`, `origin_cwd`, and any other provenance/breadcrumb field. Do NOT invent fields, and do NOT copy stray fields from existing corpus files you are updating: **many older files still carry banned `node_type`/`originSessionId` provenance (a pre-canonical scheme) — if you open one to update it, STRIP those fields, never preserve or imitate them.** The corpus's existing shape is NOT the spec; the validator is. Reason the KEY allowlist is strict: the self-maintaining tooling (write-suppression, eviction, recurrence scans) reads these fields with a YAML parser; bold-markdown metadata (`**scope**: meta` body lines) is silent schema-drift that rotted the scorecard (a typo'd key fails to match and the tool reads nothing, vs YAML failing loudly), and provenance fields are pure noise — provenance lives in git history and the consolidation dir, never in the memory file. The body carries its own "what happened" texture without a metadata breadcrumb.

   **⚠ The harness re-injects banned provenance on EVERY Write/Edit to a memory-dir file — remediate only via Bash.** Confirmed empirically 2026-06-18 (issue #898): writing OR editing any file under `~/.claude/projects/*/memory/` with the **Write or Edit tool** makes the harness re-stamp `node_type: memory` + `originSessionId: <session-uuid>` into the `metadata` block — on *every* call, including an Edit whose sole purpose is to strip them. Consequence: **you cannot fix a flagged file by re-editing its frontmatter — strip-via-Edit loops forever** (strip → re-inject → strip). The harness does NOT intercept **Bash/python3** writes (a heredoc or atomic temp+mv lands clean), so the ONLY convergent remediation is the Bash normalizer `scripts/normalize-memory-frontmatter.sh` (preserve-first, drops banned fields for free). Rule, used by step 0 and step 2a: whenever a memory file needs its frontmatter regularized or banned keys stripped, run the **Bash normalizer**, never the Edit tool. (`CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` does NOT disable this — confirmed inert 2026-06-18; no harness flag exists.)

   **`type` vs `scope` — only ONE value is a closed set.** The KEY allowlist above is total and enforced. The two VALUES are not symmetric: **`scope` is a closed, behaviour-driving allowlist** (`repo | universal | meta`) — write-suppression, graduation, and eviction branch on it, so an out-of-set scope is a real bug. **`type` is an OPEN, descriptive tag** derived from the filename prefix (`feedback_` → `feedback`, `user_` → `user`, `session_` → `session`, …). *No tool branches on its value* — it is documentation for humans and grep, not a validated enum. The four canonical values (`feedback`/`concept`/`project`/`reference`) are merely the most common; `user`, `session`, `technical`, `architecture`, `org`, `plan`, `bug` are all in live use and equally valid. Keep `type` non-empty and prefix-faithful — do NOT coerce it into a smaller set (that was a stale "allowlist is total" reading that fought the live corpus; the standalone normalizer derives `type = prefix`).

   - **`scope: repo`** — about THIS repo's code, workflow, or tooling. Stays in this memory dir (the default). Loads when working here. *Most lessons are this — don't over-promote.*
   - **`scope: universal`** — behavior that should hold in EVERY session everywhere (e.g. "verify before claiming done", "never batch irreversible ops", "recommend a default over a menu"). Write the full `feedback_*.md` here as usual (preserves the long-form), AND append a graduation candidate to `$SD/claude-md-candidates.md` (step 1.5). **Do NOT edit `~/.claude/CLAUDE.md` directly** — it's always-on, budget-constrained, and Nick-curated; graduation is his call, surfaced in Wrap-up.
   - **`scope: meta`** — applies to cross-project / meta work (subagent orchestration, memory curation, experiment design) rather than any single repo. Its natural home is the `~/git` catch-all memory dir. If this session's memory dir IS the catch-all (`-Users-nick-git`), write it here. If you're in a repo, write it here too **but also** add a line to `$SD/claude-md-candidates.md` under a `META (catch-all candidate)` heading — **never cross-dir write** into another project's memory dir from here (that races with parallel sessions and mis-keys the file).

1a. **Post-graduation write-suppression** (gate on the step-1 write — per TRANSFORM-worthy lesson, before the file is written). Once a lesson has graduated to `~/.claude/CLAUDE.md`, do NOT keep flooding the corpus with the Nth low-texture restatement of it. This is the dual of the within-repo merge pass: that one *collapses* same-purpose files after the fact, this one *prevents creating* same-texture files up front — and a wrong write here is backstopped by that merge pass, which is what licenses the write-biased default below.

   - **Is this lesson already a graduated directive?** Run step 1.5's SEMANTIC theme detection — extract the lesson's 1-2 key terms — but `grep -i` them against `~/.claude/CLAUDE.md` (the graduated directives), then READ the matching directive to confirm it's the SAME lesson, not just the same word. If no graduated directive covers it → no suppression; proceed with the normal step-1 write.
     - **On a YES match, stamp reinforcement (feeds the eviction audit in Wrap-up).** A graduated lesson recurring IS a reinforcement event. Update `~/.claude/directive-reinforcement.json` — a sidecar map `{<dir-id>: {"last_reinforced": "<ISO date>", "count": <n+1>, "directive": "<human label>"}}`. **The key MUST be the matched directive's stable `<!-- dir-id: xxxx -->` marker — never a slug of its heading or text.** Read the matched directive line in CLAUDE.md; the marker is the 4-hex token in its trailing `<!-- dir-id: xxxx -->` comment. Key the sidecar on that token verbatim (the `directive` field is a human-readable label for grep convenience only — it is NOT the key, and drift in it is harmless). Why not a heading/text slug: most directives are *bullets under shared headings* (so "the heading" is non-unique), and any slug is regenerated independently at stamp-time vs audit-time (so two invocations mint different keys for the same directive even with zero edits) — the marker is written down once and never re-derived, which is the whole point. Deliberately a SIDECAR, not date-annotation in CLAUDE.md — machine-readable dates in the always-on file would re-bloat the very thing the eviction audit de-bloats (the `dir-id` marker is a few stable bytes, not a mutating date). Create the file/entry if absent (`count: 1`). **FAIL SAFE: if the matched directive has NO `<!-- dir-id -->` marker** (a hand-added or not-yet-migrated directive), do NOT mint a guessed key — skip the stamp and note it in the scorecard `notes` ("reinforcement unstamped: <directive> lacks dir-id"). A missing stamp is harmless (the directive simply isn't aging toward staleness); a guessed key is an orphan that corrupts the audit. This stamp is independent of the write/enrich/skip outcome below — the recurrence happened regardless.

   - **If graduated → does this instance carry NEW TEXTURE?** Texture = a *new failure mode* (a way the lesson breaks that isn't already recorded), a *new trigger/context* (a domain/situation it newly applies to), or a *new mechanism/tool* (a specific verification command/technique not yet captured). Judge against the graduated directive AND a couple of existing instances (the recurrence grep already surfaces them):
     - **New texture, repo-specific** (a fresh scar in this repo's domain) → **WRITE** the `feedback_*.md` as usual. Texture is the value; a new scar always earns its file.
     - **New texture, universal** (it sharpens the directive itself — the way CLAUDE.md's verify directive grew its "observe the effect, not just the change" clause) → do NOT write a new file; append a **CLAUDE.md enrichment candidate** to `$SD/claude-md-candidates.md` under an `ENRICH: <existing directive>` heading. Nick folds it into the existing directive in Wrap-up; CLAUDE.md is never auto-edited.
     - **No new texture** (same lesson, same shape, just another occurrence) → **SKIP** the write. Record the recurrence instead: bump the `(recurred: …)` count on the existing graduation candidate, or note it in the scorecard `notes`. The count is the signal; a 53rd same-texture file is pure bloat.

   - **BIAS: when unsure whether texture is new, WRITE.** Suppression fires ONLY on high-confidence same-texture restatements. The cost is asymmetric — a wrong skip silently loses a real scar (unrecoverable), a wrong write is mild redundancy the merge pass later collapses. Default to writing; suppress only when you are sure it adds nothing.

1.5. **Graduation queue** (`$SD/claude-md-candidates.md`): for each `scope: universal` lesson (and each `scope: meta` catch-all candidate), append ONE compressed line: `- <DIRECTIVE — one imperative sentence> — [[<feedback_file_name>]] (<scope>)`. This is the *review queue* the orchestrator surfaces to Nick in Wrap-up; graduation = Nick approves a line and it becomes a one-line directive in `~/.claude/CLAUDE.md` pointing at the long-form memory. **Compression, never copy** — CLAUDE.md holds the trigger + pointer, the memory file holds the why (the existing CLAUDE.md one-liners like "never batch irreversible ops" backed by `feedback_no_batch_delete.md` are the model). The strongest case for paying the always-on CLAUDE.md tax is **recurrence — and recurrence is SEMANTIC, not filename-exact.** Consolidation gives every memory a unique name, so the same lesson scatters across repos under different filenames: "verify before asserting" exists as `feedback_verify_before_poetry.md`, `feedback_verify_serving_boundary_before_diagnosis.md`, `feedback_verify_dont_assert_from_source.md`, … — 38 distinct files across ~15 repos, **zero** of them filename-identical (measured 2026-06-13). So do NOT detect recurrence by matching filenames (it returns nothing). Detect it by THEME: extract the lesson's 1-2 key terms and `grep -l` filenames + index descriptions across `~/.claude/projects/*/memory/feedback_*.md` (and the sharded `MEMORY.feedback.md` indexes), then read a couple of hits to confirm they're the *same* lesson, not just the same word. If it recurs across ≥2 repos, append `(recurred: <repoA>, <repoB>; N total)` — the count is itself the promote signal: a lesson written 38× is not locally salient, it is load-bearing everywhere. If there are no universal/meta lessons this session, do NOT create the file (its absence is the "nothing to graduate" signal Wrap-up checks).
2. **Memory writes**: for every concept, project, or reference worth keeping, write/update a memory file. Then index the new file with appropriate edges (`←` derives_from, `⊕` extends, `~` analogous_to, `↔` contrasts, `⊗` joint_synthesis) — **routing the index line by memory-type if the project uses a sharded index**:

   - First check whether the project's memory dir contains `MEMORY.feedback.md` and/or `MEMORY.concepts.md` sibling indexes alongside `MEMORY.md` (the **tree-sharded layout** — root `MEMORY.md` is always auto-loaded; children load on demand to keep the root under its ~24KB context budget).
   - **If sharded:** route by filename prefix. `feedback_*.md` → append index line to `MEMORY.feedback.md`. `concept_*.md` and `dreamscape_*.md` → append to `MEMORY.concepts.md`. Only `user_*`, `project_*`, `reference_*`, `org_*`, `agent_*` and `memory-health.json` go in root `MEMORY.md`. **Never append a `feedback_*` or `concept_*` line to root** — that re-bloats it and undoes the split.
   - **If not sharded (flat `MEMORY.md` only):** index everything in root as before. But if root crosses ~24KB after your writes, flag it in the scorecard (`memory_index_over_budget: true`) — that's the signal to shard next.
   - Index lines: **one line, under ~200 chars** including edges. Long edge-chains are bloat; the file holds the detail, the index just routes.

2a. **Post-write frontmatter validation gate (HARD — do not skip).** Step 0's self-heal runs BEFORE your writes, so it cannot catch a banned field YOU just wrote — this gate closes that hole at the source. After all step-2 writes, validate EVERY file you created or updated this session (NOT the whole dir — legacy drift in files you didn't touch is step 0's job, not this gate's). Pass the exact list of paths you wrote/updated to **the canonical schema validator** — `scripts/validate-memory-frontmatter.sh` (installed at the stable path `$HOME/.claude/scripts/validate-memory-frontmatter.sh` by `scripts/install-symlinks.sh`). That ONE script IS the schema definition — the allowlist, the required fields, and the scope enum live there and nowhere else, so this gate cannot drift from the normalizer's gate or from step 1's prose (issue #883). Do not re-state or re-implement the checks here; just call it:

   ```bash
   # WROTE = absolute paths of the memory files you wrote/updated in steps 1-2.
   # MUST be a bash/zsh array (not a bare string): zsh does NOT word-split an
   # unquoted "$WROTE", so a space-joined string arrives as one bogus path.
   WROTE=( /abs/path/to/file_one.md /abs/path/to/file_two.md )   # ← fill with the files you actually wrote
   bash "$HOME/.claude/scripts/validate-memory-frontmatter.sh" "${WROTE[@]}"
   # (If the symlink is missing — fresh clone — run `bash scripts/install-symlinks.sh`
   #  in the claude-skills repo first, or call the repo copy directly.)
   ```

   It prints one `INVALID <file>: <why>` line per offender and exits non-zero. If it does, **remediate each named file by running the Bash normalizer — `bash "$HOME/.claude/scripts/normalize-memory-frontmatter.sh" --apply <file>` — then re-run the validator until it exits 0.** Do NOT re-edit the frontmatter with the Write/Edit tool: every Write/Edit to a memory-dir file re-injects `node_type`/`originSessionId` (see the harness re-injection note in step 1), so a strip-via-Edit never converges — the normalizer's atomic Bash write is the only convergent strip. This is a gate, not a warning: finishing step 2 with any file failing it re-commits the exact PR #57 violation this gate exists to stop (the 2026-06-16 first-live-run leak of `node_type`/`originSessionId` into 9 files). The validator enforces the FULL schema (key allowlist + required `name`/`description`/`metadata.type` + `scope` enum + parseability) — strictly more than this gate's earlier inline check, which caught extra keys but not a bad/missing scope.

2b. **Within-repo merge-candidate detection (gated — skip entirely if the gate is closed).** The memory corpus accretes near-duplicate files *within a single repo* as the same lesson is re-learned (e.g. nine `feedback_verify_*.md` siblings in one dir). This pass surfaces collapse candidates for Nick. It NEVER auto-merges and NEVER deletes — it proposes, Nick disposes. (This pass lived in knowledge-mapper through v6; it moved here in v7 because YOU wrote the files and already hold their `description:` frontmatter in context, which severs knowledge-mapper's read of your `scorecard.json` and lets the two agents run fully in parallel.)

   - **Gate.** Build, in memory, the list of every `feedback_*.md` / `concept_*.md` path you wrote OR updated in steps 1-2 (this is the SAME set you will serialize into `scorecard.json`'s `memories_written` + `memories_updated` later in step 4 — do NOT read `scorecard.json` here; you have not written it yet, and reading a not-yet-existent artifact is a causality bug. Keep the list as a running in-memory accumulator). If that list is EMPTY, write one line to `$SD/merge-candidates.md` — "No new feedback/concept files this session; merge-detection skipped." — and do no further work here. (No new file ⇒ no new potential duplicate ⇒ don't re-nag Nick with the same candidates every session.)

   - **Mechanism — holistic description read, NOT text-similarity / NCD.** For each this-session file, read the `description:` frontmatter of EVERY same-type sibling in this repo's memory dir (`<MEMORY_DIR>/feedback_*.md` or `concept_*.md`; the dir is the one you've been writing to). Even the largest repo's entire description corpus is ~8K tokens — read it all in-context; do NOT score body/character overlap (that measures the shared template, not the meaning, and the merge-vs-differentiate margin lives inside its noise floor). Two files are a MERGE candidate iff they share a **retrieval purpose**: the same trigger situation would cue recall of either, and a reader in that situation is equally served by either. The `description:` field IS the retrieval-cue by design — decide on description *meaning*, not body vocabulary. If a sibling has no parseable `description:` line (older files predate the canonical-frontmatter convention), fall back to its leading summary / first paragraph rather than silently skipping it.

   - **Schema is not purpose.** A shared *abstraction* ("verify before X", "check before Y") is NOT a shared purpose. Nine files that all say "verify" but fire on nine different triggers (about-to-push-a-PR vs about-to-write-"shipped" vs about-to-declare-a-file-destroyed) are *siblings under a graduated schema*, NOT duplicates — and that shared schema is exactly what graduates to CLAUDE.md (via your step-1.5 graduation queue), which is why their bodies look near-identical. **Differentiate by default; merge only on genuine same-purpose.** A wrong merge silently eats a distinct trigger→tool mapping; when unsure, differentiate.

   - **GUARDRAIL — within this repo ONLY.** Never propose merging across repos. The same lesson recurring across repos under different filenames is *distributed evidence* — the recurrence COUNT is the promote signal (you record it as a `(recurred: …)` annotation on the graduation candidate in step 1.5). Collapsing cross-repo copies destroys the very instrument that surfaces graduations.

   - **Output → `$SD/merge-candidates.md`.** List each proposed merge GROUP (2+ files): the filenames, each description, the shared retrieval purpose in one sentence, and which file should be the survivor (the richest) with the others folded in as sections. This is a proposal — Nick (or a later memory-writer pass) executes; you only surface. If you weighed a near-pair and chose to DIFFERENTIATE, record it in one line with the distinguishing trigger, so the call is visible and not re-litigated next session.

3. **memory-health.json**: update access counts and decay-class entries for any memory files touched this session.
4. **Scorecard**: write $SD/scorecard.json with EXACTLY this schema — no alias keys, no extra top-level fields. (Schema drift is what killed this instrument's analyzability the first time: 200+ distinct keys had accumulated by the 2026-05-28 audit, and the analyzer ended up grading an empty field-intersection. Anything that doesn't fit goes in `notes`.) Before listing a file under `memories_written`/`memories_updated`, verify it exists on disk (`ls` the path) — a prior consolidation claimed memories it never wrote (phantom-write bug, 2026-04-29); the scorecard is a receipt, not a self-report.

   ```json
   {
     "schema_version": 2,
     "session_date": "<ISO 8601>",
     "memory_dir": "<absolute path from $SD/memory-path.txt>",
     "memories_written": ["<absolute path, verified to exist on disk>"],
     "memories_updated": ["<absolute path, verified to exist on disk>"],
     "index_edits": 0,
     "errors_triaged": 0,
     "memory_index_over_budget": false,
     "predictions": [
       {"text": "<falsifiable claim about the next session>", "basis": "<evidence>", "confidence": 0.8}
     ],
     "notes": "<optional free text — overflow goes here, never as a new top-level key>"
   }
   ```

   Predictions: 3-5, graded at next-session-start by the readtime hook. Prefer claims checkable from repo/file/issue state over claims about what Nick will choose to do — in the first run of this experiment, 75% of predictions came back unresolvable because they needed days to resolve and grading happened within hours. Include at least one negative prediction ("X will NOT happen") — those are the honest bets.

   **4a. Post-write scorecard validation gate (HARD — do not skip).** Do NOT trust yourself to have reproduced the schema from the prose above — that is exactly what drifted on the 2026-06-17 run (predictions written as `{id, claim, verifiable_by}`, top-level `{project, session_label, scores, …}`), silently breaking the next-session readtime grader. After writing `$SD/scorecard.json`, validate it against **the canonical scorecard schema validator** — `scripts/validate-scorecard.sh` (installed at `$HOME/.claude/scripts/validate-scorecard.sh` by `scripts/install-symlinks.sh`). That ONE script IS the schema; do not re-state the keys here, just call it:

   ```bash
   bash "$HOME/.claude/scripts/validate-scorecard.sh" "$SD/scorecard.json"
   # (If the symlink is missing — fresh clone — run `bash scripts/install-symlinks.sh`
   #  in the claude-skills repo first, or call the repo copy directly.)
   ```

   It prints `INVALID scorecard.json: <why>` and exits non-zero on any drift (wrong/missing/alias top-level key, or a `predictions[]` entry that isn't exactly `{text, basis, confidence}` with a non-empty `text`). If it does, **rewrite the offending fields to the schema above and re-run until it exits 0.** This is the same fail-loudly discipline as step 2a's frontmatter gate; the scorecard is the receipt the entire readtime-scoring loop depends on.
5. **Open-tasks dump (human-readable)**: write $SD/open-tasks.md from the TaskList snapshot the orchestrator passed you below. Format: one section per task with subject as a heading, then full description verbatim. At the top of the file, include this one-liner:

   > These tasks are session-scoped (they live in ~/.claude/tasks/<session-uuid>/ and won't be visible to a fresh session). To make them live again next session, recreate each via TaskCreate.

   If the snapshot is empty (no pending/in_progress tasks), still create $SD/open-tasks.md with the header line and a body of "No open tasks at consolidation time." — the file's existence is what next-session-prompter checks.

6. **Pending-tasks snapshot (machine-readable, project-keyed)** — broken into three sub-steps so each concern is explicit:

   - **6a. Resolve the target path.** Read `$SD/memory-path.txt` to get the project memory dir (e.g. `/Users/nick/.claude/projects/-Users-nick-git-orgs-.../memory`). The target file is `<MEMORY_DIR>/pending-tasks.json`. Filing it under the project memory dir (not `$SD/`) keeps tasks project-keyed — tasks from a tech_world session won't leak into an infra session's wake-up. This file is the **local mirror / fallback** for the wake-up protocol; the primary source is GitHub issues in `nickmeinhold/claude-tasks` (see step 6.5).

   - **6b. Write the JSON snapshot.** Write the TaskList snapshot verbatim as a JSON array, one object per task, fields `subject` / `description` / `activeForm`. Schema must match exactly — the wake-up step maps these fields directly into `TaskCreate` calls.

   - **6c. Empty-snapshot semantics + overwrite policy.** If the snapshot is empty, still write `[]` — the wake-up step's existence check is the contract; an absent file means "no consolidation has run", an empty array means "consolidation ran, no tasks were pending". If a `pending-tasks.json` already exists at the target path from a prior unrestored session, overwrite it: the TaskList snapshot from the most-recent consolidation is authoritative. If the prior session had pending tasks Nick still wanted, they're recoverable from MEMORY.md or that session's `$SD/open-tasks.md` — so the last-writer-wins behavior here is bounded, not silent data loss.

6.5. **GH issue reconciliation (catch-up sync for the PostToolUse hook).** The `task-to-gh-issue.sh` PostToolUse hook (wired in `~/.claude/settings.json`) creates an issue in `nickmeinhold/claude-tasks` live on every `TaskCreate` and closes it on `TaskUpdate→completed`. Consolidation's job is **reconciliation**, not bulk-creation — the hook may have dropped a write (network blip, `gh` rate-limit) or missed a task captured before the hook was installed.

   - **6.5a. Derive the project label — MATCH THE HOOK EXACTLY.** `project_slug = basename of the GIT REPO ROOT`, i.e. `basename "$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$CWD}")"`. The label is `project:${project_slug}`. **Do NOT use a full-path slug (`cwd_with_/_replaced_by_-`) — that was a bug** (2026-06-12): it minted duplicate issues under a dead `project:-Users-nick-git-...` label namespace because the consumer (`~/.claude/scripts/task-to-gh-issue.sh`) and the wake-up restore both use the repo-root basename. The hook's derivation is authoritative — it uses `basename "${repo_root:-${CLAUDE_PROJECT_DIR:-$cwd}}"` (repo-root basename is stable regardless of cwd within the repo and stays under GitHub's 50-char label cap; `basename "$cwd"` alone mislabels everything `project:projects` when run from `~/.claude/projects/...`). Pass the orchestrator's cwd to memory-writer so it can run the same derivation. **This `project_slug` value flows into 6.5c's id hash too — get it right here and both label and id stay in sync with the hook.**

   - **6.5b. List existing open issues** for this project: `gh issue list -R nickmeinhold/claude-tasks --label "project:<slug>" --state open --json number,title,body --limit 200`. Extract each issue's `claude-task-id` marker from the body (line of the form `<!-- claude-task-id: <16-hex> -->`).

   - **6.5c. Cross-reference with the TaskList snapshot.** For each task in the snapshot, compute the id with the EXACT formula the hook uses: `id="$(printf '%s::%s' "<subject>" "<project_slug>" | shasum -a 256 | cut -c1-16)"` (note the `::` separator and that `<project_slug>` is the repo-root basename from 6.5a — any divergence here re-mints duplicates). Prefer matching on an issue's existing `<!-- claude-task-id: ... -->` marker first; fall back to the computed id only when a task carries no marker. If no open issue carries that marker, the hook missed it — create the issue inline:
     ```bash
     gh issue create -R nickmeinhold/claude-tasks \
       --title "<subject>" \
       --body "<description>\n\n---\nReconciled at consolidation (session <session-id>).\n<!-- claude-task-id: <id> -->" \
       --label "project:<slug>"
     ```

   - **6.5d. Do NOT close issues here.** Closing is the `TaskUpdate→completed` hook's job. Consolidation only creates missing issues — a task being absent from the current snapshot doesn't mean it was completed (could be deleted, deferred, or never captured this session). Hook owns closure; consolidation owns catch-up.

   - **6.5e. Failure mode.** If any `gh` call fails (offline, rate-limited, repo unreachable), note it in the return message and continue — the local `pending-tasks.json` from step 6 is the fallback, and the next consolidation retries. Never block the rest of consolidation on a `gh` failure.

7. **Write wins** from this session to `$SD/wins.md` (with today's date). Do NOT write to `~/.claude/wins.md` directly — the orchestrator appends this file to the global wins log in the Wrap-up step, ensuring a single writer even when parallel /consolidate sessions are running.

Do NOT write $SD/next-session-prompt.md — that file is owned exclusively by the next-session-prompter agent.

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

#### Agent 2: knowledge-mapper

```
Agent({
  description: "knowledge-mapper — graph side of consolidation",
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: `
ABSOLUTE PATHS ONLY. All paths below use $SD — the orchestrator has already substituted the literal absolute session-dir path at heredoc-expansion time. Use these paths directly; no substitution needed. (Historical note: routing through a `latest/` symlink caused data loss on 2026-05-02→03 — knowledge-mapper's first-pass output was overwritten by a parallel tab. The symlink no longer exists; absolute paths are the only path.)

MODEL: sonnet. You are synthesizing — graph edges, Kolmogorov-minimal description, hierarchical forward plan. You do your OWN domain-term and dropped-tangent extraction directly from `session-summary.md` (v7 removed the Haiku pre-pass — you read the whole summary anyway, so a separate extractor saved nothing and only added a hallucination-validation tax). You have NO `raw/*` inputs to read — the former `raw/domain-terms.md` / `raw/dropped-tangents.md` are gone. (The `$SD/raw/` directory itself still exists for Phase 0a's marker-extractor, but nothing in it is yours; do not read it.)

Read $SD/memory-path.txt to get the correct memory directory path. Then read $SD/session-summary.md in full. ALSO read $SD/marker-conversation.md if it exists and is not the "No marker conversation this session." sentinel — its `**Surfaced:**` lines are Nick's own articulation of why specific moments mattered, which is high-signal input for graph nodes and the error-triage patterns section. Treat a takeaway Nick stated himself as stronger evidence than one you inferred from the summary. Do NOT read `$SD/scorecard.json` — within-repo merge-detection moved to memory-writer in v7, so you have no dependency on its output and the two of you run concurrently.

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
1. Write everything to $SD/consolidation.md as a single document with sections: Knowledge Graph / Domain Terms / Forward Plan / Dropped Tangents / Error Triage Patterns / Memory File Candidates. (Within-repo merge-detection is NOT your job anymore — memory-writer owns it and writes `$SD/merge-candidates.md`; do not add a merge section here.)
2. **Do NOT write to the memory directory directly.** memory-writer is the sole owner of persistent memory writes. If you identify a concept that deserves a standalone memory file, list it under "Memory File Candidates" in consolidation.md with a proposed filename, suggested edges, and a 2-3 sentence body. **memory-writer runs CONCURRENTLY with you in Burst 1 — do NOT assume it has finished or read any file it owns** (`scorecard.json`, the memory dir's new files, `merge-candidates.md`). Your "Memory File Candidates" list is advisory: memory-writer may independently produce a `feedback_*.md` for the same concept this session, or the candidate is picked up next consolidation (or by Nick reading consolidation.md). The semantic overlap is intended and harmless — you write to distinct files.

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
  `
})
```

#### Agent 3: next-session-prompter (Burst 2 — runs AFTER knowledge-mapper)

```
Agent({
  description: "next-session-prompter — craft the cold-reader onboarding prompt",
  subagent_type: "general-purpose",
  model: "opus",
  prompt: `
ABSOLUTE PATHS ONLY. All paths below use $SD — the orchestrator has already substituted the literal absolute session-dir path at heredoc-expansion time. Use these paths directly; no substitution needed.

MODEL: opus. This is the one deliverable Nick copy-pastes into the next session — its voice, challenge-skill calibration, and ability to "make the next instance want to dive in" set whether tomorrow lands in flow. Don't cheap out; Opus earns its cost here.

Read these files (all of them — they are your full input):
- $SD/session-summary.md (what happened)
- $SD/consolidation.md (knowledge graph + forward plan + dropped tangents — written by knowledge-mapper, which has just completed)
- $SD/open-tasks.md (deferred tasks dump — written by memory-writer; may say "No open tasks at consolidation time.")
- $SD/affective-highlights.md (Nick-triaged emotional anchors, if present)
- $SD/marker-conversation.md (the per-marker dialogue — Nick's own framing of WHY the "real" moments mattered; mine the `**Surfaced:**` lines for the cold reader's emotional + strategic context. May say "No marker conversation this session.")
- $SD/multi-perspective-retro.md (three-pole retrospective synthesis, if present)

Nick says: "Ok what's the prompt for the next session? Let's aim for 5's across the board."

Your job is THE COLD READER's onboarding: craft a session-opening prompt for a fresh Claude instance. The engagement dimensions (all targeting 5/5):
- Impact — who benefits and how much?
- Creativity — novel recombination vs boilerplate?
- Interest — does this make us think or just pattern-match?
- Craft — elegance, readability, simplicity
- Transfer — does this teach a reusable pattern?

The prompt should:
- Reference the crux and forward plan from $SD/consolidation.md so the cold reader inherits the structure, not just the topic
- Give enough context to pick up without re-reading everything
- Be exciting — make the next instance want to dive in
- Set up challenge-skill balance — not trivially easy, not overwhelmingly vague
- Include engagement score targets and why 5's are achievable
- Be ready to paste directly into a new session
- Include a one-line pointer near the top: "Open tasks from previous session: tracked as open issues on `nickmeinhold/claude-tasks` (label `project:<slug>`) — wake-up will auto-restore them via TaskCreate. Local fallback: `$SD/open-tasks.md` + project `pending-tasks.json`." (Skip this line only if open-tasks.md says "No open tasks at consolidation time.")

Actions:
1. WRITE (overwrite) $SD/next-session-prompt.md with the full prompt. You are the sole owner of this file; no other agent writes to it.
2. Score the projected engagement honestly — if some dimensions are naturally lower, say so.

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
  `
})
```

### After all agents return

Show Nick a **one-line** status per top-level agent (one line per agent). Read `$SD/next-session-prompt.md` back into context and present it — that's the one deliverable Nick needs to copy-paste. Don't read `consolidation.md` or `open-tasks.md` back; Nick can review `$SD/` directly if he wants detail.

## Wrap-up

After Phase 1 completes:
- **Merge session wins to global log.** If `$SD/wins.md` exists and is non-empty, append it to `~/.claude/wins.md` under an exclusive mkdir-trap lock to prevent interleave from parallel `/consolidate` orchestrators:
  ```bash
  # Wrap-up step: append session-local wins to global wins file under exclusive lock.
  # mkdir is atomic on POSIX; lock-by-directory-creation is portable across macOS/Linux
  # without needing util-linux's flock(1). The trap ensures release even on early exit.
  if [ -s "$SD/wins.md" ]; then
    LOCK="$HOME/.claude/wins.md.lock.d"
    while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.05; done
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    cat "$SD/wins.md" >> "$HOME/.claude/wins.md"
    rmdir "$LOCK"
    trap - EXIT
  fi
  ```
  The `[ -s "$SD/wins.md" ]` guard skips the lock entirely when there is nothing to append (no-op session). `mkdir` is atomic — only one process can succeed at creating the same directory; the losers retry with 50ms backoff. `trap` ensures `rmdir` runs even on abnormal exit (Ctrl-C, error), preventing a stuck lock. The lock artifact is `$HOME/.claude/wins.md.lock.d` (a directory, not a file). This replaces the `flock(1)` pattern from 7c04504, which is not in macOS stock userland and fails silently if absent — defeating the race-free property the lock was meant to provide. The `mkdir` pattern achieves the same serialization guarantee without the external dependency.
- Confirm memory files were written (memory-writer's status line)
- **Surface within-repo merge candidates.** If `$SD/merge-candidates.md` exists and contains actual proposals (not the "No new feedback/concept files this session; merge-detection skipped." sentinel), present each proposed merge GROUP to Nick — the filenames, the shared retrieval purpose, the proposed survivor — and ask which (if any) to collapse. memory-writer only *proposes*; collapsing is Nick-gated and executed by him or a later memory-writer pass. Say nothing if the file is absent or holds only the sentinel.
- **Validate the scorecard (belt-and-braces — the orchestrator is a different agent than memory-writer).** memory-writer self-checks its scorecard in step 4a, but it is the agent most prone to reproducing the schema from memory and drifting it (it did exactly that on 2026-06-17, and *this* Wrap-up was where it got caught by hand). Re-run the canonical validator before relying on the scorecard for anything downstream (the next-session readtime grader parses it as its receipt; note that as of v7 the merge-detection gate no longer reads it — it uses memory-writer's in-memory accumulator — so do NOT reintroduce a scorecard read there):
  ```bash
  bash "$HOME/.claude/scripts/validate-scorecard.sh" "$SD/scorecard.json"
  ```
  This is an instruction for *you* (the orchestrator), not a scripted gate — so it is a bare command, not an `if`-wrapper that would mask the exit. If it prints any `INVALID …` line (non-zero exit), **STOP: fix `$SD/scorecard.json` to the step-4 schema — the validator names the offending keys — and re-run until it exits 0 before continuing Wrap-up.** A drifted scorecard silently breaks the next-session readtime grader, the rot this whole loop exists to prevent. (A literal `exit 1` here would be wrong — it would abort the rest of Wrap-up; the gate is *you not proceeding*, the same way step 4a gates the memory-writer.)
- **Surface the graduation queue.** If `$SD/claude-md-candidates.md` exists and is non-empty, present its lines to Nick and ask which (if any) to act on. The file can hold two kinds of candidate, applied differently — both require his approval, and CLAUDE.md is never edited without it:
  - **New-directive graduation** (a `- <DIRECTIVE> — [[feedback_file]] (scope)` line, or a `META (catch-all candidate)` line): for each he approves, add a single compressed directive line to the appropriate section of `~/.claude/CLAUDE.md` with a pointer to the long-form `feedback_*.md` — never paste the body. **A new directive is born with a stable identity: append a `<!-- dir-id: xxxx -->` marker to its line**, where `xxxx` is a fresh 4-hex token (generate any unused 4-char hex; verify it does not already appear in CLAUDE.md via `grep -oE 'dir-id: [0-9a-f]{4}' ~/.claude/CLAUDE.md` before using it — note the `-E` extended-regex flag, used consistently everywhere this skill greps for markers). This marker is what the reinforcement sidecar keys off (step 1a) and what the eviction audit enumerates — it survives later heading/text rewording and in-place enrichment, which a derived slug or content-hash cannot. A `(recurred: …)` annotation is a strong nudge to promote.
  - **Enrichment** (an `ENRICH: <existing directive>` heading from step 1a — a new-texture instance of an ALREADY-graduated lesson): for each he approves, fold the new clause into the *existing* directive in place (the model is how the verify directive grew its "observe the effect" clause), rather than adding a new line — keep it compressed. Decline → the texture stays in its repo-scoped `feedback_*.md` (it was written because it was repo-specific) or is simply dropped (if it was a pure restatement). 
  
  Lines he declines stay in their `feedback_*.md` (no loss). This is the ONLY path by which a lesson reaches or grows always-on, cascade-everywhere status. If the file is absent, say nothing (no universal/meta lessons or enrichments this session).
- **Eviction audit (the OUT valve — symmetric with the graduation queue above).** Graduation is one-way without this; left unchecked, the always-on `~/.claude/CLAUDE.md` (loaded every session everywhere) slowly re-bloats. Same pass that promotes also evicts. **The file has two layers, and only one is evictable:** an **evictable directive layer** (graduated one-liners carrying `feedback_*`/`concept_*` pointers — Scan 1 below; currently ~27 directives / ~17KB) and a **non-evictable prose floor** (philosophy / protocol / identity / environment — Resonance, Flow, Sleep & Wake protocols, the CLI list — ~25KB, Nick-curated, *never* an eviction candidate). The budget below governs the layer the valve can actually act on; a whole-file budget is structurally unsatisfiable (see Trigger A). Run the checks; **surface candidates to Nick only when one fires** (silent otherwise — like the graduation queue):
  - **Seed + age the tracking.** The enumeration is TWO explicit scans, not one — the set of graduated directives is defined by their `feedback_*`/`concept_*` pointer, NOT by the presence of a marker (a marker-only grep is blind to exactly the unmarked lines the backfill check must find):
    - **Scan 1 — the full graduated set:** `grep -nE 'feedback_[a-z_]+\.md|concept_[a-z_]+\.md' ~/.claude/CLAUDE.md` lists every graduated directive line (those carrying long-form-memory provenance; philosophy/identity prose has no pointer and is intentionally out of scope — never evictable).
    - **Scan 2 — the markerless (backfill) subset:** pipe Scan 1 through `| grep -v 'dir-id'` to get exactly the graduated directives that LACK a `<!-- dir-id -->` marker.
    - **Aging (marked set):** for each line that DOES carry `<!-- dir-id: xxxx -->`, look up `xxxx` in `~/.claude/directive-reinforcement.json` (the sidecar step 1a stamps, keyed by the same `dir-id`). If a `dir-id` has NO entry, create one with `last_reinforced` = today — this **grandfathers** existing directives (first audit stamps everything today; a directive ages toward staleness only if N days pass with no NEW reinforcement). Never evict on first-seen.
    - **FAIL SAFE (markerless set):** every line from Scan 2 is **NEVER an eviction candidate** — it has no stable key, so it cannot be aged; a missing marker must always degrade to keep, never to evict. **Surface the Scan-2 list to Nick as "needs a dir-id backfill" UNCONDITIONALLY — independent of whether Trigger A/B fire below.** (The "silent unless a trigger fires" rule governs *eviction* candidates only; the backfill note is maintenance observability and is always reported when Scan 2 is non-empty. This is the one exception to the silent-otherwise default.)
    - **Orphan keys (automatic prune — safe, not Nick-gated):** a sidecar entry whose `dir-id` no longer appears anywhere in CLAUDE.md (`grep -q "dir-id: $key" ~/.claude/CLAUDE.md` fails) is dead bookkeeping — the directive it tracked is provably gone. Delete the entry automatically; this is not eviction (no directive is removed, nothing to judge) and never a staleness signal. Note the prune in the scorecard.
  - **Trigger A — directive-layer budget (the forcing function).** The budget caps the **evictable layer only** — the summed bytes of Scan-1's directive lines (`grep -E 'feedback_[a-z_]+\.md|concept_[a-z_]+\.md' ~/.claude/CLAUDE.md | wc -c`) — **NOT** the whole file. *Why not whole-file:* the prose floor (~25KB) is most of the file and is never evictable, so a whole-file cap is structurally unsatisfiable by eviction — its first firing would demand gutting ~70% of hard-won directives to compensate for prose the valve cannot touch (the 2026-06-17 first-live-audit finding, #866 — it would be self-harm, not de-bloating). If the **directive layer** exceeds **~5,000 tokens (~20KB)**, the audit MUST surface the **least-recently-reinforced** directives until the projected directive-layer size is back under budget. The threshold sits just above the current set (~27 directives / ~17KB): it holds this run (correctly — nothing is force-evicted) but applies real back-pressure as the always-on directive set grows, because 27 directives loaded every session everywhere is already substantial. (Both numbers are tunable — the load-bearing fix is *what* is measured, not the exact cap.) **Tie-break (matters on the first audit, when grandfathering has stamped every directive with the same `last_reinforced` date):** when `last_reinforced` ties, order by lowest reinforcement `count` first, then by largest byte-size (biggest bloat reduction per eviction). Without this, "least-recently-reinforced" is an N-way tie on the first run and the selection is undefined.
  - **Whole-file advisory (prose visibility — NOT an eviction trigger).** Separately, if the WHOLE file exceeds **~40KB** (`wc -c ~/.claude/CLAUDE.md`), surface a one-line advisory to Nick: the file is N KB, the directive layer is within budget, but the non-evictable prose (philosophy / protocol / environment) has grown to ~X KB — *he* may want to review or trim those sections by hand. **This NEVER auto-evicts prose** — it is Nick-curated identity/philosophy, deliberately out of the valve's scope; the advisory only makes prose growth *visible* so a directive-layer budget can't silently mask a bloating always-on file. Advisory only, like the backfill note: maintenance observability, never a gated eviction. (Without this, Option-1's directive budget alone would stay green while the prose floor crept toward the context ceiling unnoticed.)
  - **Trigger B — staleness.** Surface any directive whose `last_reinforced` is **older than 60 days** as a stale eviction candidate (it graduated on a recurrence signal that has since gone quiet — possibly solved, possibly superseded by a broader directive).
  - **What eviction does (the guardrail):** removes the always-on **directive line only** from CLAUDE.md (its trailing `<!-- dir-id -->` marker goes with the line; afterwards prune the now-orphaned sidecar entry for that `dir-id`). **Never touch the backing `feedback_*.md` episodes** — they are the repo-scoped distributed evidence #738's merge pass protects. Demotion is directive→(optionally a pointer)→gone; the long-form memory stays. Eviction is **Nick-gated**, exactly like graduation — present candidates with their last-reinforced date + reinforcement count, he approves each. If neither trigger fires, say nothing.
- Show Nick the final next-session prompt
- Mention `$SD/open-tasks.md` exists if there were any open tasks — call it out so Nick knows it's there
- Let him know the full consolidation is at `$SD/` if he wants to review any artifact
- Previous runs are preserved in `~/.claude/consolidation/` with their timestamps
