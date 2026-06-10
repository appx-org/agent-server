#!/usr/bin/env bash
set -euo pipefail

# The workspace volume may mount empty; agent-server requires the dir to exist.
mkdir -p "${WORKSPACE_DIR:-/workspace}"

# First-run rootless storage init is slow; warm it up. Non-fatal: the REST
# surface must come up even if nesting is broken — the failure then surfaces
# in agent tool calls instead of a crash loop.
if podman info >/dev/null 2>&1; then
  echo "[builder] rootless podman ready"
else
  echo "[builder] WARNING: podman info failed — inner containers will not work" >&2
fi

exec node /app/dist/server.js
