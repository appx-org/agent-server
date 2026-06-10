#!/usr/bin/env bash
# Build and run the outer builder container. This script is the canonical
# spawn contract — an orchestrator (appx) should replicate exactly these
# flags. See docs/superpowers/specs/2026-06-10-outer-builder-container-design.md.
set -euo pipefail

cd "$(dirname "$0")/../.."

IMAGE="${BUILDER_IMAGE:-appx-builder}"
NAME="${BUILDER_NAME:-appx-builder}"
AGENT_PORT="${BUILDER_AGENT_PORT:-4001}"
APP_PORTS="${BUILDER_APP_PORTS:-3000-3010}"
WORKSPACE_VOLUME="${BUILDER_WORKSPACE_VOLUME:-appx-workspace}"
PODMAN_VOLUME="${BUILDER_PODMAN_VOLUME:-appx-podman}"

docker build -t "$IMAGE" -f docker/builder/Dockerfile .

docker rm -f "$NAME" >/dev/null 2>&1 || true

# Notes on flags (no --privileged):
#  --device /dev/fuse                    fuse-overlayfs storage for nested podman
#  seccomp/apparmor unconfined           required for nested user namespaces on
#                                        stock Docker; a tailored seccomp profile
#                                        is a follow-up hardening task
#  $PODMAN_VOLUME                        keeps inner images/containers across
#                                        outer restarts
docker run -d --name "$NAME" \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  -v "$WORKSPACE_VOLUME":/workspace \
  -v "$PODMAN_VOLUME":/home/builder/.local/share/containers \
  -p "$AGENT_PORT":4001 \
  -p "$APP_PORTS":"$APP_PORTS" \
  -e ANTHROPIC_API_KEY \
  -e AGENT_SERVER_TOKEN \
  -e LITELLM_BASE_URL -e LITELLM_API_KEY \
  -e LITELLM_MODELS -e LITELLM_MODELS_JSON \
  -e LITELLM_DEFAULT_MODEL -e LITELLM_DEFAULT_THINKING \
  "$IMAGE"

echo "builder container '$NAME' is up — agent-server on :$AGENT_PORT, app ports $APP_PORTS"
