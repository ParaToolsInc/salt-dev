# salt-dev

[![ci](https://github.com/ParaToolsInc/salt-dev/actions/workflows/CI.yml/badge.svg)](https://github.com/ParaToolsInc/salt-dev/actions/workflows/CI.yml)

Container definitions for [SALT] development.

This repository defines and deploys the containers used for [SALT] continuous integration (CI) and local development.

LLVM/Clang patches needed by [SALT] for minimal LLVM/Clang builds are shared between this repository
and [SALT] using a [git submodule].
The patches are stored here: https://github.com/ParaToolsInc/salt-llvm-patches

## Building the development container for local use

First, BuildKit, caching and intelligent layer creation and ordering have been employed
in an attempt to minimize time spent waiting for the container to build.
Certain operations are unavoidably expensive when performed for the first time,
however, steps have been taken to maximize caching and minimuze rebuild times.
The first build on a new machine will always be expensive but subsequent updates
should be comparatively snappy and painless.

To build the development image with BuildKit, the following command may be employed:

``` shell
docker buildx build --pull -t salt-dev --load .
```

To usethe development image in testing, something like this should work:

``` shell
docker run -it --tmpfs=/dev/shm:rw,nosuid,nodev,exec --privileged -v $(pwd):/home/salt/src salt-dev
```

This will mount the working directory (usually your SALT worktree) into `/home/salt/src`.

## Optimizations for expensive build steps

The following discusses the major pain points and the steps taken to minimize them.

### Compiling LLVM/Clang

This is by far the most expensive step.
On a 2.4 GHz 8-Core Intel Core i9 Mac Book Pro,
the initial build of this image layer takes approximately 150-200 minutes.
It is therefore important that:

1. This layer is built early to maximise the opportunity for reuse
2. Cheaper steps that are likely to change should be placed after the `RUN` step compiling llvm/clang in the `Dockerfile`
3. Some sort of compiler cache is employed, here we use ccache, to speed up the build even when the layer needs to be rebuilt
4. The compiler cache needs to be made available to the build even when the layer is rebuilt.

The first build will still take a long time (~150-200 minutes on a 2.4 GHz 8-Core Intel Core i9),
however subsequent rebuilds will take about 1 minute (on a 2.4 GHz 8-Core Intel Core i9) when the cache is
present.
This is acheived through the use of `ccache` and the `--mount=type=cache,target=/some/path` option to the
`RUN` command in the Dockerfile.
In the event that previous layers have not changed and neither has the layer defining the llvm/clang compilation,
then, of course, a previous cached layer may just be reused taking about a second or so.

### Cloning/updating llvm-project

Shallow clones are fastest, but they are less than performant when a subsequent update of the repository
(via `git fetch` or `git pull`) is required.
An alternate to shallow clones is to use the `--filter=blob:none` option,
which fetches entire histories, commits and trees, but only the blobs needed by `HEAD`.
This allows the repository to be worked with and updated in an efficient way takes considerably less time
than a full clone.
(On a 2.4 GHz 8-Core Intel Core i9 with ~40 Mbit/s download speed `--single-branch` and `--filter=blob:none`
reduce the clone time from over 5 minutes to 2.5-3 minutes.
A shallow clone using `--single-branch` and `--depth=1` takes about 1.5-2 minutes.)
By not using a shallow clone, we can cache the `.git` folder, and efficiently reset the work tree and
fetch any updates on the branch if the cache exists.
If the cache doesn't exist a new clone is performed.

### Package installation via `apt`

Caching of `apt` packages that can be potentially shared was implemented following the example
[here](https://docs.docker.com/engine/reference/builder/#run---mounttypecache)

### GitHub Actions caching

Using the official docker GitHub Actions with their support for caching maximizes the amount of caching and
efficiency of building the image(s) during CI.
Very useful examples are available [here](https://docs.docker.com/build/ci/github-actions/examples).

[SALT]: https://github.com/ParaToolsInc/salt
[git submodule]: https://git-scm.com/book/en/v2/Git-Tools-Submodules
