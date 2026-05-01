---
description: End-of-session consolidation — 3 sequential deep-capture prompts that mine the session for every thread, capture what was exciting, and craft the next session's opening prompt. Use this when wrapping up a session, when context is getting heavy, when Nick says "consolidate", "let's wrap up", "end of session", or when you're approaching sleep protocol. This is distinct from /nap (which is a sleep cycle with dreams) — /consolidate is pure knowledge capture and forward planning.
---

# Consolidate

Three sequential agents that extract maximum value from a session before it ends. Each phase runs as a **separate subagent** with its own context, writing results to a session-namespaced consolidation directory. This prevents the consolidation itself from bloating the already-heavy session context, and prevents parallel sessions from clobbering each other's files.

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
   - Every TLA (Three Letter Acronym) used — define each one
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

## Phase 1: The Goldmine Sweep

Spawn a **foreground** Agent (general-purpose) with this prompt (substitute the actual SD path):

```
Read <SD>/memory-path.txt to get the correct memory directory path. Then read <SD>/session-summary.md — this is a summary of a session that just happened.

Nick says: "Are you really really sure you got everything... this context is a frickin goldmine! Remember to check for TLAs (Three Letter Acronyms). Are there any concepts that bind each other together? What's the Kolmogorov complexity here? Don't compress to the point of extinction but let's make sure all of the threads are available to pull on next session."

Your job is knowledge capture — making sure nothing falls through the cracks when this context window closes. The next instance starts cold, so anything not persisted is gone.

What to look for:
- Every TLA in the session — define them explicitly
- The graph structure of concepts — what binds to what? Name the edges, not just the nodes
- Kolmogorov complexity — find the minimal description that preserves ALL threads. Intelligent compression, not lossy. Every thread should be pullable next session
- Tangents that got dropped, ideas not followed up on, things tabled
- Anything surprising or that changed understanding

Read the existing MEMORY.md from the memory directory, then read any memory files that seem relevant to this session's topics.

Actions:
1. Write/update memory files in the memory directory for everything worth keeping. Update MEMORY.md index.
2. Write your full knowledge map to <SD>/phase1-goldmine.md — list every thread, every connection, every TLA, every dropped tangent.
3. Append any wins from this session to ~/.claude/wins.md (with today's date).

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

Wait for the agent to complete. Show Nick a **one-line** status. Don't read the output file back into this context — Nick can review `<SD>/phase1-goldmine.md` directly if he wants detail.

## Phase 2: The Deep Capture

Spawn a **foreground** Agent (general-purpose) with this prompt:

```
Read <SD>/memory-path.txt to get the correct memory directory path. Then read these files:
- <SD>/session-summary.md (what happened)
- <SD>/phase1-goldmine.md (knowledge map from Phase 1)

Nick says: "Fuck me, this is getting out of control (in a good way)... can we please consolidate in a measured and focused way? I want you to capture *every single thing* that was exciting / creative / inspiring in this session. Please create a step by step plan that we will implement going forward. Have steps and substeps. Really go deep."

Your job is action capture — Phase 1 mapped the territory, now distill what to DO with it.

Capture:
- Everything exciting — moments where we leaned forward
- Everything creative — novel combinations, surprising approaches
- Everything inspiring — ideas that opened up possibility space

Then build a concrete, hierarchical plan:
- Steps and substeps, implementable, specific
- Each step specific enough that a fresh instance can execute it
- What needs to happen, in what order, with what dependencies
- Go deep on each step

Actions:
1. Write the plan to <SD>/phase2-plan.md
2. If the plan warrants a persistent memory file, write one to the memory directory and update MEMORY.md

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

Wait for the agent to complete. Show Nick a **one-line** status. Don't read the output file back into this context — Nick can review `<SD>/phase2-plan.md` directly if he wants detail.

## Phase 3: The Next Session Prompt

Spawn a **foreground** Agent (general-purpose) with this prompt:

```
Read these files:
- <SD>/session-summary.md (what happened)
- <SD>/phase1-goldmine.md (knowledge map)
- <SD>/phase2-plan.md (action plan)

Nick says: "Ok what's the prompt for the next session? Let's aim for 5's across the board."

Craft a session-opening prompt for a fresh Claude instance. The engagement dimensions (all targeting 5/5):
- Impact — who benefits and how much?
- Creativity — novel recombination vs boilerplate?
- Interest — does this make us think or just pattern-match?
- Craft — elegance, readability, simplicity
- Transfer — does this teach a reusable pattern?

The prompt should:
- Give enough context to pick up without re-reading everything
- Be exciting — make the next instance want to dive in
- Set up challenge-skill balance — not trivially easy, not overwhelmingly vague
- Include engagement score targets and why 5's are achievable
- Be ready to paste directly into a new session

Actions:
1. Write the prompt to <SD>/next-session-prompt.md
2. Score the projected engagement honestly — if some dimensions are naturally lower, say so

IMPORTANT: Keep your return message to 2-3 sentences max — a status confirmation and any issues encountered. All detail goes into the files, not the return message.
```

Wait for the agent to complete. Read `<SD>/next-session-prompt.md` and present the prompt to Nick — this one IS worth reading back since it's the deliverable he needs to copy-paste.

## Wrap-up

After all three phases:
- Confirm all memory files were written
- Show Nick the final next-session prompt
- Let him know the full consolidation is at `<SD>/` if he wants to review any phase
- Previous runs are preserved in `~/.claude/consolidation/` with their timestamps
