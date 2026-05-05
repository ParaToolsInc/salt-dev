#!/usr/bin/env bash
# Claude Code status line - inspired by Liquid Prompt style
# Receives JSON input via stdin

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
session_short=$(echo "$input" | jq -r '.session_id // empty' | cut -c1-8)
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# Sum all token types from current_usage to get tokens used in the current context
tokens_used=$(echo "$input" | jq -r '
  (.context_window.current_usage // null) as $u |
  if $u == null then empty
  else (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0) + ($u.cache_creation_input_tokens // 0)) | tostring
  end
')
max_tokens=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .workspace.current_dir // .cwd // empty')

user=$(whoami)
host=$(hostname -s)

# Shorten home directory to ~ using explicit conditional checks
short_cwd="$cwd"
home_literal="/Users/${user}"
# shellcheck disable=SC2088 # Intentional literal ~ for display
if [[ "$cwd" == "${home_literal}/"* ]]; then
    short_cwd="~/${cwd#"${home_literal}"/}"
elif [[ "$cwd" == "${home_literal}" ]]; then
    short_cwd="~"
elif [[ -n "$HOME" && "$cwd" == "${HOME}/"* ]]; then
    short_cwd="~/${cwd#"${HOME}"/}"
elif [[ -n "$HOME" && "$cwd" == "${HOME}" ]]; then
    short_cwd="~"
fi

# Effort level: walk settings hierarchy (project.local > project > user)
# Falls back to "high" which is the Claude Code default when not explicitly set.
effort=""
for settings_file in \
    "${project_dir}/.claude/settings.local.json" \
    "${project_dir}/.claude/settings.json" \
    "${HOME}/.claude/settings.json"; do
    if [ -f "$settings_file" ]; then
        val=$(jq -r '.effortLevel // empty' "$settings_file" 2>/dev/null)
        if [ -n "$val" ]; then
            effort="$val"
            break
        fi
    fi
done
# Always show effort level; default to "high" when not set in any config file.
if [ -z "$effort" ]; then
    effort="high"
fi

# Git branch (skip optional locks)
git_branch=""
if git_out=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null); then
    git_branch="$git_out"
elif git_out=$(git -C "$cwd" --no-optional-locks describe --tags --exact-match HEAD 2>/dev/null); then
    git_branch="$git_out"
fi

# Git file counts (only when inside a git repo)
git_counts=""
if [ -n "$git_branch" ] || git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    untracked=0
    staged=0
    changed=0
    while IFS= read -r line; do
        x="${line:0:1}"
        y="${line:1:1}"
        if [ "$x" = "?" ] && [ "$y" = "?" ]; then
            (( untracked += 1 ))
        else
            if [ "$x" != " " ] && [ "$x" != "?" ]; then (( staged += 1 )); fi
            if [ "$y" != " " ] && [ "$y" != "?" ]; then (( changed += 1 )); fi
        fi
    done < <(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
    stashes=$(git -C "$cwd" --no-optional-locks stash list 2>/dev/null | wc -l | tr -d ' ')

    parts=""
    [ "$untracked" -gt 0 ] && parts="${parts}?${untracked} "
    [ "$staged" -gt 0 ]    && parts="${parts}+${staged} "
    [ "$changed" -gt 0 ]   && parts="${parts}~${changed} "
    [ "$stashes" -gt 0 ]   && parts="${parts}{${stashes} "
    git_counts="${parts% }"  # strip trailing space
fi

# Format an integer token count as compact "k" notation.
# < 100000  -> 1 decimal place, e.g. 21400 -> "21.4k"
# >= 100000 -> integer,          e.g. 200000 -> "200k"
format_k() {
    local n="$1"
    if [ -z "$n" ] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo ""
        return
    fi
    if [ "$n" -lt 100000 ]; then
        # one decimal: multiply by 10, divide by 1000, then insert the dot
        local tenths=$(( (n * 10) / 1000 ))
        local whole=$(( tenths / 10 ))
        local frac=$(( tenths % 10 ))
        echo "${whole}.${frac}k"
    else
        echo "$(( n / 1000 ))k"
    fi
}

# Claude brand color palette using 256-color ANSI codes:
#   orange    (#D97757 approx) -> 173  user@host
#   tan/beige (#E8D5B7 approx) -> 223  path
#   muted warm rose            -> 138  separator/punctuation
#   off-white                  -> 253  git branch
#   warm taupe                 -> 181  model/context bracket
RESET=$'\033[0m'
ORANGE=$'\033[38;5;173m'   # warm orange/terracotta - user@host
TAN=$'\033[38;5;223m'      # tan/beige - path
SEPARATOR=$'\033[38;5;138m' # muted warm rose - colon separator
OFFWHITE=$'\033[38;5;253m' # soft off-white - git branch
TAUPE=$'\033[38;5;181m'    # warm taupe - model/context info

printf '%s%s@%s%s%s:%s%s%s%s' "$ORANGE" "$user" "$host" "$RESET" "$SEPARATOR" "$RESET" "$TAN" "$short_cwd" "$RESET"

if [ -n "$git_branch" ]; then
    if [ -n "$git_counts" ]; then
        printf ' %s(%s%s %s%s%s)%s' "$SEPARATOR" "$OFFWHITE" "$git_branch" "$SEPARATOR" "$git_counts" "$SEPARATOR" "$RESET"
    else
        printf ' %s(%s%s%s)%s' "$SEPARATOR" "$OFFWHITE" "$git_branch" "$SEPARATOR" "$RESET"
    fi
fi

if [ -n "$model" ]; then
    printf ' %s[%s%s' "$SEPARATOR" "$TAUPE" "$model"
    if [ -n "$effort" ]; then
        printf ' %s(%s%s%s)%s%s' "$SEPARATOR" "$TAUPE" "$effort" "$SEPARATOR" "$RESET" "$TAUPE"
    fi
    if [ -n "$session_short" ]; then
        printf ' %s#%s%s' "$SEPARATOR" "$TAUPE" "$session_short"
    fi
    if [ -n "$remaining" ]; then
        used_k=$(format_k "$tokens_used")
        max_k=$(format_k "$max_tokens")
        if [ -n "$used_k" ] && [ -n "$max_k" ]; then
            # Full form: ctx: 21.4k/200k (89% left)
            printf '%s | %sctx: %s/%s (%s%% left)' "$SEPARATOR" "$TAUPE" "$used_k" "$max_k" "$remaining"
        else
            # Fallback: ctx: 89%
            printf '%s | %sctx: %s%%' "$SEPARATOR" "$TAUPE" "$remaining"
        fi
    fi
    # Rate limit remaining (only shown when data is available, i.e. after first API response)
    if [ -n "$five_hour" ] || [ -n "$seven_day" ]; then
        printf '%s | %s' "$SEPARATOR" "$TAUPE"
        if [ -n "$five_hour" ]; then
            five_remaining=$(printf '%.0f' "$(echo "$five_hour" | awk '{print 100 - $1}')")
            reset_str=""
            if [ -n "$five_hour_resets" ] && [[ "$five_hour_resets" =~ ^[0-9]+$ ]]; then
                now=$(date +%s)
                secs_left=$(( five_hour_resets - now ))
                if [ "$secs_left" -gt 0 ]; then
                    mins_left=$(( secs_left / 60 ))
                    if [ "$mins_left" -ge 60 ]; then
                        hrs=$(( mins_left / 60 ))
                        mins=$(( mins_left % 60 ))
                        reset_str=" rst:${hrs}h${mins}m"
                    else
                        reset_str=" rst:${mins_left}m"
                    fi
                fi
            fi
            printf '5h:%s%%%s' "$five_remaining" "$reset_str"
        fi
        if [ -n "$five_hour" ] && [ -n "$seven_day" ]; then
            printf ' '
        fi
        if [ -n "$seven_day" ]; then
            seven_remaining=$(printf '%.0f' "$(echo "$seven_day" | awk '{print 100 - $1}')")
            printf '7d:%s%%' "$seven_remaining"
        fi
    fi
    printf '%s]%s' "$SEPARATOR" "$RESET"
fi

# Caveman mode badge (reads flag file written by caveman-activate.js)
CAVEMAN_FLAG="${HOME}/.claude/.caveman-active"
if [ -f "$CAVEMAN_FLAG" ]; then
    caveman_mode=$(cat "$CAVEMAN_FLAG" 2>/dev/null)
    if [ -n "$caveman_mode" ]; then
        CAVEMAN_COLOR=$'\033[38;5;172m'
        if [ "$caveman_mode" = "full" ]; then
            printf ' %s[CAVEMAN]%s' "$CAVEMAN_COLOR" "$RESET"
        else
            caveman_upper=$(echo "$caveman_mode" | tr '[:lower:]' '[:upper:]')
            printf ' %s[CAVEMAN:%s]%s' "$CAVEMAN_COLOR" "$caveman_upper" "$RESET"
        fi
    fi
fi
