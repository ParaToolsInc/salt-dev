# salt-dev

[![ci](https://github.com/ParaToolsInc/salt-dev/actions/workflows/CI.yml/badge.svg)](https://github.com/ParaToolsInc/salt-dev/actions/workflows/CI.yml)

Container definitions for [SALT] development.

This repository defines and deploys the containers used for [SALT] continuous integration (CI) and local development.

LLVM/Clang patches needed by [SALT] for minimal LLVM/Clang builds are shared between this repository
and [SALT] using a [git submodule].
The patches are stored here: https://github.com/ParaToolsInc/salt-llvm-patches

## Building the development container for local use

BuildKit, caching, and intelligent layer ordering are used to minimize build times.
The first build on a new machine is expensive, but subsequent rebuilds are fast
thanks to ccache and Docker layer caching.

### Base image (`salt-dev`)

Build with BuildKit:

``` shell
docker buildx build --pull -t salt-dev --load .
```

Run against a local SALT worktree:

``` shell
docker run -it --tmpfs=/dev/shm:rw,nosuid,nodev,exec --privileged -v $(pwd):/home/salt/src salt-dev
```

This mounts the working directory (usually your SALT worktree) into `/home/salt/src`.

### Dev Tools image (`salt-dev-tools`)

A variant with interactive tooling for AI-assisted development, debugging, and profiling.
Includes: Claude Code, GitHub CLI, Node.js 22, emacs, ripgrep, silversearcher, gdb, valgrind,
htop, jq, bat, and python3.

Build using the helper script:

``` shell
./build-devtools.sh --no-push --no-intel   # salt-dev-tools only, no Intel IFX (local)
./build-devtools.sh --no-push              # salt-dev-tools + Intel IFX installed (local)
./build-devtools.sh                        # build, install IFX, and push to Docker Hub
```

To pin a specific IFX version:

``` shell
./build-devtools.sh --no-push --ifx-version=2025.3 --tag=intel-2025.3
```

Or build directly with BuildKit (requires a local `salt-dev` image):

``` shell
docker buildx build -f Dockerfile.devtools -t salt-dev-tools --load .
```

Launch interactively (reads `CLAUDE_CODE_OAUTH_TOKEN` and `GH_TOKEN` from the environment):

``` shell
./run-salt-dev.sh
```

### VS Code Devcontainer

Open this repository in VS Code and accept the "Reopen in Container" prompt.
The devcontainer configuration will build the image automatically and install GitHub Copilot extensions.

## Scripts

| Script | Description | Example |
|---|---|---|
| `build-devtools.sh` | Builds `salt-dev-tools`, optionally installs Intel IFX, and pushes to Docker Hub | `./build-devtools.sh --no-push` |
| `run-salt-dev.sh` | Launches a `salt-dev` or `salt-dev-tools` container with sensible defaults; resolves git identity and API tokens from the environment | `./run-salt-dev.sh` |
| `install-intel-ifx.sh` | Installs Intel IFX/ICX/ICPX compilers inside `salt-dev-tools`; handles Debian 13+ APT signature quirks | `./install-intel-ifx.sh 2025.2` |
| `build-llvm.sh` | OOM-resilient LLVM build wrapper around ninja; maximizes parallelism and auto-recovers by retrying failed targets at progressively lower `-j` | `./build-llvm.sh clang flang` |
| `test-build-llvm.sh` | Unit and integration tests for `build-llvm.sh` | `./test-build-llvm.sh` |
| `lint.sh` | Runs all linters: hadolint, shellcheck, actionlint, jq | `./lint.sh` |

## Optimizations for expensive build steps

### Compiling LLVM/Clang

Cold build: ~150-200 min on an 8-core machine. With a warm ccache: ~1 min.

The Dockerfile uses `--mount=type=cache` to persist the ccache directory across BuildKit invocations.
In CI, the [`reproducible-containers/buildkit-cache-dance`](https://github.com/reproducible-containers/buildkit-cache-dance)
action bridges BuildKit's internal cache mount to GitHub Actions' `actions/cache` store —
exporting the cache to a tarball on each run and importing it back before the next build,
so ccache survives across ephemeral CI runners.

### Cloning/updating llvm-project

Uses `--filter=blob:none` (blobless clone) to fetch full history without downloading all blobs upfront,
roughly halving clone time versus a full clone while still supporting efficient updates.
Shallow clones (`--depth=1`) are faster initially but degrade on subsequent fetches.

### Package installation via `apt`

`apt` package downloads are cached via `--mount=type=cache` so repeated `apt-get install` steps
reuse previously downloaded `.deb` files without hitting the network.

### GitHub Actions caching

The CI uses a two-layer registry cache strategy: each branch writes to a per-branch
`buildcache-<ref>` tag and reads from both that and a shared `buildcache` tag.
On push to `main`, a second build step promotes the branch cache to the shared tag,
keeping a warm cache available to all branches and new contributors.

[SALT]: https://github.com/ParaToolsInc/salt
[git submodule]: https://git-scm.com/book/en/v2/Git-Tools-Submodules
