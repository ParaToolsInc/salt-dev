#!/usr/bin/env bash
set -euo pipefail
#
# run-salt-dev.sh — Launch a salt-dev container with sensible defaults.
#
# Usage:
#   bash run-salt-dev.sh [options] [image[:tag]]
#
# Options:
#   -h, --help                 Print this help and exit
#   --no-tmpfs                 Omit the --tmpfs flag entirely
#   --tmpfs=<path>             Replace /dev/shm with <path> in tmpfs mount
#   --no-privileged            Omit the --privileged flag
#   --no-claude                Don't pass CLAUDE_CODE_OAUTH_TOKEN
#   --no-gh                    Don't pass GH_TOKEN
#   --mount=<local>[:<ctr>]    Override bind mount (container default: /home/salt/src)
#   --match-user               Pass --user $(id -u):$(id -g) to match host UID/GID
#   --user=<uid>[:<gid>]       Explicit --user override for docker run
#   --git-name=<name>          Override git author name
#   --git-email=<email>        Override git author email
#
# Examples:
#   bash run-salt-dev.sh
#   bash run-salt-dev.sh --no-privileged --no-claude
#   bash run-salt-dev.sh --mount=/tmp/work:/workspace myimage:latest
#   bash run-salt-dev.sh paratools/salt-dev-tools
#

###############################################################################
# Helpers
###############################################################################

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '/^# Usage:/,/^$/{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
}

###############################################################################
# Defaults
###############################################################################

DEFAULT_IMAGE="salt-dev-tools"
DEFAULT_TAG="intel-2025.2"
CONTAINER_MOUNT="/home/salt/src"

use_tmpfs=true
tmpfs_path="/dev/shm"
use_privileged=true
pass_claude=true
pass_gh=true
mount_local="$(pwd)"
mount_container="$CONTAINER_MOUNT"
docker_user=""
git_name=""
git_email=""
image=""
tag=""

###############################################################################
# Option parsing
###############################################################################

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)        usage ;;
    --no-tmpfs)       use_tmpfs=false; shift ;;
    --tmpfs=*)        tmpfs_path="${1#--tmpfs=}"; shift ;;
    --no-privileged)  use_privileged=false; shift ;;
    --no-claude)      pass_claude=false; shift ;;
    --no-gh)          pass_gh=false; shift ;;
    --match-user)     docker_user="$(id -u):$(id -g)"; shift ;;
    --user=*)         docker_user="${1#--user=}"; shift ;;
    --mount=*)
      mount_arg="${1#--mount=}"
      if [[ "$mount_arg" == *:* ]]; then
        mount_local="${mount_arg%%:*}"
        mount_container="${mount_arg#*:}"
      else
        mount_local="$mount_arg"
        mount_container="$CONTAINER_MOUNT"
      fi
      shift
      ;;
    --git-name=*)     git_name="${1#--git-name=}"; shift ;;
    --git-email=*)    git_email="${1#--git-email=}"; shift ;;
    -*)               die "Unknown option: $1" ;;
    *)
      # Positional arg: image[:tag]
      if [[ -n "$image" ]]; then
        die "Unexpected argument: $1 (image already set to $image)"
      fi
      if [[ "$1" == *:* ]]; then
        image="${1%%:*}"
        tag="${1#*:}"
      else
        image="$1"
      fi
      shift
      ;;
  esac
done

###############################################################################
# Git identity resolution
###############################################################################

if [[ -z "$git_name" ]]; then
  git_name="$(git config --global user.name 2>/dev/null || true)"
  if [[ -z "$git_name" ]]; then
    warn "Git author name not configured; set via --git-name= or 'git config --global user.name'"
  fi
fi

if [[ -z "$git_email" ]]; then
  git_email="$(git config --global user.email 2>/dev/null || true)"
  if [[ -z "$git_email" ]]; then
    warn "Git author email not configured; set via --git-email= or 'git config --global user.email'"
  fi
fi

###############################################################################
# Image & tag resolution
###############################################################################

if [[ -z "$image" ]]; then
  # No positional arg: use full defaults, no picker
  image="$DEFAULT_IMAGE"
  tag="$DEFAULT_TAG"
