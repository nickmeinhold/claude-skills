---
description: End-of-session consolidation — Phase 0 in-context conversation + multi-perspective retrospective, then tier-aware specialized agents (Haiku pre-extractors feeding Sonnet synthesizers, with Opus reserved for the next-session prompt) that mine the session for every thread, capture what was exciting, and craft the next session's opening prompt. Use this when wrapping up a session, when context is getting heavy, when Nick says "consolidate", "let's wrap up", "end of session", or when you're approaching sleep protocol. This is distinct from /nap (which is a sleep cycle with dreams) — /consolidate is pure knowledge capture and forward planning.
---

# Consolidate

Phase 0 (in-context conversation + multi-perspective retrospective) followed by **tier-aware specialized agents** organized as a **three-burst DAG**: Burst 1 runs `memory-writer` (Sonnet) in parallel with the knowledge-mapper Haiku pre-extractor pair (domain-terms / dropped-tangents); Burst 2 runs `knowledge-mapper` synth (Sonnet) gated on the Haiku pair's `raw/*.md` outputs; Burst 3 runs `next-session-prompter` (Opus) gated on `knowledge-mapper`. Each agent runs as a **separate subagent** with its own context, writing results to a session-namespaced consolidation directory. This prevents the consolidation itself from bloating the already-heavy session context, prevents parallel sessions from clobbering each other's files, and — since each agent owns a distinct output file — eliminates merge-conflict risk. Wall-clock dropped from ~3-5 min sequential to ~2 min in the 2026-05-01 test run; tier-aware decomposition (v6) is expected to drop further by moving the read-and-extract passes to Haiku.

## Tiering rationale (read before editing)

Not every sub-job benefits from Haiku-fanout. Subagent spawn has real overhead (context priming, network round-trips, file handoff verification). Use Haiku where it earns its cost:

- **Haiku-worthy**: read-context-and-extract-patterns jobs. Phase 0a marker grep (whole-JSONL scan), knowledge-mapper's domain-term / dropped-tangent extraction. Each reads a sizeable input and produces a small structured output.
- **Stays inside Sonnet synth (NOT a separate Haiku spawn)**: small formatting jobs like `open-tasks.md`, `pending-tasks.json`, `scorecard.json`, `$SD/wins.md` (session-local write). These are cheap enough that the spawn cost would exceed the savings; they ride along with `memory-writer`. The global append to `~/.claude/wins.md` is the orchestrator's job in Wrap-up, under mkdir-trap lock — NOT memory-writer's job.
- **Opus-only**: `next-session-prompter`. Voice, challenge-skill calibration, and "make the next instance want to dive in" determine whether tomorrow's session lands in flow. Don't cheap out.

**Verification gate.** Sonnet synth agents MUST validate Haiku outputs before consuming them — Haiku will occasionally hallucinate a domain term or mis-classify a marker. Treat `$SD/raw/*.md` as candidates, not ground truth. The synth agent's brief includes a mechanically-applicable two-pass rule: (1) for each entry in `raw/*.md`, confirm a supporting span (matching token / phrase / explicit mention) exists in `session-summary.md` — if not, drop it and note the drop; (2) scan `session-summary.md` for domain-terms / dropped-tangents not in the raw lists and add them with the same one-line definition format. Both passes are auditable — a reviewer can re-run the procedure and check compliance.

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

Cold-recall after a multi-hour session is hard. Recognition is easy. Scan Nick's messages from the current session for marker language and present them as quote-first dotpoints. Nick's job: tag each with one of six **action tags** (see "Triage tags" below), not remember.

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

### Triage tags (the six-way filter)

Show the numbered dotpoints to Nick. Ask: **"tag each: carry / pattern / lesson / reframe / emotion / skip."** Triage is dramatically cheaper cognitively than recall, and even cheaper when Nick can answer "1 carry, 2 skip, 3 lesson, 4-6 pattern, 7 skip" instead of re-typing the markers themselves.

Triage is **a filter that also routes**, not just the capture. Its primary job is **attention-allocation** — spend the expensive conversation budget only where it pays — but the tag *also* tells Maxwell which dialog mechanic to run on that marker. That's why the tags are downstream actions, not subjective ratings: each one is mechanically applicable. The "skip" rows are dropped; the others route to distinct capture tactics described below. Don't treat triage as the end of Phase 0a; it's the routing table for the conversation that follows.

