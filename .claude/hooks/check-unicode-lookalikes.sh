#!/bin/bash
# PostToolUse hook: Flag Unicode lookalikes that sneak in via autocorrect/copy-paste.
# Catches em/en dashes, smart quotes, non-breaking spaces, and ellipsis.
# Intentional Unicode (e.g., box-drawing chars in terminal output) is NOT matched.
set -euo pipefail

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

case "$(basename "$CLAUDE_FILE_PATH")" in
  *.sh|*.yml|*.yaml|*.json|*.md|Dockerfile*) ;;
  *) exit 0 ;;
esac

# Build grep character class from UTF-8 byte sequences (keeps this script pure ASCII).
#   U+00A0 non-breaking space
#   U+2013 en dash
#   U+2014 em dash
#   U+2018 left single smart quote
#   U+2019 right single smart quote
#   U+201C left double smart quote
#   U+201D right double smart quote
#   U+2026 ellipsis
NBSP=$(printf '\xc2\xa0')
EN_DASH=$(printf '\xe2\x80\x93')
EM_DASH=$(printf '\xe2\x80\x94')
LSQUO=$(printf '\xe2\x80\x98')
RSQUO=$(printf '\xe2\x80\x99')
LDQUO=$(printf '\xe2\x80\x9c')
RDQUO=$(printf '\xe2\x80\x9d')
ELLIPSIS=$(printf '\xe2\x80\xa6')

violations=$(grep -n "[${NBSP}${EN_DASH}${EM_DASH}${LSQUO}${RSQUO}${LDQUO}${RDQUO}${ELLIPSIS}]" "$CLAUDE_FILE_PATH" || true)

if [[ -n "$violations" ]]; then
  printf "Convention: avoid Unicode lookalikes (smart quotes, em/en dashes, etc.) in source files.\n" >&2
  printf "Use ASCII equivalents instead. Violations in %s:\n" "$CLAUDE_FILE_PATH" >&2
  printf "%s\n" "$violations" >&2
  exit 1
fi
