# syntax=docker/dockerfile:1.4
# Stage 1. Check out LLVM source code and run the build.
FROM debian:13 AS builder
LABEL maintainer="ParaTools Inc."
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# Configure apt caching for BuildKit mount reuse
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
EOC

ENV CCACHE_DIR=/ccache
RUN --mount=type=cache,id=ccache-builder,target=/ccache ls -l $CCACHE_DIR

# Install compiler, cmake, git, ccache etc.
# RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOC
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates \
    build-essential cmake ccache make python3 zlib1g wget unzip git
  cmake --version
EOC

ARG CI=false
ARG LLVM_VER=19
# Clone LLVM repo. A shallow clone is faster, but pulling a cached repository is faster yet
# cd inside heredoc script; WORKDIR can't replace it
# RUN --mount=type=cache,target=/git <<EO
# hadolint ignore=DL3003
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  echo "Checking out LLVM."
  echo "\$CI = $CI"
  # Ensure /git exists when not provided by a cache mount
  mkdir -p /git || true
  # If the job is killed during a git operation the cache might be broken
  if [ -f /git/llvm-project.git/index.lock ]; then
    echo "index.lock file found--git repo might be in a broken state."
    echo "Removing /git/llvm-project.git and forcing a new checkout!"
    rm -rf /git/llvm-project.git
  fi
  if mkdir llvm-project && git --git-dir=/git/llvm-project.git -C llvm-project pull origin release/${LLVM_VER}.x --ff-only
  then
    echo "WARNING: Using cached llvm git repository and pulling updates"
    cp -r /git/llvm-project.git /llvm-project/.git
    git -C /llvm-project reset --hard HEAD
  else
    echo "Cloning a fresh LLVM repository"
    git clone --separate-git-dir=/git/llvm-project.git \
      --single-branch \
      --branch=release/${LLVM_VER}.x \
      --filter=blob:none \
      https://github.com/llvm/llvm-project.git
    if [ -f /llvm-project/.git ]; then
      rm -f /llvm-project/.git
    fi
    cp -r /git/llvm-project.git /llvm-project/.git
  fi
  cd llvm-project/llvm
  mkdir build
  ls -lad /git/llvm-project.git
  ls -la /llvm-project/.git
  if [ -f /llvm-project/.git ]; then
    echo "Contents of .git: "
    cat /llvm-project/.git
    real_git_dir="$(cat /llvm-project/.git | cut -d ' ' -f2)"
    echo "Contents of $real_git_dir :"
    ls -lad "$real_git_dir"
    echo "$real_git_dir"/*
  fi
  git status
EOC

# Install a newer ninja release. It seems the older version in the debian repos
# randomly crashes when compiling llvm.
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  wget --no-verbose "https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-linux.zip"
  echo "5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6 ninja-linux.zip" \
    | sha256sum -c
  unzip ninja-linux.zip -d /usr/local/bin
  rm  ninja-linux.zip
EOC

COPY build-llvm.sh /usr/local/bin/
ARG NINJA_MAX_JOBS=""
# Default to ~19 GB for local docker builds
ARG AVAIL_MEM_KB=20000000

# Configure and build LLVM/Clang components needed by SALT
RUN --mount=type=cache,id=ccache-builder,target=/ccache <<EOC
#!/usr/bin/env bash
set -euo pipefail
  echo "Builder cores: $(nproc --all || lscpu || true)"
  echo "Current directory: $(pwd)"
  if ! git -C /llvm-project status ; then
    echo "llvm-project git repository missing or broken!!!"
    exit 1
  fi
  echo "CCache stats before build:"
  ccache -s

  # Configure the build
  CMAKE_EXTRA_ARGS=()
  if uname -a | grep x86 ; then CMAKE_EXTRA_ARGS+=("-DLLVM_TARGETS_TO_BUILD=X86"); fi
  cmake -GNinja \
    -DCMAKE_INSTALL_PREFIX=/tmp/llvm \
    -DCMAKE_MAKE_PROGRAM=/usr/local/bin/ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_CCACHE_BUILD=On \
    -DLLVM_ENABLE_PROJECTS="flang;clang;clang-tools-extra;mlir;openmp" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
    "${CMAKE_EXTRA_ARGS[@]}" \
    -S /llvm-project/llvm -B /llvm-project/llvm/build

  BUILD_DIR=/llvm-project/llvm/build

  BUILD_LLVM_ARGS=(--build-dir "$BUILD_DIR")
  if [ -n "${NINJA_MAX_JOBS:-}" ]; then BUILD_LLVM_ARGS+=(--max-jobs "${NINJA_MAX_JOBS}"); fi
  if [ -n "${AVAIL_MEM_KB:-}" ]; then BUILD_LLVM_ARGS+=(--avail-mem-kb "${AVAIL_MEM_KB}"); fi

  NON_FLANG_TARGETS=(
    install-llvm-libraries install-llvm-headers install-llvm-config install-cmake-exports
    install-clang-libraries install-clang-headers install-clang install-clang-cmake-exports
    install-clang-resource-headers
    install-mlir-headers install-mlir-libraries install-mlir-cmake-exports
    install-openmp-resource-headers
    install-compiler-rt
  )

  FLANG_TARGETS=(
    tools/flang/install
    install-flang-libraries install-flang-headers install-flang-new install-flang-cmake-exports
    install-flangFrontend install-flangFrontendTool
    install-FortranCommon install-FortranDecimal install-FortranEvaluate install-FortranLower
    install-FortranParser install-FortranRuntime install-FortranSemantics
  )

  ccache -s

  if ${CI:-false}; then

    echo "=== CI mode: phased LLVM build to prevent OOM ==="

    # Phase 1: Non-Flang targets at full parallelism (no OOM risk)
    echo "--- Phase 1: Non-Flang targets (parallel) ---"
    build-llvm.sh "${BUILD_LLVM_ARGS[@]}" "${NON_FLANG_TARGETS[@]}"

    # Phase 2: OOM-fragile .o files at -j2
    # Targets discovered from OOM failures on CI (-j4, 4.1 GB) and local (-j8, 2.5 GB).
    # Matched by CMake target directory; individual files within these dirs tend to be
    # memory-hungry due to heavy template instantiation in Flang/MLIR.
    echo "--- Phase 2: OOM-fragile object files (-j2) ---"
    mapfile -t OOM_TARGETS < <(ninja -C "$BUILD_DIR" -t targets all 2>/dev/null \
      | grep -E '(Fortran(Evaluate|Semantics|Lower|Parser)|FIRCodeGen|flangFrontend(Tool)?|MLIRMlirOptMain|bbc)\.dir/.*\.cpp\.o:' \
      | cut -d: -f1 || true)
    if [ ${#OOM_TARGETS[@]} -gt 0 ]; then
      echo "Building ${#OOM_TARGETS[@]} OOM-fragile targets at -j2"
      printf '%s\n' "${OOM_TARGETS[@]}"
      ninja -C "$BUILD_DIR" -j2 "${OOM_TARGETS[@]}"
    else
      echo "WARNING: No OOM-fragile targets found (pattern may need updating)"
    fi

    # Phase 3: Flang targets at full parallelism (OOM .o files pre-built)
    echo "--- Phase 3: Flang targets (parallel, OOM files pre-built) ---"
    build-llvm.sh "${BUILD_LLVM_ARGS[@]}" "${FLANG_TARGETS[@]}"
  else
    # Local: single pass (adequate memory + build-llvm.sh retry handles OOM)
    build-llvm.sh "${BUILD_LLVM_ARGS[@]}" \
      "${NON_FLANG_TARGETS[@]}" "${FLANG_TARGETS[@]}"
  fi

  rm -rf /llvm-project/llvm
  ccache -s
EOC

RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  FLANG_NEW="$(find /tmp/llvm -name flang-new)"
  if [ -z "$FLANG_NEW" ]; then
    echo "ERROR: flang-new not found in /tmp/llvm — Flang build failed?" >&2
    exit 1
  fi
  ln -s flang-new "$(dirname "$FLANG_NEW")/flang" # remove for LLVM 20
EOC

# Patch installed cmake exports/config files to not throw an error if not all components are installed
COPY patches/ClangTargets.cmake.patch patches/MLIRTargets.cmake.patch \
     patches/FlangTargets.cmake.patch patches/LLVMExports.cmake.patch /tmp/
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  patch --strip 1 --ignore-whitespace < /tmp/ClangTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < /tmp/MLIRTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < /tmp/FlangTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < /tmp/LLVMExports.cmake.patch
EOC

# Stage 2. Produce a minimal release image with build results.
FROM debian:13
LABEL maintainer="ParaTools Inc."
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
# Create the docker group with GID 967
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  groupadd -g 967 docker
  echo "umask 002" >> /etc/profile
EOC

# Ensure all subsequent commands are run using the docker group
USER :967

# Install packages for minimal useful image.
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
EOC

# RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOC
RUN <<EOC
#!/usr/bin/env bash
set -euo pipefail
  apt-get update
  # libstdc++-10-dev \
  apt-get install -y --no-install-recommends \
    ccache libz-dev libelf1t64 libtinfo-dev make binutils cmake git \
    gcc g++ gfortran wget ca-certificates \
    mpich libmpich-dev libmpich12 \
    less man
  rm -rf /var/lib/apt/lists/*
EOC

# Get ninja from builder
COPY --from=builder /usr/local/bin/ninja /usr/local/bin/

# Copy build results of stage 1 to /usr/local.
COPY --from=builder /tmp/llvm/ /usr/

# Setup ccache
ENV CCACHE_DIR=/home/salt/ccache

WORKDIR /home/salt/

ENV TAU_ROOT=/usr/local
ENV OMPI_ALLOW_RUN_AS_ROOT=1
ENV OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

# Download and install TAU
# http://tau.uoregon.edu/pdt_lite.tgz
# http://tau.uoregon.edu/pdt.tgz
# http://tau.uoregon.edu/tau.tgz
# http://fs.paratools.com/tau-mirror/tau.tgz
# http://fs.paratools.com/tau-nightly.tgz
# hadolint ignore=DL3003
RUN --mount=type=cache,id=ccache-tau,target=/home/salt/ccache <<EOC
#!/usr/bin/env bash
set -euo pipefail
  # Temporarily symlink compiler names to ccache so TAU/PDT builds use the cache
  for p in gcc g++ clang clang++ cc c++; do
    ln -vs /usr/bin/ccache /usr/local/bin/$p
  done
  ccache -s
  wget --no-verbose https://fs.paratools.com/tau-mirror/pdt_lite.tgz \
    || wget --no-verbose https://tau.uoregon.edu/pdt_lite.tgz
  echo "2fc9e8670f615f5079ae263184804c8ba576981d1648a307a0d65eff97b8f50a pdt_lite.tgz" | sha256sum -c
  tar xzvf pdt_lite.tgz
  rm pdt_lite.tgz
  PDT_DIR=$(echo pdt*)
  (cd "$PDT_DIR" && ./configure -GNU -prefix=/usr/local)
  make -C "$PDT_DIR" -j
  make -C "$PDT_DIR" -j install
  rm -rf pdt*
  git clone --recursive --depth=1 --single-branch https://github.com/UO-OACISS/tau2.git
  # installtau uses ./configure internally which relies on pwd; must cd into tau2
  cd tau2
  ./installtau -prefix=/usr/local -cc=gcc -c++=g++ -fortran=gfortran -pdt=/usr/local -pdt_c++=g++ \
    -bfd=download -unwind=download -dwarf=download -otf=download -zlib=download -pthread -j
  ./installtau -prefix=/usr/local -cc=gcc -c++=g++ -fortran=gfortran -pdt=/usr/local -pdt_c++=g++ \
    -bfd=download -unwind=download -dwarf=download -otf=download -zlib=download -pthread -mpi -j
  ./installtau -prefix=/usr/local -cc=clang -c++=clang++ -fortran=flang-new -pdt=/usr/local -pdt_c++=g++ \
    -bfd=download -unwind=download -dwarf=download -otf=download -zlib=download -pthread -j
  ./installtau -prefix=/usr/local -cc=clang -c++=clang++ -fortran=flang-new -pdt=/usr/local -pdt_c++=g++ \
    -bfd=download -unwind=download -dwarf=download -otf=download -zlib=download -pthread -mpi -j
  cd ..
  rm -rf tau* libdwarf-* otf2-*
  ccache -s
  # Remove ccache symlinks and restore direct compiler links for end users
  for p in gcc g++ clang clang++ cc c++; do
    rm /usr/local/bin/$p
    ln -vs /usr/bin/$p /usr/local/bin/$p
  done
  ls
EOC

ENV PATH="${PATH}:/usr/local/x86_64/bin"
WORKDIR /home/salt/src
