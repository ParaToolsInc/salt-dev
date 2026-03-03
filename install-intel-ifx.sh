#!/usr/bin/env bash
# install-intel-ifx.sh — Install Intel IFX Fortran compiler (and icx/icpx C/C++)
# inside the salt-dev-tools Docker container.
#
# Usage:
#   ./install-intel-ifx.sh [OPTIONS] [VERSION]
#
# Options:
#   --trust-intel-repo   Accept [trusted=yes] for Intel APT repo on Debian 13+
#                        (bypasses interactive prompt; TLS still protects download)
#
# Examples:
#   ./install-intel-ifx.sh                        # installs 2025.2 (default)
#   ./install-intel-ifx.sh 2025.3                 # installs 2025.3
#   ./install-intel-ifx.sh 2025.0                 # installs 2025.0
#   ./install-intel-ifx.sh 2024.1                 # installs 2024.1
#   ./install-intel-ifx.sh latest                 # installs latest available
#   ./install-intel-ifx.sh --trust-intel-repo     # non-interactive Debian 13+
#   ./install-intel-ifx.sh --trust-intel-repo 2025.3  # both options combined
#
# After installation, source the generated environment file:
#   source /opt/intel/oneapi/env.sh
#
# Or add it to your shell profile:
#   echo 'source /opt/intel/oneapi/env.sh' >> ~/.bashrc
#
# Based on: https://github.com/fortran-lang/setup-fortran

set -euo pipefail

###############################################################################
# Configuration
###############################################################################

DEFAULT_VERSION="2025.2"
TRUST_INTEL_REPO=false
VERSION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --trust-intel-repo) TRUST_INTEL_REPO=true; shift ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) VERSION="$1"; shift ;;
  esac
done
VERSION="${VERSION:-$DEFAULT_VERSION}"

INTEL_GPG_KEY_URL="https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB"
INTEL_REPO_URL="https://apt.repos.intel.com/oneapi"
INTEL_KEYRING="/usr/share/keyrings/intel-oneapi-archive-keyring.gpg"
INTEL_REPO_LIST="/etc/apt/sources.list.d/intel-oneapi.list"
ENV_FILE="/opt/intel/oneapi/env.sh"

###############################################################################
# Helpers
###############################################################################

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

# Run a command with root privileges
as_root() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  elif command -v sudo > /dev/null 2>&1; then
    sudo "$@"
  else
    die "This script requires root privileges. Run as root or install sudo."
  fi
}

###############################################################################
# Version mapping (mirrors setup-fortran's intel_version_map_l for non-classic)
###############################################################################

resolve_package_version() {
  local input_version="$1"
  case "$input_version" in
    latest)
      echo "latest"
      ;;
    2025.3 | 2025.3.0 | 2025.3.1 | 2025.3.2)
      echo "2025.3"
      ;;
    2025.2 | 2025.2.0 | 2025.2.1)
      echo "2025.2"
      ;;
    2025.1 | 2025.1.0 | 2025.1.1 | 2025.1.2 | 2025.1.3)
      echo "2025.1"
      ;;
    2025.0 | 2025.0.0 | 2025.0.1)
      echo "2025.0"
      ;;
    2024.1 | 2024.1.0)
      echo "2024.1"
      ;;
    2024.0 | 2024.0.0)
      echo "2024.0"
      ;;
    2023.2 | 2023.1 | 2023.0 | 2022.2 | 2022.1 | 2021.4 | 2021.2)
      echo "${input_version}.0"
      ;;
    2022.0.0 | 2022.0)
      echo "2022.0.2"
      ;;
    2021.1)
      echo "2021.1.1"
      ;;
    *)
      # Pass through as-is (handles already-resolved versions like 2023.2.0)
      echo "$input_version"
      ;;
  esac
}

###############################################################################
# Pre-flight checks
###############################################################################

