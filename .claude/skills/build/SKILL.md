---
name: build
description: Build Docker images locally. Use after linting passes.
disable-model-invocation: true
---

## Current State
- Branch: !`git branch --show-current`

Build the project Docker images:

1. First run `bash lint.sh` — abort if any check fails
2. Build base image: `docker buildx build --pull -t salt-dev --load .`
3. If $ARGUMENTS contains "devtools" or "all":
   - Build devtools: `docker buildx build -f Dockerfile.devtools -t salt-dev-tools --load .`
4. Report build success/failure and image sizes via `docker images | grep salt-dev`
