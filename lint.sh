#!/usr/bin/env bash
#
# lint.sh — Run all linters for the salt-dev repository.
#
# Usage: bash lint.sh
#
# Requires: hadolint, shellcheck, actionlint, jq
# Runs all checks (non-fail-fast) and reports a summary at the end.

# --- Color output when connected to a terminal ---
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  # YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED='' GREEN='' BOLD='' RESET='' # YELLOW=''
fi

# --- File lists ---
DOCKERFILES=(
  Dockerfile
  Dockerfile.devtools
)

SHELL_SCRIPTS=(
  lint.sh
  build-llvm.sh
  docker-entrypoint.sh
  install-intel-ifx.sh
  test-build-llvm.sh
  .github/actions/docker-cache/backup.sh
  .github/actions/docker-cache/restore.sh
  .github/actions/docker-cache/timing.sh
)

WORKFLOWS=(
  .github/workflows/CI.yml
)

JSON_FILES=(
  .devcontainer/devcontainer.json
)

# --- Helpers ---
failures=0
checked=0

run_check() {
  local name=$1
  shift
  checked=$((checked + 1))
  printf "${BOLD}[%d] Running %s...${RESET}\n" "$checked" "$name"
  if "$@"; then
    printf "${GREEN}    ✓ %s passed${RESET}\n\n" "$name"
  else
    printf "${RED}    ✗ %s failed${RESET}\n\n" "$name"
    failures=$((failures + 1))
  fi
}

# --- Check for required tools ---
missing=()
for tool in hadolint shellcheck actionlint jq; do
  if ! command -v "$tool" &>/dev/null; then
    missing+=("$tool")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  printf "${RED}${BOLD}Missing required tools:${RESET} %s\n\n" "${missing[*]}"
  printf "Install hints:\n"
  for tool in "${missing[@]}"; do
    case $tool in
      hadolint)
        printf "  hadolint:   brew install hadolint  OR  https://github.com/hadolint/hadolint/releases\n" ;;
      shellcheck)
        printf "  shellcheck: brew install shellcheck  OR  apt-get install shellcheck\n" ;;
      actionlint)
        printf "  actionlint: brew install actionlint  OR  https://github.com/rhysd/actionlint/releases\n" ;;
      jq)
        printf "  jq:         brew install jq  OR  apt-get install jq\n" ;;
    esac
  done
  exit 1
fi

# --- Change to repo root ---
cd "$(git rev-parse --show-toplevel)" || exit 1

# --- Run linters ---
run_check "hadolint" hadolint "${DOCKERFILES[@]}"
run_check "shellcheck" shellcheck --external-sources --source-path=SCRIPTDIR "${SHELL_SCRIPTS[@]}"
# Suppressions managed in .actionlint.yaml
run_check "actionlint" actionlint "${WORKFLOWS[@]}"

# jq --exit-status with 'empty' returns 0 on valid JSON, non-zero otherwise
# shellcheck disable=SC2329  # invoked indirectly via run_check
jq_check() {
  local rc=0
  for f in "${JSON_FILES[@]}"; do
    if ! jq empty "$f" 2>&1; then
      rc=1
    fi
  done
  return "$rc"
}
run_check "jq (JSON syntax)" jq_check

# --- Summary ---
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${BOLD}" "${RESET}"
if [[ $failures -eq 0 ]]; then
  printf '%s%sAll %d checks passed.%s\n' "${GREEN}" "${BOLD}" "$checked" "${RESET}"
else
  printf '%s%s%d of %d checks failed.%s\n' "${RED}" "${BOLD}" "$failures" "$checked" "${RESET}"
fi
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${BOLD}" "${RESET}"

exit "$failures"
