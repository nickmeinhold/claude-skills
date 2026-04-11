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
