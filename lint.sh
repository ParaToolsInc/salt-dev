#!/usr/bin/env bash
#
# lint.sh -- Run all linters for the salt-dev repository.
#
# Usage: ./lint.sh                  # lint all tracked files
#        ./lint.sh --file PATH      # lint a single file (for hooks)
#        ./lint.sh --warn-untracked # also warn about unlisted files
#        ./lint.sh -v               # verbose output
#
# Requires: hadolint, shellcheck, actionlint, jq
# Runs all checks (non-fail-fast) and reports a summary at the end.

# --- Parse flags ---
VERBOSE=false
SINGLE_FILE=""
WARN_UNTRACKED=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--verbose) VERBOSE=true; shift ;;
    --file) SINGLE_FILE="$2"; shift 2 ;;
    --warn-untracked) WARN_UNTRACKED=true; shift ;;
    *) printf "Unknown argument: %s\n" "$1" >&2; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

# --- File lists ---
DOCKERFILES=(
  Dockerfile
  Dockerfile.devtools
)

SHELL_SCRIPTS=(
  lint.sh
  build-devtools.sh
  build-llvm.sh
  docker-entrypoint.sh
  install-intel-ifx.sh
  run-salt-dev.sh
  test-build-llvm.sh
  .claude/hooks/block-pipe-to-shell.sh
  .claude/hooks/lint-changed-file.sh
  .claude/hooks/check-shell-strict-mode.sh
  .claude/hooks/check-workflow-expressions.sh
  .claude/hooks/check-lint-registration.sh
  .claude/hooks/check-dockerfile-heredoc-strict.sh
  .claude/hooks/check-unicode-lookalikes.sh
  .claude/hooks/check-trailing-whitespace.sh
)

WORKFLOWS=(
  .github/workflows/CI.yml
)

JSON_FILES=(
  .devcontainer/devcontainer.json
  .claude/settings.json
)

# Tool configs -- validated implicitly by their respective tools at runtime
CONFIG_FILES=(
  .actionlint.yaml
  .hadolint.yaml
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

# --- Linter args (shared between single-file and full modes) ---
# Note: hadolint reports shellcheck violations inside RUN heredocs using the
# line number of the RUN instruction, not the actual line within the heredoc.
# Run shellcheck directly on extracted scripts for precise heredoc line numbers.
HADOLINT_ARGS=()
SHELLCHECK_ARGS=(--external-sources --source-path=SCRIPTDIR)
ACTIONLINT_ARGS=()
if $VERBOSE; then
  HADOLINT_ARGS+=(--format json)
  ACTIONLINT_ARGS+=(-verbose)
fi

# --- Single-file mode (for hooks) ---
if [[ -n "$SINGLE_FILE" ]]; then
  base=$(basename "$SINGLE_FILE")
  case "$base" in
    Dockerfile*)  exec hadolint "${HADOLINT_ARGS[@]}" "$SINGLE_FILE" ;;
    *.sh)         exec shellcheck "${SHELLCHECK_ARGS[@]}" "$SINGLE_FILE" ;;
    *.yml|*.yaml) exec actionlint "${ACTIONLINT_ARGS[@]}" "$SINGLE_FILE" ;;
    *.json)       exec jq empty "$SINGLE_FILE" ;;
    *)            printf "Unknown file type: %s\n" "$SINGLE_FILE" >&2; exit 1 ;;
  esac
fi

# --- Validate manifest entries exist ---
missing_files=()
for f in "${DOCKERFILES[@]}" "${SHELL_SCRIPTS[@]}" "${WORKFLOWS[@]}" "${JSON_FILES[@]}" "${CONFIG_FILES[@]}"; do
  [[ -f "$f" ]] || missing_files+=("$f")