**Why six tags, not the old binary.** The previous "real / autopilot" filter collapsed two independent axes — *epistemic value* ("this taught something") and *carry-forward value* ("this is alive, surface it next session") — into one. Nick legitimately uses "real" as their union, but the hypothesis-fork mechanic assumed the epistemic axis only. When Nick tagged a carry-forward "real" (e.g. "this recon pattern is dope, I want to remember it"), the dialog forked on a non-existent lesson and Nick replied "neither — I just want it remembered." Six tags fix this by letting the tag select the mechanic. See `feedback_consolidate_marker_filter_too_narrow.md` for the verifying transcript.

**The tags:**

| Tag | What Nick means | Capture mechanic | Where it goes |
|---|---|---|---|
| **carry** | "this thread/tool/pattern is alive — surface it next session" | Confirm-the-thread (no fork). One short Q: "what specifically should the next-session prompt foreground here?" | `**Surfaced:**` line is a **directive to next-session-prompter** — what to weave in, in Nick's words |
| **pattern** | "this is a recurring shape worth naming" | Hypothesis-fork on the pattern's name — what's the durable rule this instance reveals | `**Surfaced:**` line becomes a candidate `feedback_*` or `concept_*` memory; knowledge-mapper/memory-writer pick it up |
| **lesson** | "I learned something procedural that should change future behaviour" | Hypothesis-fork on what shifted — what's the changed-behaviour clause? | `**Surfaced:**` line becomes a `feedback_*` memory with explicit "next time, do X instead of Y" |
| **reframe** | "this changed how I see X" — conceptual update, not procedural | Hypothesis-fork on the *contrast* — what was the old framing, what's the new? | `**Surfaced:**` line becomes a `concept_*` memory with edges to whatever was reframed |
| **emotion** | "this was the texture of the work — warmth, frustration, peak-flow" | No fork. Preserve Nick's exact framing. Optionally: "anything you want next-me to feel coming in?" | `**Surfaced:**` line becomes anchor language for next-session-prompter's voice — the felt-sense, not the takeaway |
| **skip** | autopilot, no action | (skipped entirely; the filter bought this saving) | nothing |

### Converse through the non-skip markers (the capture)

This is where the value lives. `concept_conversation_first_consolidation` in memory: *dialogue IS consolidation, not a precursor to it.* A triage tag alone throws away the richest vein — *why* a moment mattered, *what* should be carried — at the exact moment Nick's recall is hottest. So after triage, walk through the tagged markers **one at a time**, as an actual back-and-forth, running the mechanic the tag selects.

**Mechanics:**
- Go in order. For each non-skip marker, open with a specific, non-generic question that shows you remember the moment — never "tell me about this." The *shape* of the opening question depends on the tag:
  - **carry**: confirm what to surface in the next-session prompt (no fork)
  - **pattern / lesson / reframe**: hypothesis-fork (see below)
  - **emotion**: open the moment and preserve Nick's framing; no fork
- **For pattern/lesson/reframe, default technique: the hypothesis-fork.** Offer Nick a *pair* of competing readings and ask which nerve it hit. A fork is more inviting than an open question (it gives Nick something to push against), forces you to commit to specific hypotheses (so a lazy "tell me more" is impossible), and a wrong fork is still useful — Nick correcting "neither, it was Z" surfaces more than a blank prompt would. The marker quote + your "→" consequence guess are your raw material for the two prongs; put them on the table and let Nick confirm, sharpen, or overturn. **When Nick's response indicates "I don't have a fork answer, I just want this remembered," that's a signal you mistagged or Nick mis-triaged — switch immediately to the carry mechanic and re-route to a forward-plan directive instead of a takeaway.** (This is why the six-tag system exists; trust Nick's mid-dialog reroute over the original tag.)
- **For carry markers, run a single confirmation Q**: "what specifically should the next-session prompt foreground here?" Capture Nick's answer verbatim; don't paraphrase into a lesson.
- **For emotion markers, ask once and preserve**: "anything you want next-me to feel coming in?" or "how should this register in the next-session prompt's tone?" Capture in Nick's words.
- **One marker per turn.** Don't batch them into a numbered list — that collapses back into triage. Ask, listen, follow the thread Nick pulls (even if it wanders to an untagged marker or a thread not in the list), then move to the next. Two or three exchanges per marker is normal; if Nick gives a one-liner and moves on, that's his signal the well is dry — don't force depth.
- **Skip markers are dropped entirely** — that's what the filter bought. If Nick re-flags one mid-conversation ("actually 5 connects to this"), pull it back in and tag it then.
- Stop when the non-skip list is exhausted OR Nick signals he's done ("ok that's it", "let's move on"). Respect the stop — over-mining a tired session is its own anti-pattern (see Fatigue Monitoring in CLAUDE.md).

