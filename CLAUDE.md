# CLAUDE.md

Container definitions for [SALT](https://github.com/ParaToolsInc/salt) CI/CD and dev. Published to Docker Hub (`paratools/salt-dev`) and GHCR (`ghcr.io/paratoolsinc/salt-dev`). No test suite — only linting.

## Commands

```bash
docker buildx build --pull -t salt-dev --load . # build base image
docker buildx build -f Dockerfile.devtools -t salt-dev-tools --load . # devtools (requires base)
git clone --recursive git@github.com:ParaToolsInc/salt-dev.git # patches/ submodule required
bash lint.sh # run after any Dockerfile/shell/workflow/JSON change
```

## Conventions

- Shell scripts use `set -euo pipefail`
- Hadolint suppressions: prefer inline `# hadolint ignore=DLxxxx` on the line directly above the instruction; put rationale on a separate comment line above
- When adding new Dockerfiles, shell scripts, workflows, or JSON files, add them to `lint.sh`
- Supply chain: verify downloads with sha256, pin GPG fingerprints, prefer Debian packages over `curl|bash`
- In workflow `run:` blocks, use `$GITHUB_REF` not `${{ github.ref }}`, same for SHAs/event values — set as `env:` vars
- Version tags: `v*.*.*` semver

## Gotchas

- Same-repo PRs can read base-branch `actions/cache` entries via `restore-keys`; fork PRs cannot
- GitHub CLI GPG key fingerprint (`2C61...6059`) pinned in `Dockerfile.devtools` — **expires 2026-09-04**
- PDT checksum (`2fc9e86...`) pinned in `Dockerfile` — update if upstream changes `pdt_lite.tgz`
- LLVM build: 150-200 min cold, ~4 min with ccache; `ARG CI=false` triggers shallow clones in GHA only
- Intel IFX APT repo has signature verification issues on Debian 13+ (sqv rejects Intel's OpenPGP format); `install-intel-ifx.sh` detects and prompts for `[trusted=yes]`
