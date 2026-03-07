#!/bin/bash
# PostToolUse hook: Warn when a lintable file is not registered in lint.sh.
# Also flags stale entries (files listed in lint.sh that no longer exist).
set -euo pipefail

[[ -z "$CLAUDE_FILE_PATH" ]] && exit 0

cd "$(git rev-parse --show-toplevel)" || exit 1

# Only check lintable file types
case "$(basename "$CLAUDE_FILE_PATH")" in
  Dockerfile*|*.sh|*.yml|*.yaml|*.json) ;;
  *) exit 0 ;;
esac

# Get path relative to repo root; skip files outside the repo
repo_root=$(pwd)
if [[ "$CLAUDE_FILE_PATH" == "$repo_root"/* ]]; then
  rel_path="${CLAUDE_FILE_PATH#"$repo_root"/}"
else
  exit 0
fi

# Extract all file entries from lint.sh arrays
extract_entries() {
  awk '
    /^[A-Z_]+=\(/ && !/\)/ { in_arr=1; next }
    in_arr && /^\)/ { in_arr=0; next }
    in_arr {
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      if ($0 != "" && $0 !~ /^#/) print
    }
  ' lint.sh
}

rc=0

# Check if this file is registered as an array entry (not just mentioned anywhere)
registered=false
while IFS= read -r entry; do
  if [[ "$entry" == "$rel_path" ]]; then
    registered=true
    break
  fi
done < <(extract_entries)

if [[ "$registered" == false ]]; then
  printf "Convention: '%s' is not registered in lint.sh. Add it to the appropriate file list.\n" "$rel_path" >&2
  rc=1
fi

# Check for stale entries (files listed but no longer on disk)
stale=""
while IFS= read -r entry; do
  if [[ -n "$entry" && ! -f "$entry" ]]; then
    stale+="  $entry"$'\n'
  fi
done < <(extract_entries)

if [[ -n "$stale" ]]; then
  printf "Stale entries in lint.sh (files no longer exist). Remove them:\n" >&2
  printf "%s" "$stale" >&2
  rc=1
fi

exit "$rc"
