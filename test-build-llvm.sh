#!/usr/bin/env bash
set -euo pipefail

# test-build-llvm.sh -- Unit and integration tests for build-llvm.sh.
#
# Tier 1: Unit tests (parallelism formula + target extraction)
# Tier 2: Integration tests (mock ninja, OOM recovery flows)
#
# Usage: bash test-build-llvm.sh

# --- Color output when connected to a terminal ---
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  RED='' GREEN='' BOLD='' RESET=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="${SCRIPT_DIR}/build-llvm.sh"

# --- Test infrastructure ---
pass_count=0
fail_count=0

assert_eq() {
  local description=$1 expected=$2 actual=$3
  if [[ "$expected" = "$actual" ]]; then
    printf '%s  PASS: %s%s\n' "$GREEN" "$description" "$RESET"
    pass_count=$((pass_count + 1))
  else
    printf '%s  FAIL: %s%s\n' "$RED" "$description" "$RESET"
    printf '%s    expected: '\''%s'\''%s\n' "$RED" "$expected" "$RESET"
    printf '%s    actual:   '\''%s'\''%s\n' "$RED" "$actual" "$RESET"
    fail_count=$((fail_count + 1))
  fi
}

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ============================================================
# Tier 1: Parallelism formula
# ============================================================
echo ""
printf '%s=== Tier 1: Parallelism formula ===%s\n' "$BOLD" "$RESET"

test_compute_jobs() {
  local mock_nproc=$1 expected_jobs=$2

  local mock_bin="${TMPDIR_TEST}/mock_nproc_${mock_nproc}"
  mkdir -p "$mock_bin"
  cat > "${mock_bin}/nproc" <<NPROC
#!/usr/bin/env bash
echo ${mock_nproc}
NPROC
  chmod +x "${mock_bin}/nproc"

  local actual_jobs
  actual_jobs=$(PATH="${mock_bin}:${PATH}" bash "$BUILD_SCRIPT" --dry-run 2>/dev/null \
    | grep '^jobs=' | cut -d= -f2)

  assert_eq "nproc=${mock_nproc} -> jobs=${expected_jobs}" "$expected_jobs" "$actual_jobs"
}

test_compute_jobs 1  1
test_compute_jobs 4  4
test_compute_jobs 6  6
test_compute_jobs 9  8
test_compute_jobs 12 10
test_compute_jobs 18 14
test_compute_jobs 24 18
test_compute_jobs 30 22
test_compute_jobs 64 56

# ============================================================
# Tier 1: --avail-mem-kb dry-run output
# ============================================================
echo ""
printf '%s=== Tier 1: --avail-mem-kb dry-run ===%s\n' "$BOLD" "$RESET"

test_avail_mem_kb_in_output() {
  local output
  output=$(bash "$BUILD_SCRIPT" --dry-run --avail-mem-kb 13926400 2>/dev/null)
  local actual
  actual=$(echo "$output" | grep '^avail_mem_kb=' | cut -d= -f2)
  assert_eq "--avail-mem-kb appears in dry-run" "13926400" "$actual"
}

test_avail_mem_kb_default_empty() {
  local output
  output=$(bash "$BUILD_SCRIPT" --dry-run 2>/dev/null)
  local actual
  actual=$(echo "$output" | grep '^avail_mem_kb=' | cut -d= -f2)
  assert_eq "Default avail_mem_kb is empty" "" "$actual"
}

test_avail_mem_kb_in_output
test_avail_mem_kb_default_empty

# ============================================================
# Tier 1: Target extraction
# ============================================================
echo ""
printf '%s=== Tier 1: Target extraction ===%s\n' "$BOLD" "$RESET"

# Source the script to access extract_failed_targets directly
# shellcheck source=build-llvm.sh
source "$BUILD_SCRIPT"

test_extract_single() {
  local log_file="${TMPDIR_TEST}/extract_single.log"
  cat > "$log_file" <<'LOG'
[1234/5678] Building CXX object tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold.cpp.o
FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold.cpp.o
/usr/bin/c++ -O3 ... tools/flang/lib/Evaluate/fold.cpp
LOG
  local result
  result=$(extract_failed_targets "$log_file")
  assert_eq "Single target extraction" "FortranEvaluate" "$result"
}

test_extract_multiple() {
  local log_file="${TMPDIR_TEST}/extract_multi.log"
  cat > "$log_file" <<'LOG'
FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold-integer.cpp.o
/usr/bin/c++ -O3 ...
FAILED: tools/flang/lib/Semantics/CMakeFiles/FortranSemantics.dir/check-omp.cpp.o
/usr/bin/c++ -O3 ...
LOG
  local result
  result=$(extract_failed_targets "$log_file")
  local expected
  expected=$(printf "FortranEvaluate\nFortranSemantics")
  assert_eq "Multiple target extraction" "$expected" "$result"
}

