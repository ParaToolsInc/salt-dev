# syntax=docker/dockerfile:1.4
# Stage 1. Check out LLVM source code and run the build.
FROM launcher.gcr.io/google/debian12:latest as builder
LABEL maintainer "ParaTools Inc."

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

# use ccache (make it appear in path earlier then /usr/bin/gcc etc)
RUN for p in gcc g++ clang clang++ cc c++; do ln -vs /usr/bin/ccache /usr/local/bin/$p;  done

ARG CI=false
ARG LLVM_VER=18
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

# Configure and build LLVM/Clang components needed by SALT
RUN --mount=type=cache,target=/ccache/ <<EOC
  nproc --all || lscpu || true
  pwd
  if ! git -C /llvm-project status ; then
    echo "llvm-project git repository missing or broken!!!"
    exit 1
  fi
  ccache -s
  #Configure the build
  if uname -a | grep x86 ; then eport LLVM_TARGETS_TO_BUILD="-DLLVM_TARGETS_TO_BUILD=X86"; fi
  cmake -GNinja \
    -DCMAKE_INSTALL_PREFIX=/tmp/llvm \
    -DCMAKE_MAKE_PROGRAM=/usr/local/bin/ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_CCACHE_BUILD=On \
    -DLLVM_ENABLE_PROJECTS="flang;clang;clang-tools-extra;mlir;openmp" ${LLVM_TARGETS_TO_BUILD} \
    -S /llvm-project/llvm -B /llvm-project/llvm/build

  # Build libraries, headers, and binaries
  # Do build
  ccache -s
  cd /llvm-project/llvm/build
  # Actually do the build
  ninja install-llvm-libraries install-llvm-headers install-llvm-config install-cmake-exports \
    install-clang-libraries install-clang-headers install-clang install-clang-cmake-exports \
    install-clang-resource-headers \
    install-flang-libraries install-flang-headers install-flang-new install-flang-cmake-exports \
    install-flangFrontend install-flangFrontendTool
  ccache -s
  git -C /llvm-project status
EOC

# Patch installed cmake exports/config files to not throw an error if not all components are installed
COPY patches/ClangTargets.cmake.patch .
COPY patches/LLVMExports.cmake.patch .
RUN <<EOC
  find /tmp/llvm -name '*.cmake' -type f
  patch --strip 1 --ignore-whitespace < ClangTargets.cmake.patch
  patch --strip 1 --ignore-whitespace < LLVMExports.cmake.patch
EOC

# Stage 2. Produce a minimal release image with build results.
FROM launcher.gcr.io/google/debian12:latest
LABEL maintainer "ParaTools Inc."

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
    gcc g++ wget
  rm -rf /var/lib/apt/lists/*
EOC

# Get ninja from builder
COPY --from=builder /usr/local/bin/ninja /usr/local/bin/

# Copy build results of stage 1 to /usr/local.
COPY --from=builder /tmp/llvm/ /usr/

# Setup ccache
ENV CCACHE_DIR=/home/salt/ccache
RUN <<EOC
  for p in gcc g++ clang clang++ cc c++; do
    ln -vs /usr/bin/ccache /usr/local/bin/$p
  done
EOC

WORKDIR /home/salt/

# Download and install TAU
# http://tau.uoregon.edu/tau.tgz
# http://fs.paratools.com/tau-mirror/tau.tgz
# http://fs.paratools.com/tau-nightly.tgz
RUN --mount=type=cache,target=/home/salt/ccache <<EOC
  ccache -s
  echo "verbose=off" > ~/.wgetrc
  wget http://tau.uoregon.edu/tau.tgz || wget http://fs.paratools.com/tau-mirror/tau.tgz
  tar xzvf tau.tgz
  cd tau*
  ./installtau -prefix=/usr/local/ -cc=gcc -c++=g++\
    -bfd=download -unwind=download -dwarf=download -otf=download -pthread -iowrapper -j
  ./installtau -prefix=/usr/local/ -cc=clang -c++=clang++\
    -bfd=download -unwind=download -dwarf=download -otf=download -pthread -iowrapper -j
  cd ..
  rm -rf tau*
  ccache -s
EOC

ENV PATH="${PATH}:/usr/local/x86_64/bin"
RUN alias ls="ls --color=auto"
