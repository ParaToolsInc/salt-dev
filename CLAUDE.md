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
- `docker commit` captures the running command as the new `CMD`. After committing a container that ran `install-intel-ifx.sh`, reset `CMD` with: `docker commit --change='CMD ["/bin/bash"]' <container> <image:tag>`

## Working Style

Behavioral guidelines (adapted from [andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills/blob/main/CLAUDE.md)) to reduce common LLM coding mistakes. These bias toward caution over speed; use judgment for trivial tasks.

### Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them -- don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### Simplicity First

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Test: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### Surgical Changes

Touch only what you must. Clean up only your own mess.

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it -- don't delete it.
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

Every changed line should trace directly to the user's request.

### Goal-Driven Execution

Define success criteria. Loop until verified.

- "Add validation" -> "Write tests for invalid inputs, then make them pass"
- "Fix the bug" -> "Write a test that reproduces it, then make it pass"
- "Refactor X" -> "Ensure tests pass before and after"

For multi-step tasks, state a brief plan with verification per step. Strong success criteria let you loop independently; weak criteria ("make it work") require constant clarification.
