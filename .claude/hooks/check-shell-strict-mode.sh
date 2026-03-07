#!/bin/bash
# PostToolUse hook: Ensure shell scripts contain 'set -euo pipefail'.
# Source: CLAUDE.md - "Shell scripts use set -euo pipefail"

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

case "$(basename "$CLAUDE_FILE_PATH")" in
  *.sh) ;;
  *) exit 0 ;;
esac

# lint.sh intentionally omits -e so all checks run before reporting a summary.
if [[ "$(basename "$CLAUDE_FILE_PATH")" == "lint.sh" ]]; then
  if ! grep -qE '^[^#]*set -uo pipefail' "$CLAUDE_FILE_PATH"; then
    echo "Convention: lint.sh must include 'set -uo pipefail'. Not found in $CLAUDE_FILE_PATH" >&2
    exit 1
  fi
else
  if ! grep -qE '^[^#]*set -euo pipefail' "$CLAUDE_FILE_PATH"; then
    echo "Convention: shell scripts must include 'set -euo pipefail'. Not found in $CLAUDE_FILE_PATH" >&2
    exit 1
  fi
fi
