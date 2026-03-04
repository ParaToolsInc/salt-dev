#!/usr/bin/env bash
set -euo pipefail
#
# build-devtools.sh — Build the salt-dev-tools image with Intel IFX compilers.
#
# Automates the full pipeline: build devtools image from a base image, install
# Intel IFX inside a temporary container, commit the result, and tag it.
#
# Usage:
#   bash build-devtools.sh [options]
#
# Options:
#   -h, --help                 Print this help and exit
#   --base=<image:tag>         Base image (default: salt-dev:latest)
#   --tag=<tag>                Output tag (default: intel-2025.2)
#   --ifx-version=<version>    Intel IFX version (default: 2025.2)
#   --builder=<name>           Buildx builder for devtools stage (default: desktop-linux)
#   --skip-devtools-build      Skip the Dockerfile.devtools build; use existing salt-dev-tools:latest
#   --no-intel                 Skip Intel IFX installation
#   --no-push                  Don't push to Docker Hub
#   --push-repo=<repo>         Docker Hub repo (default: paratools/salt-dev-tools)
#
# Examples:
#   bash build-devtools.sh
#   bash build-devtools.sh --base=paratools/salt-dev:1.3
#   bash build-devtools.sh --ifx-version=2025.3 --tag=intel-2025.3
#   bash build-devtools.sh --skip-devtools-build
#   bash build-devtools.sh --no-push
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

cleanup() {
  if [[ -n "${CONTAINER_NAME:-}" ]]; then
    if docker inspect "$CONTAINER_NAME" &>/dev/null; then
      info "Cleaning up container: $CONTAINER_NAME"
      docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

###############################################################################
# Defaults
###############################################################################

# Prefer local salt-dev image; fall back to Docker Hub if not present
if docker image inspect salt-dev:latest &>/dev/null; then
  BASE_IMAGE="salt-dev"
else
  BASE_IMAGE="paratools/salt-dev"
fi
BASE_TAG="latest"
OUTPUT_TAG="intel-2025.2"
IFX_VERSION="2025.2"
BUILDER="desktop-linux"
SKIP_DEVTOOLS_BUILD=false
INSTALL_INTEL=true
DO_PUSH=true
PUSH_REPO="paratools/salt-dev-tools"
CONTAINER_NAME="salt-devtools-build-$$"

###############################################################################
# Option parsing
###############################################################################

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)              usage ;;
    --base=*)
      base_arg="${1#--base=}"
      if [[ "$base_arg" == *:* ]]; then
        BASE_IMAGE="${base_arg%%:*}"
        BASE_TAG="${base_arg#*:}"
      else
        BASE_IMAGE="$base_arg"
      fi
      shift
      ;;
    --tag=*)                OUTPUT_TAG="${1#--tag=}"; shift ;;
    --ifx-version=*)        IFX_VERSION="${1#--ifx-version=}"; shift ;;
    --builder=*)            BUILDER="${1#--builder=}"; shift ;;
    --skip-devtools-build)  SKIP_DEVTOOLS_BUILD=true; shift ;;
    --no-intel)             INSTALL_INTEL=false; shift ;;
    --no-push)              DO_PUSH=false; shift ;;
    --push-repo=*)          PUSH_REPO="${1#--push-repo=}"; shift ;;
    -*)                     die "Unknown option: $1" ;;
    *)                      die "Unexpected argument: $1" ;;
  esac
done

###############################################################################
# Locate repo root
###############################################################################

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$REPO_ROOT" ]]; then
  # Try worktree common dir
  REPO_ROOT="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)/.." && pwd)"
fi
if [[ ! -f "${REPO_ROOT}/Dockerfile.devtools" ]]; then
  die "Cannot find Dockerfile.devtools in repo root: ${REPO_ROOT}"
fi

###############################################################################
# Stage 1: Build Dockerfile.devtools
###############################################################################

if [[ "$SKIP_DEVTOOLS_BUILD" == false ]]; then
  info "Building salt-dev-tools from ${BASE_IMAGE}:${BASE_TAG} (builder: ${BUILDER})"
  docker buildx build \
    --builder "$BUILDER" \
    -f "${REPO_ROOT}/Dockerfile.devtools" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "BASE_TAG=${BASE_TAG}" \
    -t salt-dev-tools:latest \
    --load \
    "$REPO_ROOT"
  info "Devtools image built: salt-dev-tools:latest"
else
  info "Skipping devtools build (--skip-devtools-build)"
  if ! docker image inspect salt-dev-tools:latest &>/dev/null; then
    die "salt-dev-tools:latest not found; remove --skip-devtools-build to build it"
  fi
fi

###############################################################################
# Push devtools (non-Intel) to Docker Hub
###############################################################################

if [[ "$DO_PUSH" == true ]]; then
  info "Pushing salt-dev-tools:latest to ${PUSH_REPO}:latest"
  docker tag salt-dev-tools:latest "${PUSH_REPO}:latest"
  docker push "${PUSH_REPO}:latest"
else
  info "Skipping push (--no-push)"
fi

###############################################################################
# Stage 2: Install Intel IFX (local only — not pushed)
###############################################################################

if [[ "$INSTALL_INTEL" == true ]]; then
  info "Installing Intel IFX ${IFX_VERSION} in temporary container: ${CONTAINER_NAME}"
  docker run \
    --name "$CONTAINER_NAME" \
    salt-dev-tools:latest \
    bash -c "sudo install-intel-ifx.sh --trust-intel-repo ${IFX_VERSION} \
      && echo 'source /opt/intel/oneapi/env.sh' >> ~/.bashrc"

  info "Committing container as salt-dev-tools:${OUTPUT_TAG} (local only)"
  # Reset CMD to interactive shell; docker commit inherits the container's
  # bash -c "install..." command otherwise
  docker commit --change 'CMD ["/bin/bash"]' "$CONTAINER_NAME" "salt-dev-tools:${OUTPUT_TAG}"

  info "Removing temporary container"
  docker rm "$CONTAINER_NAME" >/dev/null
  # Clear the name so the EXIT trap doesn't try again
  CONTAINER_NAME=""
else
  info "Skipping Intel IFX installation (--no-intel)"
fi

###############################################################################
# Summary
###############################################################################

info "Done! Tagged images:"
docker images salt-dev-tools --format '  {{.Repository}}:{{.Tag}}  {{.Size}}  {{.CreatedSince}}'