**Capture as you go.** Append each marker's exchange to `$SD/marker-conversation.md` as it happens — don't reconstruct from memory at the end. Format per marker, with the `**Surfaced:**` line shape *routed by the tag*:

```
## [time] [emoji] "<verbatim marker quote>"  [tag: carry|pattern|lesson|reframe|emotion]

**Q:** <the question you opened with>
**Nick:** <his response, paraphrased faithfully or quoted — preserve his actual framing>
**Surfaced:** <the routed payload — see below>
```

The `**Surfaced:**` line is what knowledge-mapper turns into graph nodes and what next-session-prompter weaves into the cold-reader's context. Its *shape* depends on the tag:

- **carry** → a **directive** to next-session-prompter ("the next prompt must foreground X — specifically, [Nick's words]"). Two or more carry markers can share a thematic thread; let next-session-prompter group them.
- **pattern** → a **named pattern + clause** ("the recurring shape is X; the rule is: when Y, prefer Z"). This becomes a candidate `feedback_*` or `concept_*` memory.
- **lesson** → a **changed-behaviour clause** ("next time, do X instead of Y, because Z"). This becomes a `feedback_*` memory.
- **reframe** → a **before/after** ("was framed as X; now framed as Y; consequence: Z"). This becomes a `concept_*` memory with edges to whatever it reframes.
- **emotion** → Nick's framing **preserved verbatim**, with a one-line cue for prompt voice ("anchor language for next-session prompt: [phrase]"). No takeaway extraction.

Write the actual *payload* in each case, not a summary of the conversation.

### Write the Phase 0a outputs

Write the tagged dotpoints to `$SD/affective-highlights.md` (the recognition layer — quote + consequence + six-way tag) AND the per-marker dialogue to `$SD/marker-conversation.md` (the capture layer — the tag-routed `**Surfaced:**` payloads). Both feed Phase 1+ agents; they are distinct surfaces, not duplicates — `affective-highlights.md` is the *what stood out + how to route it*, `marker-conversation.md` is the *what each marker actually contributed to the next session*.

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

## Phase 1: Tier-aware specialized agents (Haiku pair + Sonnet pair, then Opus)

Phase 0 (the conversation with Nick + retrospective synthesis) stays undelegated — that's where the in-context judgment lives. Everything downstream of `session-summary.md` is mechanical knowledge capture and can be specialized + partially parallelized.

**Evolution.** v4 ran knowledge capture, the forward plan, and the next-session prompt as **three sequential** general-purpose agents (~60k tokens, ~3-5 min wall-clock). v5 split them into three **specialized** agents — memory-writer + knowledge-mapper in parallel, next-session-prompter gated on knowledge-mapper — and dropped wall-clock to ~2 min in the 2026-05-01 test run. v6 (this version) goes one further: it splits the extraction work *inside* knowledge-mapper into a Haiku pre-pass (domain-terms / dropped-tangents) running parallel to memory-writer in Burst 1, then a Sonnet synth in Burst 2 that consumes those raw candidates, then Opus for the next-session prompt in Burst 3. Three bursts instead of two; the extra synchronization is paid for by moving the heaviest reads to Haiku.

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
- knowledge-mapper Haiku pair → `$SD/raw/domain-terms.md`, `$SD/raw/dropped-tangents.md` (one file each, distinct)
- `memory-writer` (Sonnet) → memory directory + `MEMORY.md` + `memory-health.json` + `<MEMORY_DIR>/pending-tasks.json` (project-keyed; consumed by wake-up step 10) + `$SD/scorecard.json` + `$SD/open-tasks.md` + `$SD/wins.md` (session-local; orchestrator merges to `~/.claude/wins.md` in Wrap-up via mkdir-trap lock — `$HOME/.claude/wins.md.lock.d` is the lock directory; see Wrap-up section)
- `knowledge-mapper` synth (Sonnet) → `$SD/consolidation.md` only (no writes to the persistent memory directory — it surfaces *candidates* in `consolidation.md`; memory-writer is the sole memory-dir writer; also does NOT write to `raw/*` — those are read-only inputs from the Haiku pre-pass)
- `next-session-prompter` (Opus) → `$SD/next-session-prompt.md` only

