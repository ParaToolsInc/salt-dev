#!/usr/bin/env bash
set -euo pipefail

# build-llvm.sh — Adaptive OOM-resilient LLVM build wrapper around ninja.
#
# Maximizes parallelism, auto-recovers from OOM kills by retrying failed
# targets at progressively lower -j values, and provides CI-friendly
# progress output.
#
# Usage: build-llvm.sh [OPTIONS] target1 [target2 ...]
# Options:
#   -b, --build-dir DIR       Ninja build directory (default: /llvm-project/llvm/build)
#   -j, --max-jobs N          Override auto-computed parallelism
#   -r, --max-retries N       Max OOM retry cycles (default: 10)
#   -m, --monitor-interval N  Seconds between progress output (default: 90)
#   --avail-mem-kb N          Available memory in KB; sets per-job ulimit -v
#   --dry-run                 Print computed settings and exit

# --- Defaults ---
DEFAULT_BUILD_DIR="/llvm-project/llvm/build"
DEFAULT_MAX_RETRIES=20
DEFAULT_MONITOR_INTERVAL=90

# --- Functions ---

# Compute optimal parallel jobs based on available cores.
#   nproc <= 6  : use all cores (dedicated/small system)
#   6 < nproc < 30 : reserve floor((nproc-6)*8/24) cores (linear ramp 0->8)
#   nproc >= 30 : reserve 8 cores
compute_jobs() {
  local cores
  cores=$(nproc)
  if [[ "$cores" -le 6 ]]; then
    echo "$cores"
  elif [[ "$cores" -lt 30 ]]; then
    echo $(( cores - (cores - 6) * 8 / 24 ))
  else
    echo $(( cores - 8 ))
  fi
}

# Extract CMake target names from FAILED: lines in a ninja build log.
# Pattern: CMakeFiles/<TARGET>.dir/<file>.o -> <TARGET>
# Returns one target per line, sorted and deduplicated.
extract_failed_targets() {
  local log_file=$1
  grep '^FAILED:' "$log_file" 2>/dev/null \
    | sed -n 's|.*CMakeFiles/\([^/]*\)\.dir/.*|\1|p' \
    | sort -u || true
}

# Run ninja in background with progress monitoring.
# Outputs tail of build log periodically for CI liveness.
# Returns ninja's exit code.
run_ninja() {
  local build_dir=$1 jobs=$2 monitor_interval=$3
  shift 3
  local log_file="${build_dir}/build.log"
  local last_emitted=0

  if [[ -n "${avail_mem_kb:-}" ]]; then
    local mem_limit=$(( avail_mem_kb / jobs ))
    echo ">>> ulimit -Sv ${mem_limit} KB (${avail_mem_kb} KB / ${jobs} jobs)"
    ulimit -Sv "$mem_limit"
  fi
  echo ">>> ninja -C ${build_dir} -j${jobs} $*"
  ninja -C "${build_dir}" -j "${jobs}" "$@" > "${log_file}" 2>&1 &
  local ninja_pid=$!

  while kill -0 "$ninja_pid" 2>/dev/null; do
    tail -n 4 "${log_file}" 2>/dev/null || true
    last_emitted=$(wc -l < "${log_file}" 2>/dev/null || echo 0)
    sleep "${monitor_interval}"
  done

  local rc=0
  wait "$ninja_pid" || rc=$?
  # Emit only lines not yet shown, capped at 100
  tail -n +"$((last_emitted + 1))" "${log_file}" 2>/dev/null | tail -n 100
  return "$rc"
}

main() {
  local build_dir="$DEFAULT_BUILD_DIR"
  local max_jobs=""
  local max_retries="$DEFAULT_MAX_RETRIES"
  local monitor_interval="$DEFAULT_MONITOR_INTERVAL"
  local avail_mem_kb=""
  local dry_run=false
  local targets=()

  while [[ $# -gt 0 ]]; do
    case $1 in
      -b|--build-dir)        build_dir="$2"; shift 2 ;;
      -j|--max-jobs)         max_jobs="$2"; shift 2 ;;
      -r|--max-retries)      max_retries="$2"; shift 2 ;;
      -m|--monitor-interval) monitor_interval="$2"; shift 2 ;;
      --avail-mem-kb)        avail_mem_kb="$2"; shift 2 ;;
      --dry-run)             dry_run=true; shift ;;
      -*)                    echo "Unknown option: $1" >&2; exit 1 ;;
      *)                     targets+=("$1"); shift ;;
    esac
  done

  local high_jobs="${max_jobs:-$(compute_jobs)}"

  if [[ "$dry_run" = true ]]; then
    echo "build_dir=${build_dir}"
    echo "jobs=${high_jobs}"
    echo "max_retries=${max_retries}"
    echo "monitor_interval=${monitor_interval}"
    echo "avail_mem_kb=${avail_mem_kb}"
    echo "targets=${targets[*]:-}"
    return 0
  fi

  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "Error: no build targets specified" >&2
    return 1
  fi

  # --- Main build loop ---
  local outer_retries=0
  while [[ "$outer_retries" -lt "$max_retries" ]]; do
    # Try full build at high parallelism
    if run_ninja "$build_dir" "$high_jobs" "$monitor_interval" "${targets[@]}"; then
      return 0
    fi

    echo "*** Build failed at -j${high_jobs}, analyzing failures..."

    local log_file="${build_dir}/build.log"
    local failed_str
    failed_str=$(extract_failed_targets "$log_file")

    local failed_targets=()
    if [[ -n "$failed_str" ]]; then
      mapfile -t failed_targets <<< "$failed_str"
      echo "*** Failed targets: ${failed_targets[*]}"
    else
      echo "*** No specific targets identified, retrying all targets"
      failed_targets=("${targets[@]}")
    fi

    # Targeted recovery at progressively lower -j
    local low_j=$(( high_jobs / 2 ))
    local recovered=false
    while [[ "$low_j" -ge 1 ]]; do
      echo "*** Retrying ${failed_targets[*]} at -j${low_j}..."
      if run_ninja "$build_dir" "$low_j" "$monitor_interval" "${failed_targets[@]}"; then
        recovered=true
        break
      fi
      low_j=$(( low_j / 2 ))
    done

    if [[ "$recovered" = false ]]; then
      echo "*** Build failed even at -j1 — likely a real build error" >&2
      return 1
    fi

    outer_retries=$(( outer_retries + 1 ))
    echo "*** Recovery succeeded, retrying full build (attempt $((outer_retries + 1))/${max_retries})..."
  done

  echo "*** Exhausted ${max_retries} retries" >&2
  return 1
}

# Only run main when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  main "$@"
fi
