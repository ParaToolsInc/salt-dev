# CLAUDE.md

Container definitions for [SALT](https://github.com/ParaToolsInc/salt) CI/CD and dev. Published to Docker Hub (`paratools/salt-dev`) and GHCR (`ghcr.io/paratoolsinc/salt-dev`). No test suite -- only linting.

## Commands

```bash
git clone --recursive git@github.com:ParaToolsInc/salt-dev.git # patches/ submodule required
```

- `/build` -- build Docker images with the salt-8cpu builder

## Conventions

- Hadolint suppressions: prefer inline `# hadolint ignore=DLxxxx` on the line directly above the instruction; put rationale on a separate comment line above
- Supply chain: verify downloads with sha256, pin GPG fingerprints
- Version tags: `v*.*.*` semver

## Gotchas

- Same-repo PRs can read base-branch `actions/cache` entries via `restore-keys`; fork PRs cannot
- GitHub CLI GPG key fingerprint (`2C61...6059`) pinned in `Dockerfile.devtools` -- **expires 2026-09-04**
- PDT checksum (`2fc9e86...`) pinned in `Dockerfile` -- update if upstream changes `pdt_lite.tgz`
- LLVM build: 150-200 min cold, ~4 min with ccache; `ARG PHASED_BUILD=true` enables OOM-aware phased build
- Intel IFX APT repo has signature verification issues on Debian 13+ (sqv rejects Intel's OpenPGP format); `install-intel-ifx.sh` detects and prompts for `[trusted=yes]`
