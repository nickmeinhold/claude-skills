---
argument-hint: <question text>
description: Research a question and live-update a Q&A slide on the current presentation
---

# Live Q&A

Update a Q&A slide in real-time on a running Google Slides presentation. The audience sees the slide change live — no clicking needed.

## Input

The question text comes from `$ARGUMENTS`. If empty, error with: "Usage: /live-qa <question>"

## Configuration

Check for `.claude/live-qa-config.md` in the project root. It should contain:

```markdown
## Settings
presentation-id: <Google Slides presentation ID>
```

If the config file doesn't exist, error with: "Missing .claude/live-qa-config.md — set your presentation-id there."

## Steps

### 1. Show progress immediately

The audience is waiting. Before doing any research, generate a unique temp path using the PID or timestamp (e.g., `/tmp/live-qa-slide-$$.json`) and write a progress config to it:

```json
{
  "title": "Q&A",
  "slides": [
    {
      "background": { "red": 0.12, "green": 0.12, "blue": 0.15 },
      "elements": [
        {
          "text": "Q&A",
          "x": 600, "y": 15, "w": 100, "h": 30,
          "size": 14, "color": { "red": 0.4, "green": 0.7, "blue": 1.0 }, "bold": true
        },
        {
          "text": "<THE QUESTION>",
          "x": 40, "y": 40, "w": 640, "h": 50,
          "size": 24, "color": { "red": 1, "green": 1, "blue": 1 }, "bold": true,
          "animate": "matrix"
        },
        {
          "text": "Researching...",
          "x": 40, "y": 150, "w": 640, "h": 50,
          "size": 20, "color": { "red": 0.5, "green": 0.5, "blue": 0.55 }
        }
      ]
    }
  ]
}
```

Run immediately:
```bash
npx --prefix "${CLAUDE_SLIDES_PATH:?CLAUDE_SLIDES_PATH must be set; clone https://github.com/nickmeinhold/claude-slides and export the path}" claude-slides --config $SLIDE_CONFIG --presentation-id <ID> --update-slide last
```

This updates the last slide in-place. The audience sees "Researching..." appear within seconds.

### 2. Research the question

Perform 1-2 targeted web searches to find a concise, accurate answer. Speed is critical — do NOT use background agents. Keep searches focused.

### 3. Update with the answer

Write the final slide config to the same temp file (`$SLIDE_CONFIG`):

```json
{
  "title": "Q&A",
  "slides": [
    {
      "background": { "red": 0.12, "green": 0.12, "blue": 0.15 },
      "elements": [
        {
          "text": "Q&A",
          "x": 600, "y": 15, "w": 100, "h": 30,
          "size": 14, "color": { "red": 0.4, "green": 0.7, "blue": 1.0 }, "bold": true
        },
        {
          "text": "<THE QUESTION>",
          "x": 40, "y": 40, "w": 640, "h": 50,
          "size": 24, "color": { "red": 1, "green": 1, "blue": 1 }, "bold": true
        },
        {
          "text": "<BULLET ANSWER>",
          "x": 40, "y": 110, "w": 640, "h": 250,
          "size": 18, "color": { "red": 0.85, "green": 0.85, "blue": 0.85 }
        }
      ],
      "notes": "<DETAILED NOTES: facts, context, sources, follow-up points for the presenter>"
    }
  ]
}
```

Run:
```bash
npx --prefix "${CLAUDE_SLIDES_PATH:?CLAUDE_SLIDES_PATH must be set; clone https://github.com/nickmeinhold/claude-slides and export the path}" claude-slides --config $SLIDE_CONFIG --presentation-id <ID> --update-slide last
```

The audience sees "Researching..." morph into the actual answer — live, no interaction.

**Formatting rules for the answer element:**
- 3-5 bullet points (use `\u2022 ` as bullet prefix)
- Each point on its own line (`\n` separated)
- Short phrases — readable from the back of the room
- No jargon unless the audience expects it

**Speaker notes** should be much more detailed: include source URLs, nuance, caveats, and things the presenter can say to elaborate.

### 4. Output

Keep output brief — the presenter is on stage:

```
Updated: <question summary in ~5 words>
```

Do NOT output the full research, slide JSON, or verbose logs.

---

## Setup

### Presentation prep

Before starting the presentation, add a **blank slide at the end** of your deck. This is your Q&A slide. During Q&A time, navigate to it and park there. All questions will update this slide in-place — you never need to click again.

Alternatively, you can use `--append` on the first question to create the slide, then `--update-slide last` for subsequent questions.

### Config file

Create `.claude/live-qa-config.md` in your project:

```markdown
## Settings
presentation-id: abc123def456
```

Get the ID from your Google Slides URL: `https://docs.google.com/presentation/d/<THIS-PART>/edit`

### iOS Shortcut: "Ask Claude"

To trigger `/live-qa` from an iPhone (audience asks question, presenter speaks it):

1. **Record Audio** — tap to start, tap to stop
2. **Get Contents of URL** (POST to `https://api.openai.com/v1/audio/transcriptions`)
   - Header: `Authorization: Bearer <OPENAI_API_KEY>`
   - Request body: Form
     - `file`: recorded audio
     - `model`: `whisper-1`
     - `response_format`: `text`
3. **Run Script over SSH**
   - Host: Mac's local IP or hostname
   - User: your macOS username
   - Authentication: SSH key (set up in advance)
   - Command: `claude -p "/live-qa <transcription>"`

### Prerequisites

- **OpenAI API key** for Whisper transcription
- **SSH enabled on Mac**: System Settings > General > Sharing > Remote Login
- **claude CLI** accessible via SSH (may need full path, e.g., `/usr/local/bin/claude`)
- **iPhone and Mac on same network** (or use Tailscale/VPN)
- **`CLAUDE_SLIDES_PATH`** env var pointing to a local clone of [claude-slides](https://github.com/nickmeinhold/claude-slides) (see `/slides` skill for setup)
- **Google OAuth tokens** already set up (`npx --prefix "$CLAUDE_SLIDES_PATH" claude-slides --auth`)
