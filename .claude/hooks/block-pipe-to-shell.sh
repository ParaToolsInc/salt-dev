#!/bin/bash
# PreToolUse hook: Block curl/wget pipe-to-shell patterns
# Source: Project CLAUDE.md — "prefer Debian-packaged software over curl|bash install scripts"
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Block: curl ... | bash, curl ... | sh, wget ... | bash, wget ... | sh
# Also catches variants with sudo, env, or flags between the pipe and shell
if echo "$COMMAND" | grep -qEi '\b(curl|wget)\b.*\|\s*(sudo\s+)?(bash|sh|zsh|dash)\b'; then
  echo "Blocked: Do not pipe curl/wget to a shell. Download the file first, verify its checksum, then execute it." >&2
  exit 2
fi

exit 0
