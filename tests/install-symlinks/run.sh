#!/usr/bin/env bash
# tests/install-symlinks/run.sh — convenience wrapper for invoking the bats
# suite locally and in CI. Mirrors tests/eval-tally/run.sh in shape.
#
# Requires bats-core. On macOS: `brew install bats-core`.
# In CI we install via apt (`bats`) — see .github/workflows/ci.yml.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH — install bats-core (brew install bats-core)" >&2
  exit 127
fi

exec bats "$TEST_DIR"
