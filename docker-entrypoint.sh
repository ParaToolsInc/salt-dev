#!/bin/bash
set -euo pipefail

# --- Git identity ---
# Priority: env vars > mounted repo's git config > skip gracefully
GIT_NAME="${GIT_AUTHOR_NAME:-}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-}"

# Auto-detect from mounted git repo if not explicitly provided
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  # Check if the working directory is a git repo
  REPO_DIR="${PWD}"
  if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    if [ -z "$GIT_NAME" ]; then
      GIT_NAME=$(git -C "$REPO_DIR" config user.name 2>/dev/null || true)
    fi
    if [ -z "$GIT_EMAIL" ]; then
      GIT_EMAIL=$(git -C "$REPO_DIR" config user.email 2>/dev/null || true)
    fi
  fi
fi

# Apply whatever identity we found
if [ -n "$GIT_NAME" ]; then
  git config --global user.name "$GIT_NAME"
fi
if [ -n "$GIT_EMAIL" ]; then
  git config --global user.email "$GIT_EMAIL"
fi

# Inform user if identity is incomplete
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  echo "Note: Git identity not fully configured."
  echo "  Set GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL env vars, or"
  echo "  mount a repo with git config user.name/email configured."
fi

# --- Claude Code setup ---
# CLAUDE_CODE_OAUTH_TOKEN provides auth but Claude Code also checks for
# ~/.claude/settings.json to determine if it has been set up before.
# Without it, the first-run wizard fires and prompts for browser login
# even though the token is already present in the environment.
# attribution.commit/pr set to "" disables co-authorship lines in commits/PRs.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  mkdir -p ~/.claude
  if [ ! -f ~/.claude/settings.json ]; then
    printf '{"attribution":{"commit":"","pr":""}}\n' > ~/.claude/settings.json
  fi
fi

# --- GitHub Copilot ---
GH_TOKEN="${GH_TOKEN:-}"
if [ -n "$GH_TOKEN" ] && ! gh copilot --help >/dev/null 2>&1; then
  echo "Installing gh copilot extension..."
  gh extension install github/gh-copilot 2>/dev/null || true
fi

exec "$@"
