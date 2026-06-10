#!/usr/bin/env bash
set -euo pipefail

# The workspace volume may mount empty; agent-server requires the dir to exist.
workspace_dir="${WORKSPACE_DIR:-/workspace}"
global_agent_dir="${workspace_dir}/.pi-global"
builder_agents_template="/usr/local/share/appx-builder/AGENTS.md"

mkdir -p "${global_agent_dir}"

if [ ! -e "${global_agent_dir}/AGENTS.md" ]; then
  cp "${builder_agents_template}" "${global_agent_dir}/AGENTS.md"
fi

# First-run rootless storage init is slow; warm it up. Non-fatal: the REST
# surface must come up even if nesting is broken — the failure then surfaces
# in agent tool calls instead of a crash loop.
if podman info >/dev/null 2>&1; then
  echo "[builder] rootless podman ready"
else
  echo "[builder] WARNING: podman info failed — inner containers will not work" >&2
fi

exec node /app/dist/server.js