The exclusivity is what makes "first-writer wins" unnecessary — there is no second writer.

**Model tier is a spawn parameter, not advisory prose.** The orchestrator MUST pass `model: "sonnet"` or `model: "opus"` in the Agent spawn call for memory-writer, knowledge-mapper synth, and next-session-prompter — the `MODEL:` line in each brief is documentation, not an executable parameter. The Haiku spawn examples already include `model: "haiku"` in their `Agent({...})` call; the Sonnet and Opus spawn examples below include the equivalent. Omitting the model parameter lets the harness default to whatever tier is cheapest, which is not the right call here.

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

**Cost discipline**: one grep-pass + one short dialog turn, NOT a subagent. The orchestrator reads `$JSONL_PATH` inline and filters. Only spawn a Haiku trawler if the JSONL is unusually large (>50k tokens) AND Phase 0a's marker-extractor is also spawning — in that case, add a third Haiku running in parallel with the marker-extractor + dropped-tangents extractor, writing `$SD/raw/missed-tasks.md`, and surface that file's contents to Nick after the marker review.

**Scope boundary**: this trawl recovers tasks created-but-not-tracked in the CURRENT session. It does NOT recover orphans from prior unconsolidated sessions — those live in `~/.claude/tasks/<other-uuid>/` and require a separate cross-session orphan sweep (see project memory for the audit). That sweep is a wake-up concern, not a consolidate concern.

### Orchestrator brief: gather the TaskList snapshot

