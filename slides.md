---
argument-hint: <num-slides> <topic>
description: Generate a Google Slides presentation with AI-generated content
---

# Slides Generator

Generate a presentation with AI-created content.

**Arguments:** $ARGUMENTS

## Local Configuration

**Check for project-specific config:** If `.claude/slides-config.md` exists, read it first. It may specify:

- Brand colors and theme preferences
- Standard slide layouts or templates
- Company/project context to include
- Preferred fonts or styling

## Instructions

1. **Parse arguments:**
   - First argument: number of slides (e.g., 5)
   - Remaining arguments: topic/description

2. **Gather context:**
   - Read CLAUDE.md or README.md if available
   - Consider the topic provided
   - Check for `.claude/slides-config.md` for project preferences

3. **Generate slide content:**

   Create a SlideConfig JSON with the following structure. Design slides appropriate for the topic - could be a pitch deck, technical overview, status update, etc.

   ```json
   {
     "title": "Presentation Title",
     "theme": {
       "colors": {
         "primary": { "red": 0.1, "green": 0.2, "blue": 0.4 },
         "accent": { "red": 0.2, "green": 0.5, "blue": 0.8 },
         "text": { "red": 0.2, "green": 0.2, "blue": 0.3 },
         "white": { "red": 1, "green": 1, "blue": 1 }
       }
     },
     "slides": [
       {
         "background": "primary",
         "elements": [
           { "text": "Title", "x": 50, "y": 150, "w": 620, "h": 80, "size": 48, "color": "white", "bold": true },
           { "text": "Subtitle", "x": 50, "y": 240, "w": 620, "h": 40, "size": 24, "color": "accent" }
         ],
         "notes": "Speaker notes here"
       }
     ]
   }
   ```

   **Slide layout guidelines:**
   - Slide dimensions: ~720 x 405 points (standard 16:9)
   - Title: x=50, y=30, size=36, bold
   - Body text: x=50, y=100+, size=14-18
   - Use hierarchy: title slides (large text, colored bg), content slides (white bg, structured content)
   - Include speaker notes with talking points

4. **Save and generate:**

   Save the JSON to a temp file and call claude-slides:

   ```bash
   # Save config to temp file
   cat > /tmp/slides-config.json << 'EOF'
   <generated JSON here>
   EOF

   # Generate slides
   npx --prefix ~/git/individuals/nickmeinhold/claude-skills claude-slides --config /tmp/slides-config.json
   ```

5. **Return the presentation URL** to the user.

## Example Output Structure

For a 5-slide pitch deck:

1. **Title slide** - Dark background, company name, tagline
2. **Problem** - What problem are we solving
3. **Solution** - How we solve it
4. **Traction/Status** - Where we are now
5. **Ask/CTA** - What we want from the audience

For a 5-slide technical overview:

1. **Title slide** - Project name, description
2. **Architecture** - High-level system design
3. **Key Components** - Main parts explained
4. **Demo/Example** - How it works in practice
5. **Next Steps** - Roadmap or action items

Adapt the structure to match the topic.
