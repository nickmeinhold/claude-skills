#!/bin/bash
# Triggered via SSH from iOS Shortcut
# Usage: ./live-qa-trigger.sh "What is quantum computing?"
#
# This script invokes Claude Code with the /live-qa skill.
# It's meant to be called from an iOS Shortcut via "Run Script Over SSH".

set -e

# SSH non-interactive shells get a minimal PATH — add homebrew
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

QUESTION="$1"

if [ -z "$QUESTION" ]; then
  echo "Error: No question provided"
  exit 1
fi

# Change to the project directory where .claude/live-qa-config.md lives
cd /Users/nick/git/individuals/nickmeinhold/claude-skills

# Load environment variables (Google credentials, etc.)
source .env 2>/dev/null
export GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET

# Invoke Claude Code non-interactively with the live-qa skill
claude -p "/live-qa $QUESTION" --dangerously-skip-permissions
