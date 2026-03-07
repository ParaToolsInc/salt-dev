#!/bin/bash
# PostToolUse hook: Flag ${{ github.* }} in workflow run: blocks.
# These should use shell env vars set via the step's env: key.
#
# Checks for ${{ github.* }} on lines inside run: blocks. These should be
# replaced with shell env vars (e.g., $GITHUB_REF) set via the step's env: key.

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

case "$(basename "$CLAUDE_FILE_PATH")" in
  *.yml|*.yaml) ;;
  *) exit 0 ;;
esac

# Use awk to find ${{ github.* }} only inside run: blocks.
# Track indentation to detect when a run: block ends.
violations=$(awk '
  /^[[:space:]]+run:[[:space:]]*[|>]/ {
    in_run = 1
    match($0, /^[[:space:]]*/)
    run_indent = RLENGTH
    next
  }
  /^[[:space:]]+run:[[:space:]]*[^|>]/ {
    # Single-line run: value
    if ($0 ~ /\$\{\{[[:space:]]*github\./) print NR": "$0
    next
  }
  in_run {
    if (NF == 0) next
    match($0, /^[[:space:]]*/)
    cur_indent = RLENGTH
    if (cur_indent <= run_indent && $0 ~ /[a-zA-Z_-]+:/) { in_run = 0; next }
    if ($0 ~ /\$\{\{[[:space:]]*github\./) print NR": "$0
  }
' "$CLAUDE_FILE_PATH")

if [[ -n "$violations" ]]; then
  printf "Convention: use shell env vars (e.g., \$GITHUB_REF) instead of \${{ github.* }} in run: blocks.\n" >&2
  printf "Set values via the step's env: key. Violations in %s:\n" "$CLAUDE_FILE_PATH" >&2
  printf "%s\n" "$violations" >&2
  exit 1
fi