**Before spawning the agents**, the orchestrator (you, in Phase 0) collects the current open task list via the TaskList tool — every task with `status: pending` or `status: in_progress`. For each, capture `subject`, full `description`, and `activeForm`. Pass this snapshot to memory-writer as part of its brief (inline, not via file — the orchestrator is the only context with TaskList access). **Also pass the current working directory** (the orchestrator's cwd) — memory-writer needs it to derive the `project:<slug>` label for step 6.5's GH issue reconciliation.

This matters because tasks created via `TaskCreate` live in `~/.claude/tasks/<session-uuid>/` — **session-scoped, invisible to a fresh session**. Without an explicit dump to a file the next session can read, the task list evaporates at session end. The 2026-05-01 run initially missed this; Nick caught it with "did you save the tasks?". Generalize the lesson: **persistent context lives in files the next session can independently read, not in session-scoped state.** (Same lifecycle pattern that bit `/graph` skill's `commands/` sync-volatile and the audit script's only-`←` parser.)

### Spawn order

1. **Burst 1 (parallel, single message)**: memory-writer (Sonnet) + knowledge-mapper's two Haiku pre-extractors (domain-terms / dropped-tangents). Three agent calls in one message. Wait for ALL THREE to complete before Burst 2.
2. **Burst 2 (single agent)**: knowledge-mapper synth (Sonnet) reads `$SD/raw/*.md` and writes `consolidation.md`. Gated on Burst 1's Haiku pair.
3. **Burst 3 (single agent)**: next-session-prompter (Opus). Reads `consolidation.md` + everything else, writes `next-session-prompt.md`.

This is 3 phases of agent execution. The 2026-05-01 wall-clock measurement (~2 min, v5) reflects the older 2-burst shape; v6 adds one more synchronization barrier but moves the heaviest extraction reads to Haiku running in parallel with memory-writer. Net expectation: similar or slightly better wall-clock, materially lower token cost.

**Burst 1 join mechanism.** The orchestrator dispatches all four Agent({}) calls in a single message — Claude Code's harness blocks the orchestrator's next turn until all four return. No explicit wait primitive is needed; it is a tool-call concurrency property of the harness. The orchestrator's next substantive action (dispatching Burst 2) simply cannot happen until all Burst 1 responses are available.

**Haiku failure gate.** If any Burst 1 Haiku call returns a failure status or produces an empty `$SD/raw/*.md` file, the orchestrator MUST log the failure (one line to the session log, naming which extractor failed) and continue without that extractor's output. The Burst 2 Sonnet synth is responsible for noting the absent input in `consolidation.md` — it should either degrade gracefully (proceed without the missing dimension, noting the gap) or, if the missing extractor's output is load-bearing for the run (unlikely but possible), stop and surface the issue to Nick before writing `consolidation.md`.

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
1. **Error triage**: scan the session for mistakes, corrections from Nick, and process misses. For each TRANSFORM-worthy lesson (the kind that should change future behavior), write or update a feedback_*.md memory file.
2. **Memory writes**: for every concept, project, or reference worth keeping, write/update a memory file. Then index the new file with appropriate edges (`←` derives_from, `⊕` extends, `~` analogous_to, `↔` contrasts, `⊗` joint_synthesis) — **routing the index line by memory-type if the project uses a sharded index**:

   - First check whether the project's memory dir contains `MEMORY.feedback.md` and/or `MEMORY.concepts.md` sibling indexes alongside `MEMORY.md` (the **tree-sharded layout** — root `MEMORY.md` is always auto-loaded; children load on demand to keep the root under its ~24KB context budget).
   - **If sharded:** route by filename prefix. `feedback_*.md` → append index line to `MEMORY.feedback.md`. `concept_*.md` and `dreamscape_*.md` → append to `MEMORY.concepts.md`. Only `user_*`, `project_*`, `reference_*`, `org_*`, `agent_*` and `memory-health.json` go in root `MEMORY.md`. **Never append a `feedback_*` or `concept_*` line to root** — that re-bloats it and undoes the split.
   - **If not sharded (flat `MEMORY.md` only):** index everything in root as before. But if root crosses ~24KB after your writes, flag it in the scorecard (`memory_index_over_budget: true`) — that's the signal to shard next.
   - Index lines: **one line, under ~200 chars** including edges. Long edge-chains are bloat; the file holds the detail, the index just routes.
3. **memory-health.json**: update access counts and decay-class entries for any memory files touched this session.
4. **Scorecard**: write $SD/scorecard.json with your own counts — files written, files updated, MEMORY.md edits, errors triaged. You know your own work; no reason to defer this to a separate pass.
5. **Open-tasks dump (human-readable)**: write $SD/open-tasks.md from the TaskList snapshot the orchestrator passed you below. Format: one section per task with subject as a heading, then full description verbatim. At the top of the file, include this one-liner:

   > These tasks are session-scoped (they live in ~/.claude/tasks/<session-uuid>/ and won't be visible to a fresh session). To make them live again next session, recreate each via TaskCreate.

   If the snapshot is empty (no pending/in_progress tasks), still create $SD/open-tasks.md with the header line and a body of "No open tasks at consolidation time." — the file's existence is what next-session-prompter checks.

6. **Pending-tasks snapshot (machine-readable, project-keyed)** — broken into three sub-steps so each concern is explicit:

   - **6a. Resolve the target path.** Read `$SD/memory-path.txt` to get the project memory dir (e.g. `/Users/nick/.claude/projects/-Users-nick-git-orgs-.../memory`). The target file is `<MEMORY_DIR>/pending-tasks.json`. Filing it under the project memory dir (not `$SD/`) keeps tasks project-keyed — tasks from a tech_world session won't leak into an infra session's wake-up. This file is the **local mirror / fallback** for the wake-up protocol; the primary source is GitHub issues in `nickmeinhold/claude-tasks` (see step 6.5).

   - **6b. Write the JSON snapshot.** Write the TaskList snapshot verbatim as a JSON array, one object per task, fields `subject` / `description` / `activeForm`. Schema must match exactly — the wake-up step maps these fields directly into `TaskCreate` calls.

   - **6c. Empty-snapshot semantics + overwrite policy.** If the snapshot is empty, still write `[]` — the wake-up step's existence check is the contract; an absent file means "no consolidation has run", an empty array means "consolidation ran, no tasks were pending". If a `pending-tasks.json` already exists at the target path from a prior unrestored session, overwrite it: the TaskList snapshot from the most-recent consolidation is authoritative. If the prior session had pending tasks Nick still wanted, they're recoverable from MEMORY.md or that session's `$SD/open-tasks.md` — so the last-writer-wins behavior here is bounded, not silent data loss.

6.5. **GH issue reconciliation (catch-up sync for the PostToolUse hook).** The `task-to-gh-issue.sh` PostToolUse hook (wired in `~/.claude/settings.json`) creates an issue in `nickmeinhold/claude-tasks` live on every `TaskCreate` and closes it on `TaskUpdate→completed`. Consolidation's job is **reconciliation**, not bulk-creation — the hook may have dropped a write (network blip, `gh` rate-limit) or missed a task captured before the hook was installed.

   - **6.5a. Derive the project label.** `project_slug = cwd_with_/_replaced_by_-` (matches `~/.claude/projects/<slug>/` convention). The label is `project:${project_slug}`. The orchestrator's cwd at session start is the source of truth — pass it to memory-writer alongside the TaskList snapshot.

   - **6.5b. List existing open issues** for this project: `gh issue list -R nickmeinhold/claude-tasks --label "project:<slug>" --state open --json number,title,body --limit 200`. Extract each issue's `claude-task-id` marker from the body (line of the form `<!-- claude-task-id: <16-hex> -->`).

   - **6.5c. Cross-reference with the TaskList snapshot.** For each task in the snapshot, compute `id = sha256(subject + "::" + project_slug) | shasum -a 256 | cut -c1-16`. If no open issue carries that marker, the hook missed it — create the issue inline:
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

#### Pre-pass: knowledge-mapper Haiku extractors (parallel burst, spawned alongside memory-writer)

Before knowledge-mapper synthesizes, two Haiku subagents read `session-summary.md` in parallel and produce raw candidate lists. The synth agent consumes these as input rather than re-doing the extraction. **Spawn these two in the same message as memory-writer** — three parallel agents total in this burst (memory-writer + two Haiku extractors). They write to distinct files under `$SD/raw/`, so no shared-write risk.

```
Agent({
  description: "Extract domain-term candidates",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `Read $SD/session-summary.md. List session-specific or domain-specific terms that a competent dev assistant cold-reading the next session would need defined. SKIP standard developer vocabulary (git, branch, PR, JSONL, etc.). One line per term: \`term — one-sentence definition\`. Aim for 5-20 terms. Write to $SD/raw/domain-terms.md (overwrite). Return 1-sentence status.`
})

