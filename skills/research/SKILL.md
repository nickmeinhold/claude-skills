---
argument-hint: <research-topic>
description: Spawn a background researcher agent for long research tasks
---

# Research Task

You need to spawn a background research agent to investigate: $ARGUMENTS

## Local Configuration

**Check for project-specific config:** If `.claude/research-config.md` exists, read it first. It may specify:

- Preferred research sources or documentation
- Project tech stack context to include in prompts
- Standard deliverable formats
- Domain-specific terminology or constraints
- Links to internal wikis or docs to reference

Include any relevant local context in the research prompt you generate.

## Instructions

Use the Task tool to spawn a background research agent with the following configuration:

```
Tool: Task
subagent_type: Explore (for codebase research) or general-purpose (for broader research)
run_in_background: true
prompt: <detailed research prompt based on user's request>
```

**Important:**
1. Analyze the research request to determine the best subagent type:
   - `Explore` - for codebase exploration, finding patterns, understanding architecture
   - `general-purpose` - for broader research involving web searches, documentation, multi-step investigation

2. Create a detailed prompt for the subagent that includes:
   - Clear research objective
   - Specific questions to answer
   - What deliverables to produce (summary, recommendations, code examples, etc.)
   - Instruction to be thorough since this runs in background

3. Spawn the agent with `run_in_background: true`

4. **Critical:** Include in the agent's prompt:
   - Instruction to write findings to `RESEARCH.md` in the current working directory
   - The file should have a clear title, date, and structured sections
   - Use markdown formatting with headers, bullet points, code blocks as appropriate

5. Tell the user:
   - That the research is running in background
   - The task ID so they can check on it
   - That results will be saved to `RESEARCH.md` in their project
   - How to check status: "Use `/tasks` to see progress"

## Example Prompts

**Codebase research:**
```
Research how authentication is implemented in this codebase.
Find: auth patterns, token handling, session management, security measures.
Deliverable: Write a RESEARCH.md file with a summary of auth architecture including file references.
```

**Technology research:**
```
Research best practices for implementing real-time updates in Flutter.
Compare: WebSockets, Server-Sent Events, Firebase Realtime Database, Firestore listeners.
Deliverable: Write a RESEARCH.md file with a pros/cons table and recommendation for this project's needs.
```

**Documentation research:**
```
Research the latest Flutter 3.x navigation patterns.
Find: go_router best practices, deep linking, typed routes.
Deliverable: Write a RESEARCH.md file with a summary and code examples applicable to this project.
```

Now spawn the background research agent for: $ARGUMENTS