# Detect Debian version and handle Intel APT signature issues on Debian 13+.
# Debian 13 (trixie) uses sqv instead of gpg for APT signature verification,
# and sqv rejects Intel's OpenPGP key format. TLS still protects downloads.
INTEL_REPO_TRUSTED=""
detect_debian_version() {
  local version_id=""
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    version_id=$(. /etc/os-release && echo "${VERSION_ID:-}")
  fi
  if [ -n "$version_id" ] && [ "$version_id" -ge 13 ] 2>/dev/null; then
    if [ "$TRUST_INTEL_REPO" = true ]; then
      info "Debian ${version_id} detected; --trust-intel-repo set, using [trusted=yes]."
      INTEL_REPO_TRUSTED="yes"
    else
      warn "Debian ${version_id} detected."
      warn "Intel's APT repository GPG key uses an OpenPGP format that Debian 13+'s"
      warn "signature verifier (sqv) cannot process. APT signature verification will fail."
      warn ""
      warn "Options:"
      warn "  1) Continue with [trusted=yes] — bypasses signature check (TLS still protects download)"
      warn "  2) Abort and wait for Intel to update their repository signing key"
      warn ""
      warn "To skip this prompt, re-run with --trust-intel-repo"
      echo ""
      read -r -p "Continue with [trusted=yes]? [y/N] " answer
      case "$answer" in
        [yY]|[yY][eE][sS])
          info "Proceeding with [trusted=yes] for Intel repository."
          INTEL_REPO_TRUSTED="yes"
          ;;
        *)
          die "Aborted. Re-run when Intel fixes their APT repository signing."
          ;;
      esac
    fi
  fi
}

preflight() {
  # Verify we're on Linux
  [ "$(uname -s)" = "Linux" ] || die "This script only supports Linux."

  # Verify we're on a Debian/Ubuntu system with apt
  command -v apt-get > /dev/null 2>&1 || die "apt-get not found. This script requires a Debian-based system."

  # Verify we have a download tool
  if command -v curl > /dev/null 2>&1; then
    FETCH="curl -fsSL"
  elif command -v wget > /dev/null 2>&1; then
    FETCH="wget -qO -"
  else
    die "Neither curl nor wget found. Install one first."
  fi

  # Verify gpg is available (needed for keyring creation)
  command -v gpg > /dev/null 2>&1 || die "gpg not found. Install gnupg first."

  detect_debian_version
}

###############################################################################
# Install Intel oneAPI APT repository
###############################################################################

setup_intel_repo() {
  info "Adding Intel oneAPI APT repository..."

  # Download and verify GPG key using modern signed-by approach
  # (apt-key is deprecated on Debian 12+)
  local tmpkey
  tmpkey=$(mktemp)
  $FETCH "$INTEL_GPG_KEY_URL" > "$tmpkey" \
    || die "Failed to download Intel GPG key from $INTEL_GPG_KEY_URL"

  as_root gpg --batch --yes --dearmor -o "$INTEL_KEYRING" < "$tmpkey"
  rm -f "$tmpkey"

  # Add the repository with the signed-by keyring
  local repo_opts="arch=amd64 signed-by=${INTEL_KEYRING}"
  if [ "$INTEL_REPO_TRUSTED" = "yes" ]; then
    repo_opts="arch=amd64 trusted=yes"
  fi
  echo "deb [${repo_opts}] ${INTEL_REPO_URL} all main" \
    | as_root tee "$INTEL_REPO_LIST" > /dev/null

  info "Updating package lists..."
  as_root apt-get update -o Dir::Etc::sourcelist="$INTEL_REPO_LIST" \
    -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" 2>&1 \
    || as_root apt-get update
}

###############################################################################
# Install Intel compiler packages
###############################################################################

install_packages() {
  local pkg_version="$1"

  if [ "$pkg_version" = "latest" ]; then
    info "Installing latest Intel oneAPI compilers..."
    as_root apt-get install -y --no-install-recommends \
      intel-oneapi-compiler-fortran \
      intel-oneapi-compiler-dpcpp-cpp
  else
    info "Installing Intel oneAPI compilers version ${pkg_version}..."

    # Package names changed in 2024+: dpcpp-cpp-and-cpp-classic → dpcpp-cpp
    case "$pkg_version" in
      2024* | 2025*)
        as_root apt-get install -y --no-install-recommends \
          "intel-oneapi-compiler-fortran-${pkg_version}" \
          "intel-oneapi-compiler-dpcpp-cpp-${pkg_version}"
        ;;
      *)
        as_root apt-get install -y --no-install-recommends \
          "intel-oneapi-compiler-fortran-${pkg_version}" \
          "intel-oneapi-compiler-dpcpp-cpp-and-cpp-classic-${pkg_version}"
        ;;
    esac
  fi
}