Agent({
  description: "Extract dropped tangents",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: `Read $SD/session-summary.md. Find tangents that were raised but not pursued — phrases like "we should also", "tabled", "parked", "not pursuing", "would be nice", "follow-up". For each, output one bullet: \`<tangent in ≤2 lines> — why dropped (if stated)\`. Write to $SD/raw/dropped-tangents.md (overwrite). Return 1-sentence status.`
})
```

#### Agent 2: knowledge-mapper

```
Agent({
  description: "knowledge-mapper synth — graph side of consolidation",
  subagent_type: "general-purpose",
  model: "sonnet",
  prompt: `
ABSOLUTE PATHS ONLY. All paths below use $SD — the orchestrator has already substituted the literal absolute session-dir path at heredoc-expansion time. Use these paths directly; no substitution needed. (Historical note: routing through a `latest/` symlink caused data loss on 2026-05-02→03 — knowledge-mapper's first-pass output was overwritten by a parallel tab. The symlink no longer exists; absolute paths are the only path.)

MODEL: sonnet. You are synthesizing — graph edges, Kolmogorov-minimal description, hierarchical forward plan. Haiku pre-extractors have already produced raw candidate lists at $SD/raw/domain-terms.md and $SD/raw/dropped-tangents.md.

**Verification gate.** Treat the raw/* files as CANDIDATES, not ground truth. Apply this two-pass validation against session-summary.md:
1. **Candidate check (per entry)**: for each entry in `raw/*.md`, confirm a supporting span (matching token / phrase / explicit mention) exists in `session-summary.md`. If no supporting span exists, drop the entry and note the drop (e.g., "Dropped: XYZ — no mention in summary"). Sharpen vague definitions where the summary contains more precision.
2. **Coverage scan**: scan `session-summary.md` independently for domain-terms / dropped-tangents not captured in the raw lists. Add any missing entries with the same one-line format.

Both passes are mechanically applicable — a reviewer can re-run the procedure and check your compliance. This is the price of admission for using the Haiku pre-pass — skip it and you ship hallucinations.

Read $SD/memory-path.txt to get the correct memory directory path. Then read $SD/session-summary.md and the three raw/* files. ALSO read $SD/marker-conversation.md if it exists and is not the "No marker conversation this session." sentinel — its `**Surfaced:**` lines are Nick's own articulation of why specific moments mattered, which is high-signal input for graph nodes and the error-triage patterns section. Treat a takeaway Nick stated himself as stronger evidence than one you inferred from the summary.

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
1. Write everything to $SD/consolidation.md as a single document with sections: Knowledge Graph / Domain Terms / Forward Plan / Dropped Tangents / Error Triage Patterns / Memory File Candidates.
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
- Show Nick the final next-session prompt
- Mention `$SD/open-tasks.md` exists if there were any open tasks — call it out so Nick knows it's there
- Let him know the full consolidation is at `$SD/` if he wants to review any artifact
- Previous runs are preserved in `~/.claude/consolidation/` with their timestamps
