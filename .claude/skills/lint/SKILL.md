---
name: lint
description: Run all project linters and fix any issues found
---

## Current State
- Branch: !`git branch --show-current`
- Modified files: !`git diff --name-only`

Run the project linters:

1. Execute `bash lint.sh` from the repo root
2. If any check fails, read `.hadolint.yaml` for suppression policy
3. Fix issues in the source files — do NOT add inline `# hadolint ignore=` directives
4. For new hadolint suppressions, add to `.hadolint.yaml` with a rationale comment
5. Re-run `bash lint.sh` until all checks pass
6. Report which checks passed and any fixes applied