###############################################################################
# Generate sourceable environment file
###############################################################################

generate_env_file() {
  info "Generating environment file at ${ENV_FILE}..."

  local setvars="/opt/intel/oneapi/setvars.sh"
  [ -f "$setvars" ] || die "Intel setvars.sh not found at ${setvars}. Installation may have failed."

  # Source setvars.sh in a subshell and capture the environment delta.
  # We compare environment before/after to extract only Intel-added variables.
  local env_before env_after
  env_before=$(env | sort)

  # setvars.sh uses set +e internally, so we must allow that
  set +eu
  # shellcheck source=/dev/null
  source "$setvars" > /dev/null 2>&1
  set -eu

  env_after=$(env | sort)

  # Build the env file from the diff
  as_root mkdir -p "$(dirname "$ENV_FILE")"
  {
    echo "#!/usr/bin/env bash"
    echo "# Intel oneAPI environment — auto-generated by install-intel-ifx.sh"
    echo "# Source this file to activate Intel compilers:"
    echo "#   source ${ENV_FILE}"
    echo ""

    # Export variables that were added or changed
    comm -13 <(echo "$env_before") <(echo "$env_after") | while IFS= read -r line; do
      varname="${line%%=*}"
      # Skip internal/transient variables
      case "$varname" in
        BASH_FUNC_*|_|SHLVL|OLDPWD|SETVARS_CALL|TBBROOT) continue ;;
      esac
      echo "export ${line}"
    done

    echo ""
    echo "# Compiler aliases"
    echo "export FC=ifx"
    echo "export CC=icx"
    echo "export CXX=icpx"
  } | as_root tee "$ENV_FILE" > /dev/null

  as_root chmod 644 "$ENV_FILE"
}

###############################################################################
# Verify installation
###############################################################################

verify() {
  info "Verifying Intel compiler installation..."

  # Source the environment we just generated
  # shellcheck source=/dev/null
  source "$ENV_FILE"

  local failed=0
  for compiler in ifx icx icpx; do
    if command -v "$compiler" > /dev/null 2>&1; then
      info "  ${compiler}: $($compiler --version | head -n1)"
    else
      warn "  ${compiler}: NOT FOUND in PATH"
      failed=1
    fi
  done

  if [ "$failed" -eq 1 ]; then
    die "One or more Intel compilers not found. Check the installation."
  fi

  # Quick compile test
  info "Running Fortran compile test..."
  local tmpdir
  tmpdir=$(mktemp -d)
  cat > "${tmpdir}/hello.f90" <<'FORTRAN'
program hello
  implicit none
  print *, "Hello from Intel IFX!"
end program hello
FORTRAN

  if ifx -o "${tmpdir}/hello" "${tmpdir}/hello.f90" && "${tmpdir}/hello"; then
    info "Compile test passed."
  else
    warn "Compile test failed — compiler is installed but may have runtime issues."
  fi
  rm -rf "$tmpdir"
}

###############################################################################
# Main
###############################################################################

main() {
  local pkg_version
  pkg_version=$(resolve_package_version "$VERSION")

  info "Intel IFX installer for salt-dev-tools"
  info "  Requested version: ${VERSION}"
  info "  Package version:   ${pkg_version}"
  echo ""

  preflight
  setup_intel_repo
  install_packages "$pkg_version"
  generate_env_file
  verify

  echo ""
  info "Installation complete!"
  info ""
  info "To activate Intel compilers in your current shell:"
  info "  source ${ENV_FILE}"
  info ""
  info "To activate automatically on login:"
  info "  echo 'source ${ENV_FILE}' >> ~/.bashrc"
}

main