test_extract_dedup() {
  local log_file="${TMPDIR_TEST}/extract_dedup.log"
  cat > "$log_file" <<'LOG'
FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold-integer.cpp.o
/usr/bin/c++ -O3 ...
FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold-real.cpp.o
/usr/bin/c++ -O3 ...
LOG
  local result
  result=$(extract_failed_targets "$log_file")
  assert_eq "Dedup extraction" "FortranEvaluate" "$result"
}

test_extract_none() {
  local log_file="${TMPDIR_TEST}/extract_none.log"
  cat > "$log_file" <<'LOG'
[1234/5678] Building CXX object ...
[5678/5678] Linking CXX shared library ...
LOG
  local result
  result=$(extract_failed_targets "$log_file")
  assert_eq "No FAILED lines -> empty" "" "$result"
}

test_extract_malformed() {
  local log_file="${TMPDIR_TEST}/extract_malformed.log"
  cat > "$log_file" <<'LOG'
FAILED: some random text without CMakeFiles pattern
FAILED: /usr/bin/cmake -E remove_directory foo
LOG
  local result
  result=$(extract_failed_targets "$log_file")
  assert_eq "Malformed FAILED lines -> empty" "" "$result"
}

test_extract_single
test_extract_multiple
test_extract_dedup
test_extract_none
test_extract_malformed

# ============================================================
# Tier 2: Integration tests (mock ninja)
# ============================================================
echo ""
printf '%s=== Tier 2: Integration (mock ninja) ===%s\n' "$BOLD" "$RESET"

# --- Test 1: OOM -> targeted retry -> success ---
test_oom_recovery() {
  local test_dir="${TMPDIR_TEST}/int_oom"
  local build_dir="${test_dir}/build"
  local mock_dir="${test_dir}/bin"
  local call_log="${test_dir}/calls.log"
  local counter_file="${test_dir}/counter"
  mkdir -p "$build_dir" "$mock_dir"
  echo "0" > "$counter_file"

  # Mock ninja: call 1 fails with FAILED line, call 2+3 succeed
  cat > "${mock_dir}/ninja" <<MOCK
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$((count + 1))
echo "\$count" > "${counter_file}"

jobs=""
while [[ \$# -gt 0 ]]; do
  case \$1 in
    -C) shift 2 ;;
    -j) jobs="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
echo "call=\${count} jobs=\${jobs}" >> "${call_log}"

if [[ \$count -eq 1 ]]; then
  echo "FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold.cpp.o"
  echo "ninja: build stopped: subcommand failed."
  exit 1
else
  echo "Build succeeded"
  exit 0
fi
MOCK
  chmod +x "${mock_dir}/ninja"

  local rc=0
  PATH="${mock_dir}:${PATH}" bash "$BUILD_SCRIPT" \
    --build-dir "$build_dir" --max-jobs 8 --monitor-interval 1 \
    target1 target2 > "${test_dir}/output.log" 2>&1 || rc=$?

  assert_eq "OOM recovery exits 0" "0" "$rc"

  local call_count
  call_count=$(wc -l < "$call_log" | tr -d ' ')
  assert_eq "OOM recovery makes 3 calls" "3" "$call_count"

  local second_call
  second_call=$(sed -n '2p' "$call_log")
  assert_eq "Retry uses -j4" "call=2 jobs=4" "$second_call"
}

# --- Test 2: No FAILED lines -> fallback to all targets ---
test_no_failed_lines() {
  local test_dir="${TMPDIR_TEST}/int_nofailed"
  local build_dir="${test_dir}/build"
  local mock_dir="${test_dir}/bin"
  local call_log="${test_dir}/calls.log"
  local counter_file="${test_dir}/counter"
  mkdir -p "$build_dir" "$mock_dir"
  echo "0" > "$counter_file"

  # Mock ninja: call 1 fails without FAILED pattern, call 2+ succeed
  cat > "${mock_dir}/ninja" <<MOCK
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$((count + 1))
echo "\$count" > "${counter_file}"

jobs=""
targets=""
while [[ \$# -gt 0 ]]; do
  case \$1 in
    -C) shift 2 ;;
    -j) jobs="\$2"; shift 2 ;;
    *)  targets="\${targets} \$1"; shift ;;
  esac
done
echo "call=\${count} jobs=\${jobs} targets=\${targets}" >> "${call_log}"

