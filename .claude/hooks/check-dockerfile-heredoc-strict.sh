#!/bin/bash
# PostToolUse hook: Ensure Dockerfile RUN heredocs contain 'set -euo pipefail'.
# Source: CLAUDE.md - "Dockerfile RUN heredocs use set -euo pipefail"
set -euo pipefail

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

case "$(basename "$CLAUDE_FILE_PATH")" in
  Dockerfile*) ;;
  *) exit 0 ;;
esac

# Find RUN heredocs missing 'set -euo pipefail'.
# Tracks heredoc boundaries by matching the delimiter word after << and
# looking for it alone on a line to close the block.
violations=$(awk '
  /^[^#]*RUN.*<<[[:space:]]*[A-Za-z_]+/ {
    tmp = $0
    sub(/.*<<[[:space:]]*/, "", tmp)
    sub(/[^A-Za-z_].*/, "", tmp)
    delim = tmp
    in_heredoc = 1
    heredoc_start = NR
    found_strict = 0
    next
  }
  in_heredoc {
    if ($0 ~ /set -euo pipefail/ && $0 !~ /^[[:space:]]*#/) found_strict = 1
    if ($0 == delim) {
      if (!found_strict) print heredoc_start": RUN heredoc (closed at line "NR") missing set -euo pipefail"
      in_heredoc = 0
    }
  }
' "$CLAUDE_FILE_PATH")

if [[ -n "$violations" ]]; then
  printf "Convention: Dockerfile RUN heredocs must include 'set -euo pipefail'. Violations in %s:\n" "$CLAUDE_FILE_PATH" >&2
  printf "%s\n" "$violations" >&2
  exit 1
fi
