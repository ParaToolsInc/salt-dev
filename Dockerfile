# syntax=docker/dockerfile:1.4
# Stage 1. Check out LLVM source code and run the build.
FROM launcher.gcr.io/google/debian11:latest as builder
LABEL maintainer "ParaTools Inc."

# Install build dependencies of llvm.
# First, Update the apt's source list and include the sources of the packages.
RUN grep deb /etc/apt/sources.list | \
    sed 's/^deb/deb-src /g' >> /etc/apt/sources.list

ENV CCACHE_DIR=/ccache
RUN --mount=type=cache,target=/ccache/ ls -l $CCACHE_DIR

# Install compiler, cmake, git, ccache etc.
RUN --mount=type=cache,target=/var/cache/apt <<EOC
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates \
    build-essential cmake ccache make python3 zlib1g wget unzip git
EOC

# use ccache (make it appear in path earlier then /usr/bin/gcc etc)
RUN for p in gcc g++ clang clang++ cc c++; do ln -vs /usr/bin/ccache /usr/local/bin/$p;  done

# Install a newer ninja release. It seems the older version in the debian repos
# randomly crashes when compiling llvm.
RUN wget "https://github.com/ninja-build/ninja/releases/download/v1.11.1/ninja-linux.zip" && \
    echo "b901ba96e486dce377f9a070ed4ef3f79deb45f4ffe2938f8e7ddc69cfb3df77 ninja-linux.zip" \
        | sha256sum -c  && \
    unzip ninja-linux.zip -d /usr/local/bin && \
    rm ninja-linux.zip

# Clone LLVM repo. A shallow clone is faster, but pulling a cached repository is faster yet
RUN --mount=type=cache,target=/git <<EOC
  if mkdir llvm-project && git --git-dir=/git/llvm-project.git -C llvm-project pull origin release/14.x --ff-only
  then
    echo "WARNING: Using cached llvm git repository and pulling updates"
    echo "gitdir: /git/llvm-project.git" > llvm-project/.git
    git -C llvm-project reset --hard HEAD
  else
    echo "Cloning a fresh LLVM repository"
    git clone --separate-git-dir=/git/llvm-project.git \
      --single-branch \
      --branch=release/14.x \
      --filter=blob:none \
      https://github.com/llvm/llvm-project.git
  fi
  cd  llvm-project/llvm
  mkdir build
  git status
EOC

# CMake llvm build
RUN --mount=type=cache,target=/ccache/ --mount=type=cache,target=/git \
  cmake -GNinja \
    -DCMAKE_INSTALL_PREFIX=/tmp/llvm \
    -DCMAKE_MAKE_PROGRAM=/usr/local/bin/ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang;clang-tools-extra" \
    -DLLVM_TARGETS_TO_BUILD=X86 \
    -S /llvm-project/llvm -B /llvm-project/llvm/build

# Build libraries, headers, and binaries
RUN --mount=type=cache,target=/ccache/ --mount=type=cache,target=/git <<EOC
  # Do build
  # First get info
  ccache -s
  nproc --all || lscpu || true
  cd /llvm-project/llvm/build
  git branch
  # Actually do the build
  # ninja install-llvm-libraries install-llvm-headers \
  #   install-clang-libraries install-clang-headers install-clang install-clang-cmake-exports \
  #   install-clang-resource-headers install-llvm-config install-cmake-exports
EOC

RUN --mount=type=cache,target=/ccache/ ccache -s

# Patch installed cmake exports/config files to not throw an error if not all components are installed
COPY patches/ClangTargets.cmake.patch .
COPY patches/LLVMExports.cmake.patch .
# RUN <<EOC
#   find /tmp/llvm -name '*.cmake' -type f
#   patch --strip 1 --ignore-whitespace < ClangTargets.cmake.patch
#   patch --strip 1 --ignore-whitespace < LLVMExports.cmake.patch
# EOC

# Stage 2. Produce a minimal release image with build results.
FROM launcher.gcr.io/google/debian11:latest
LABEL maintainer "ParaTools Inc."

# Install packages for minimal useful image.
RUN <<EOC
  apt-get update
  apt-get install -y --no-install-recommends libstdc++-10-dev \
    ccache libz-dev libtinfo-dev make binutils cmake git
  rm -rf /var/lib/apt/lists/*
EOC

RUN for p in clang clang++ cc c++; do ln -vs /usr/bin/ccache /usr/local/bin/$p;  done

COPY --from=builder /usr/local/bin/ninja /usr/local/bin/

# Copy build results of stage 1 to /usr/local.
# COPY --from=builder /tmp/llvm/ /usr/local/

ENV CCACHE_DIR=/home/salt/ccache
RUN mkdir -p $CCACHE_DIR
WORKDIR /home/salt/
