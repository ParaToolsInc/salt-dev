# CLAUDE.md

Container definitions for [SALT](https://github.com/ParaToolsInc/salt) CI/CD and dev. Published to Docker Hub (`paratools/salt-dev`) and GHCR (`ghcr.io/paratoolsinc/salt-dev`). No test suite — only linting.

## Commands

```bash
# Build (requires BuildKit)
docker buildx build --pull -t salt-dev --load .
# Devtools image (requires base)
docker buildx build -f Dockerfile.devtools -t salt-dev-tools --load .
# Clone with submodules (required for patches/)
git clone --recursive git@github.com:ParaToolsInc/salt-dev.git
# Lint (run after any Dockerfile/shell/workflow/JSON change — LLVM builds take 2-3h so lint failures are expensive)
bash lint.sh
```

## Conventions

- Shell scripts use `set -euo pipefail`
- Hadolint suppressions: prefer inline `# hadolint ignore=DLxxxx` on the line directly above the instruction; put rationale on a separate comment line above
- When adding new Dockerfiles, shell scripts, workflows, or JSON files, add them to `lint.sh`
- Supply chain: verify downloads with sha256, pin GPG fingerprints, prefer Debian packages over `curl|bash`
- In workflow `run:` blocks, use `$GITHUB_REF` not `${{ github.ref }}` (script injection prevention)
- Version tags: `v*.*.*` semver

## Gotchas

- `patches/` is a git submodule — clone with `--recursive`
- `mpich` branch still has `OMPI_ALLOW_RUN_AS_ROOT` env vars (OpenMPI leftovers, no effect with MPICH)
- GitHub CLI GPG key fingerprint (`2C61...6059`) pinned in `Dockerfile.devtools` — **expires 2026-09-04**
- PDT checksum (`2fc9e86...`) pinned in `Dockerfile` — update if upstream changes `pdt_lite.tgz`
- LLVM build: 150-200 min cold, ~1 min with ccache; `ARG CI=false` triggers shallow clones in GHA only