elif [[ -z "$tag" ]]; then
  # Collect available tags
  mapfile -t local_tags < <(
    docker images "$image" --format '{{.Tag}}' 2>/dev/null | sort -u || true
  )

  remote_tags=()
  # Attempt DockerHub tag query (silently skip on failure)
  if [[ "$image" == */* ]]; then
    hub_repo="$image"
  else
    hub_repo="library/$image"
  fi
  mapfile -t remote_tags < <(
    curl -sfL "https://hub.docker.com/v2/repositories/${hub_repo}/tags/?page_size=25" 2>/dev/null \
      | jq -r '.results[]?.name // empty' 2>/dev/null \
      | sort -u || true
  )

  # Merge and deduplicate
  mapfile -t all_tags < <(
    printf '%s\n' "${local_tags[@]}" "${remote_tags[@]}" | grep -v '^$' | sort -u
  )

  if [[ ${#all_tags[@]} -eq 0 ]]; then
    info "No tags found for '$image'; using default tag '$DEFAULT_TAG'"
    tag="$DEFAULT_TAG"
  elif [[ ${#all_tags[@]} -eq 1 ]]; then
    tag="${all_tags[0]}"
    info "Auto-selected only available tag: $tag"
  elif [[ ! -t 0 ]]; then
    # Non-interactive: fall back to default tag
    info "Multiple tags found but stdin is not a terminal; using default tag '$DEFAULT_TAG'"
    tag="$DEFAULT_TAG"
  else
    # Interactive tag picker
    info "Available tags for '$image':"
    PS3="Select tag number: "
    select tag in "${all_tags[@]}"; do
      if [[ -n "$tag" ]]; then
        break
      fi
      echo "Invalid selection, try again." >&2
    done
  fi
fi

full_image="${image}:${tag}"
info "Using image: $full_image"

###############################################################################
# Build docker run command
###############################################################################

cmd=(docker run -it --rm)

# tmpfs
if [[ "$use_tmpfs" == true ]]; then
  cmd+=(--tmpfs="${tmpfs_path}:rw,nosuid,nodev,exec")
fi

# privileged
if [[ "$use_privileged" == true ]]; then
  cmd+=(--privileged)
fi

# User override
if [[ -n "$docker_user" ]]; then
  cmd+=(--user "$docker_user")
fi

# Bind mount
cmd+=(-v "${mount_local}:${mount_container}")

# Git worktree support: the .git file in a worktree contains an absolute host
# path (gitdir: /path/to/.git/worktrees/<name>). Mount the main repo's .git
# directory at its host path so git can resolve the reference inside the container.
if [[ -f "${mount_local}/.git" ]]; then
  git_common_dir="$(cd "$mount_local" && git rev-parse --git-common-dir 2>/dev/null)" || true
  if [[ -n "$git_common_dir" && -d "$git_common_dir" ]]; then
    warn "Mount source is a git worktree; adding bind mount for git directory"
    cmd+=(-v "${git_common_dir}:${git_common_dir}")
  fi
fi

# Git identity (entrypoint propagates to git config --global, covering committer too)
if [[ -n "$git_name" ]]; then
  cmd+=(-e "GIT_AUTHOR_NAME=${git_name}")
fi
if [[ -n "$git_email" ]]; then
  cmd+=(-e "GIT_AUTHOR_EMAIL=${git_email}")
fi

# Claude token
if [[ "$pass_claude" == true && -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  cmd+=(-e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}")
fi

# GH token
if [[ "$pass_gh" == true && -n "${GH_TOKEN:-}" ]]; then
  cmd+=(-e "GH_TOKEN=${GH_TOKEN}")
fi

# Image
cmd+=("$full_image")

###############################################################################
# Exec
###############################################################################

# Display command with proper quoting and sensitive values redacted
display_cmd=""
after_e=false
for arg in "${cmd[@]}"; do
  # Redact sensitive token values
  arg="${arg/CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}/CLAUDE_CODE_OAUTH_TOKEN=***}"
  arg="${arg/GH_TOKEN=${GH_TOKEN:-}/GH_TOKEN=***}"
  if [[ "$after_e" == true && "$arg" =~ ^([A-Z_]+)=(.*) ]]; then
    # -e KEY=VALUE: quote the value portion
    display_cmd+="${BASH_REMATCH[1]}=\"${BASH_REMATCH[2]}\" "
  elif [[ "$arg" =~ [[:space:]] ]]; then
    display_cmd+="\"${arg}\" "
  else
    display_cmd+="${arg} "
  fi
  [[ "$arg" == "-e" ]] && after_e=true || after_e=false
done
info "Running: ${display_cmd% }"
exec "${cmd[@]}"
