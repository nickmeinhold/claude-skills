#!/usr/bin/env bash
# tests/normalize-frontmatter/run.sh — convenience wrapper for invoking the bats
# suite locally and in CI. Mirrors tests/install-symlinks/run.sh in shape.
#
# Requires bats-core (`brew install bats-core`) and python3 with PyYAML
# (`pip install pyyaml` or apt `python3-yaml`) for the --apply validation path.
set -euo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)

if ! command -v bats >/dev/null 2>&1; then
  echo "bats not found on PATH — install bats-core (brew install bats-core)" >&2
  exit 127
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "PyYAML not importable — install it (pip install pyyaml / apt python3-yaml)" >&2
  exit 127
fi

exec bats "$TEST_DIR"
