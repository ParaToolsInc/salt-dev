#!/bin/bash
# PostToolUse hook: Flag trailing whitespace in changed files.
# Markdown exception: trailing two spaces after text (line break) is allowed.
set -euo pipefail

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

# Skip binary files
case "$(basename "$CLAUDE_FILE_PATH")" in
  *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.tar*|*.gz|*.bz2|*.xz|*.woff*|*.ttf|*.eot|*.tgz) exit 0 ;;
esac

base=$(basename "$CLAUDE_FILE_PATH")

if [[ "$base" == *.md ]]; then
  # In markdown, exactly 2 trailing spaces after non-whitespace text is a line break.
  # Flag all other trailing whitespace (tabs, 1 space, 3+ spaces, whitespace-only lines).
  violations=$(awk '
    /[[:space:]]$/ {
      line = $0
      n = 0
      while (n < length(line) && substr(line, length(line) - n, 1) == " ") n++
      if (n == 2 && line ~ /[^[:space:]]/) next
      print NR": "$0
    }
  ' "$CLAUDE_FILE_PATH")
else
  violations=$(grep -nE '[[:space:]]$' "$CLAUDE_FILE_PATH" || true)
fi

if [[ -n "$violations" ]]; then
  printf "Convention: remove trailing whitespace. Violations in %s:\n" "$CLAUDE_FILE_PATH" >&2
  printf "%s\n" "$violations" >&2
  exit 1
fi