if [[ \$count -eq 1 ]]; then
  echo "Some error without FAILED: pattern"
  exit 1
else
  echo "Build succeeded"
  exit 0
fi
MOCK
  chmod +x "${mock_dir}/ninja"

  local rc=0
  PATH="${mock_dir}:${PATH}" bash "$BUILD_SCRIPT" \
    --build-dir "$build_dir" --max-jobs 8 --monitor-interval 1 \
    targetA targetB > "${test_dir}/output.log" 2>&1 || rc=$?

  assert_eq "No FAILED fallback exits 0" "0" "$rc"

  # Second call should retry all original targets
  local second_targets
  second_targets=$(sed -n '2p' "$call_log" | sed 's/.*targets=//')
  assert_eq "Fallback retries all targets" " targetA targetB" "$second_targets"
}

# --- Test 3: Targeted build also OOMs -> halves again ---
test_halving() {
  local test_dir="${TMPDIR_TEST}/int_halving"
  local build_dir="${test_dir}/build"
  local mock_dir="${test_dir}/bin"
  local call_log="${test_dir}/calls.log"
  local counter_file="${test_dir}/counter"
  mkdir -p "$build_dir" "$mock_dir"
  echo "0" > "$counter_file"

  # Mock ninja: calls 1-2 fail with FAILED, call 3 succeeds (quarter-j), call 4 succeeds (full)
  cat > "${mock_dir}/ninja" <<MOCK
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$((count + 1))
echo "\$count" > "${counter_file}"

jobs=""
while [[ \$# -gt 0 ]]; do
  case \$1 in
    -C) shift 2 ;;
    -j) jobs="\$2"; shift 2 ;;
    *)  shift ;;
  esac
done
echo "call=\${count} jobs=\${jobs}" >> "${call_log}"

if [[ \$count -le 2 ]]; then
  echo "FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold.cpp.o"
  exit 1
else
  echo "Build succeeded"
  exit 0
fi
MOCK
  chmod +x "${mock_dir}/ninja"

  local rc=0
  PATH="${mock_dir}:${PATH}" bash "$BUILD_SCRIPT" \
    --build-dir "$build_dir" --max-jobs 8 --monitor-interval 1 \
    target1 > "${test_dir}/output.log" 2>&1 || rc=$?

  assert_eq "Halving recovery exits 0" "0" "$rc"

  # Verify job halving sequence: 8 (full), 4 (half), 2 (quarter), 8 (full retry)
  local jobs_seq
  jobs_seq=$(awk -F'jobs=' '{print $2}' "$call_log" | tr '\n' ',' | sed 's/,$//')
  assert_eq "Job halving sequence" "8,4,2,8" "$jobs_seq"
}

# --- Test 4: Real error at -j1 ---
test_real_error() {
  local test_dir="${TMPDIR_TEST}/int_realerr"
  local build_dir="${test_dir}/build"
  local mock_dir="${test_dir}/bin"
  local counter_file="${test_dir}/counter"
  mkdir -p "$build_dir" "$mock_dir"
  echo "0" > "$counter_file"

  # Mock ninja: always fails with FAILED line
  cat > "${mock_dir}/ninja" <<MOCK
#!/usr/bin/env bash
count=\$(cat "${counter_file}")
count=\$((count + 1))
echo "\$count" > "${counter_file}"

# Create build dir if -C was given
while [[ \$# -gt 0 ]]; do
  case \$1 in
    -C) mkdir -p "\$2"; shift 2 ;;
    *)  shift ;;
  esac
done

echo "FAILED: tools/flang/lib/Evaluate/CMakeFiles/FortranEvaluate.dir/fold.cpp.o"
exit 1
MOCK
  chmod +x "${mock_dir}/ninja"

  local rc=0
  PATH="${mock_dir}:${PATH}" bash "$BUILD_SCRIPT" \
    --build-dir "$build_dir" --max-jobs 4 --monitor-interval 1 \
    target1 > "${test_dir}/output.log" 2>&1 || rc=$?

  assert_eq "Real error exits 1" "1" "$rc"
}

test_oom_recovery
test_no_failed_lines
test_halving
test_real_error

# ============================================================
# Summary
# ============================================================
echo ""
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD" "$RESET"
total=$((pass_count + fail_count))
if [[ "$fail_count" -eq 0 ]]; then
  printf '%s%sAll %d tests passed.%s\n' "$GREEN" "$BOLD" "$total" "$RESET"
else
  printf '%s%s%d of %d tests failed.%s\n' "$RED" "$BOLD" "$fail_count" "$total" "$RESET"
fi
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD" "$RESET"

exit "$fail_count"
