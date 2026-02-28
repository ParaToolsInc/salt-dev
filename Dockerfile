# syntax=docker/dockerfile:1.4
# Stage 1. Check out LLVM source code and run the build.
FROM debian:12 AS builder
LABEL maintainer="ParaTools Inc."

# Install build dependencies of llvm.
# First, Update the apt's source list and include the sources of the packages.
# Improve caching too
RUN <<EOC
  grep deb /etc/apt/sources.list | sed 's/^deb/deb-src /g' >> /etc/apt/sources.list
  rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
EOC

ENV CCACHE_DIR=/ccache
RUN --mount=type=cache,target=/ccache/ ls -l $CCACHE_DIR

# Install compiler, cmake, git, ccache etc.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOC
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates \
    build-essential cmake ccache make python3 zlib1g wget unzip git
  cmake --version
EOC

ARG CI=false
ARG LLVM_VER=19
# Clone LLVM repo. A shallow clone is faster, but pulling a cached repository is faster yet
RUN --mount=type=cache,target=/git <<EOC
  echo "Checking out LLVM."
  echo "\$CI = $CI"
  # If the job is killed during a git operation the cache might be broken
  if [ -f /git/llvm-project.git/index.lock ]; then
    echo "index.lock file found--git repo might be in a broken state."
    echo "Removing /git/llvm-project.git and forcing a new checkout!"
    rm -rf /git/llvm-project.git
  fi
  if ${CI:-false}; then
    # Github CI never seems to use the cached git directory :-[
    echo "Running under CI. \$CI=$CI. Shallow cloning will be used if a clone is required."
#    export SHALLOW='--depth=1'
  fi
  if mkdir llvm-project && git --git-dir=/git/llvm-project.git -C llvm-project pull origin release/${LLVM_VER}.x --ff-only
  then
    echo "WARNING: Using cached llvm git repository and pulling updates"
    cp -r /git/llvm-project.git /llvm-project/.git
    git -C /llvm-project reset --hard HEAD
  else
    echo "Cloning a fresh LLVM repository"
    git clone --separate-git-dir=/git/llvm-project.git \
      ${SHALLOW:-} --single-branch \
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
  wget --no-verbose "https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip"
  echo "b901ba96e486dce377f9a070ed4ef3f79deb45f4ffe2938f8e7ddc69cfb3df77 ninja-linux.zip" \
    | sha256sum -c
  unzip ninja-linux.zip -d /usr/local/bin
  rm  ninja-linux.zip
EOC

COPY build-llvm.sh /usr/local/bin/
ARG NINJA_MAX_JOBS=""

# Configure and build LLVM/Clang components needed by SALT
RUN --mount=type=cache,target=/ccache/ <<EOC
  nproc --all || lscpu || true
  pwd
  if ! git -C /llvm-project status ; then
    echo "llvm-project git repository missing or broken!!!"
    exit 1
  fi
  ccache -s

  # Configure the build
  if uname -a | grep x86 ; then export LLVM_TARGETS_TO_BUILD="-DLLVM_TARGETS_TO_BUILD=X86"; fi
  cmake -GNinja \
    -DCMAKE_INSTALL_PREFIX=/tmp/llvm \
    -DCMAKE_MAKE_PROGRAM=/usr/local/bin/ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_CCACHE_BUILD=On \
    -DLLVM_ENABLE_PROJECTS="flang;clang;clang-tools-extra;mlir;openmp" \
    -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
    ${LLVM_TARGETS_TO_BUILD} \
    -S /llvm-project/llvm -B /llvm-project/llvm/build

  BUILD_DIR=/llvm-project/llvm/build

  NON_FLANG_TARGETS="install-llvm-libraries install-llvm-headers install-llvm-config install-cmake-exports \
    install-clang-libraries install-clang-headers install-clang install-clang-cmake-exports \
    install-clang-resource-headers \
    install-mlir-headers install-mlir-libraries install-mlir-cmake-exports \
    install-openmp-resource-headers \
    install-compiler-rt"

  FLANG_TARGETS="tools/flang/install \
    install-flang-libraries install-flang-headers install-flang-new install-flang-cmake-exports \
    install-flangFrontend install-flangFrontendTool \
    install-FortranCommon install-FortranDecimal install-FortranEvaluate install-FortranLower \
    install-FortranParser install-FortranRuntime install-FortranSemantics"

  ccache -s

  if ${CI:-false}; then

    # Protect CI runner from hard OOM kills:
    # - oom_score_adj: prefer killing compiler processes over Docker daemon/runner agent
    # - ulimit -v: cap per-process virtual memory so ninja gets a clean failure
    #   (enables build-llvm.sh retry logic instead of runner crash)
    echo 300 > /proc/$$/oom_score_adj
    ulimit -v 3565158

    echo "=== CI mode: phased LLVM build to prevent OOM ==="

    # Phase 1: Non-Flang targets at full parallelism (no OOM risk)
    echo "--- Phase 1: Non-Flang targets (parallel) ---"
    build-llvm.sh --build-dir "$BUILD_DIR" \
      ${NINJA_MAX_JOBS:+--max-jobs "${NINJA_MAX_JOBS}"} \
      $NON_FLANG_TARGETS

    # Phase 2: OOM-fragile .o files at -j1 (fold ~3-4 GB each)
    # Discovered dynamically from ninja build graph after cmake configure
    echo "--- Phase 2: OOM-fragile object files (-j1) ---"
    OOM_TARGETS=$(ninja -C "$BUILD_DIR" -t targets all 2>/dev/null \
      | grep -E 'Fortran(Evaluate|Semantics|Lower)\.dir/(fold|check-|lower-).*\.cpp\.o:' \
      | cut -d: -f1 || true)
    if [ -n "$OOM_TARGETS" ]; then
      echo "Building $(echo "$OOM_TARGETS" | wc -l) OOM-fragile targets at -j1"
      echo "$OOM_TARGETS"
      ninja -C "$BUILD_DIR" -j1 $OOM_TARGETS
    else
      echo "WARNING: No OOM-fragile targets found (pattern may need updating)"
    fi

    # Phase 3: Flang targets at full parallelism (OOM .o files pre-built)
    echo "--- Phase 3: Flang targets (parallel, OOM files pre-built) ---"
    build-llvm.sh --build-dir "$BUILD_DIR" \
      ${NINJA_MAX_JOBS:+--max-jobs "${NINJA_MAX_JOBS}"} \
      $FLANG_TARGETS
  else
    # Local: single pass (adequate memory + build-llvm.sh retry handles OOM)
    build-llvm.sh --build-dir "$BUILD_DIR" \
      ${NINJA_MAX_JOBS:+--max-jobs "${NINJA_MAX_JOBS}"} \
      $NON_FLANG_TARGETS $FLANG_TARGETS
  fi

  rm -rf /llvm-project/llvm
  ccache -s