done
if [[ ${#missing_files[@]} -gt 0 ]]; then
  printf '%s%sError: files listed in lint.sh but missing from disk:%s\n' "${RED}" "${BOLD}" "${RESET}" >&2
  printf '  %s\n' "${missing_files[@]}" >&2
  exit 1
fi

warnings=0

# --- Full run: all tracked files ---
run_check "hadolint" hadolint "${HADOLINT_ARGS[@]}" "${DOCKERFILES[@]}"
run_check "shellcheck" shellcheck "${SHELLCHECK_ARGS[@]}" "${SHELL_SCRIPTS[@]}"
# Suppressions managed in .actionlint.yaml
run_check "actionlint" actionlint "${ACTIONLINT_ARGS[@]}" "${WORKFLOWS[@]}"

# jq --exit-status with 'empty' returns 0 on valid JSON, non-zero otherwise
# shellcheck disable=SC2329,SC2317  # invoked indirectly via run_check
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

# --- Verify CI path-filter covers Dockerfile COPY/ADD sources ---
# shellcheck disable=SC2329,SC2317  # invoked indirectly via run_check
ci_filter_check() {
  local ci_yml=".github/workflows/CI.yml"
  [[ -f "$ci_yml" ]] || return 0

  # Extract dorny/paths-filter 'build' patterns from CI workflow
  local filters=()
  while IFS= read -r val; do
    val="${val#\'}" ; val="${val%\'}"
    val="${val#\"}" ; val="${val%\"}"
    [[ -n "$val" ]] && filters+=("$val")
  done < <(awk '
    /filters:[[:space:]]*\|/ { in_f=1; next }
    in_f && /^[[:space:]]+build:[[:space:]]*$/ { in_b=1; next }
    in_b && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]+/, "")
      sub(/[[:space:]]+$/, "")
      if ($0 != "") print
      next
    }
    in_b && /^[[:space:]]*$/ { next }
    in_b { exit }
  ' "$ci_yml")

  if [[ ${#filters[@]} -eq 0 ]]; then
    printf "  No 'build:' path-filter found in %s -- skipping\n" "$ci_yml"
    return 0
  fi

  local rc=0

  # Extract COPY/ADD source paths from Dockerfiles (skip inter-stage copies)
  local sources=()
  for df in "${DOCKERFILES[@]}"; do
    while IFS= read -r src; do
      [[ -n "$src" ]] && sources+=("$src")
    done < <(awk '
      /^(COPY|ADD)/ && !/--from=/ {
        line = $0
        while (line ~ /\\$/) {
          sub(/\\$/, "", line)
          if ((getline nl) > 0) line = line " " nl
        }
        sub(/^(COPY|ADD)[[:space:]]+/, "", line)
        while (line ~ /^--[a-z]+=[^ \t]+[ \t]/)
          sub(/^--[a-z]+=[^ \t]+[ \t]+/, "", line)
        n = split(line, t)
        for (i = 1; i < n; i++)
          if (t[i] != "") print t[i]
      }
    ' "$df")
  done

  # Verify each COPY/ADD source is matched by a filter pattern
  for src in "${sources[@]}"; do
    local matched=false
    for pat in "${filters[@]}"; do
      # shellcheck disable=SC2053  # intentional glob match
      if [[ "$src" == $pat ]]; then
        matched=true
        break
      fi
    done
    if [[ "$matched" == false ]]; then
      printf "  COPY/ADD source '%s' not covered by CI path-filter in %s\n" "$src" "$ci_yml"
      rc=1
    fi
  done

  # Verify each Dockerfile is in the filter
  for df in "${DOCKERFILES[@]}"; do
    local matched=false
    for pat in "${filters[@]}"; do
      # shellcheck disable=SC2053
      if [[ "$df" == $pat ]]; then
        matched=true
        break
      fi
    done
    if [[ "$matched" == false ]]; then
      printf "  Dockerfile '%s' not in CI path-filter\n" "$df"
      rc=1
    fi
  done

  # Verify submodule paths are in the filter (both gitlink and contents)
  if [[ -f .gitmodules ]]; then
    while IFS= read -r sm; do
      local has_exact=false has_glob=false
      for pat in "${filters[@]}"; do
        [[ "$pat" == "$sm" ]] && has_exact=true
        [[ "$pat" == "${sm}/**" ]] && has_glob=true
      done
      if [[ "$has_exact" == false ]]; then
        printf "  Submodule '%s' (gitlink) not in CI path-filter -- misses pointer updates\n" "$sm"
        rc=1
      fi
      if [[ "$has_glob" == false ]]; then
        printf "  Submodule '%s/**' (contents) not in CI path-filter\n" "$sm"
        rc=1
      fi
    done < <(git config --file .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}')
  fi

  return "$rc"
}
run_check "CI path-filter coverage" ci_filter_check

# --- Warn about untracked lintable files ---
if [[ "$WARN_UNTRACKED" == true ]]; then
  manifest_list=$(printf '%s\n' "${DOCKERFILES[@]}" "${SHELL_SCRIPTS[@]}" "${WORKFLOWS[@]}" "${JSON_FILES[@]}" "${CONFIG_FILES[@]}")
  untracked=()
  while IFS= read -r f; do
    if ! printf '%s\n' "$manifest_list" | grep -qxF "$f"; then
      untracked+=("$f")
    fi
  done < <(git ls-files --cached --others --exclude-standard \
    -- 'Dockerfile*' '**/Dockerfile*' '*.sh' '**/*.sh' '*.yml' '**/*.yml' \
    '*.yaml' '**/*.yaml' '*.json' '**/*.json' | sort -u)
  if [[ ${#untracked[@]} -gt 0 ]]; then
    warnings=${#untracked[@]}
    printf '\n%s%sWarning: %d file(s) not in lint.sh manifest:%s\n' "${YELLOW}" "${BOLD}" "$warnings" "${RESET}"
    for f in "${untracked[@]}"; do
      printf '%s  %s%s\n' "${YELLOW}" "$f" "${RESET}"
    done
  fi
fi

# --- Summary ---
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${BOLD}" "${RESET}"
if [[ $failures -eq 0 ]]; then
  printf '%s%sAll %d checks passed.%s\n' "${GREEN}" "${BOLD}" "$checked" "${RESET}"
else
  printf '%s%s%d of %d checks failed.%s\n' "${RED}" "${BOLD}" "$failures" "$checked" "${RESET}"
fi
if [[ $warnings -gt 0 ]]; then
  printf '%s%s%d warning(s).%s\n' "${YELLOW}" "${BOLD}" "$warnings" "${RESET}"
fi
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "${BOLD}" "${RESET}"

exit "$failures"
