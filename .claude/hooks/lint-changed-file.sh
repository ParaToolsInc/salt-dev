#!/bin/bash
# PostToolUse hook: Lint only the file that was just edited/written.
# Delegates to lint.sh --file for consistent linter args.
set -euo pipefail

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

cd "$(git rev-parse --show-toplevel)" || exit 1

./lint.sh --file "$CLAUDE_FILE_PATH" 2>&1 | tail -20