EOC

RUN <<EOC
  find /tmp/llvm -name flang-new
  FLANG_NEW="$(find /tmp/llvm -name flang-new)"
  FLANG_NEW_DIR="$(dirname $FLANG_NEW)"
  cd "$FLANG_NEW_DIR"
  pwd
  ln -s flang-new flang # remove for LLVM 20
  ls -la
EOC

# Patch installed cmake exports/config files to not throw an error if not all components are installed
COPY patches/ClangTargets.cmake.patch patches/MLIRTargets.cmake.patch \
     patches/FlangTargets.cmake.patch patches/LLVMExports.cmake.patch ./
RUN <<EOC
  find /tmp/llvm -name '*.cmake' -type f
  patch --strip 1 --ignore-whitespace < ClangTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < MLIRTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < FlangTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < LLVMExports.cmake.patch
EOC

# Stage 2. Produce a minimal release image with build results.
FROM debian:12
LABEL maintainer="ParaTools Inc."
# Create the docker group with GID 967
RUN <<EOC
  groupadd -g 967 docker
  echo "umask 002" >> /etc/profile
EOC

# Ensure all subsequent commands are run using the docker group
USER :967

# Install packages for minimal useful image.
RUN <<EOC
  rm -f /etc/apt/apt.conf.d/docker-clean
  echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
EOC

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked <<EOC
  apt-get update
  # libstdc++-10-dev \
  apt-get install -y --no-install-recommends \
    ccache libz-dev libelf1 libtinfo-dev make binutils cmake git \
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
RUN --mount=type=cache,target=/home/salt/ccache <<EOC
  # Temporarily symlink compiler names to ccache so TAU/PDT builds use the cache
  for p in gcc g++ clang clang++ cc c++; do
    ln -vs /usr/bin/ccache /usr/local/bin/$p
  done
  ccache -s
  echo "verbose=off" > ~/.wgetrc
  wget https://fs.paratools.com/tau-mirror/pdt_lite.tgz || wget https://tau.uoregon.edu/pdt_lite.tgz
  echo "2fc9e8670f615f5079ae263184804c8ba576981d1648a307a0d65eff97b8f50a pdt_lite.tgz" | sha256sum -c
  tar xzvf pdt_lite.tgz
  rm pdt_lite.tgz
  cd pdt*
  ./configure -GNU -prefix=/usr/local
  make -j
  make -j install
  cd ..
  rm -rf pdt*
  # wget http://tau.uoregon.edu/tau.tgz || wget http://fs.paratools.com/tau-mirror/tau.tgz
  # tar xzvf tau.tgz
  git clone --recursive --depth=1 --single-branch https://github.com/UO-OACISS/tau2.git
  cd tau*
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
