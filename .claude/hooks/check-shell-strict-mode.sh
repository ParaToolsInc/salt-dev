#!/bin/bash
# PostToolUse hook: Ensure shell scripts contain 'set -euo pipefail'.
# Source: CLAUDE.md - "Shell scripts use set -euo pipefail"

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

case "$(basename "$CLAUDE_FILE_PATH")" in
  *.sh) ;;
  *) exit 0 ;;
esac

if ! grep -qE '^[^#]*set -euo pipefail' "$CLAUDE_FILE_PATH"; then
  echo "Convention: shell scripts must include 'set -euo pipefail'. Not found in $CLAUDE_FILE_PATH" >&2
  exit 1
fi
