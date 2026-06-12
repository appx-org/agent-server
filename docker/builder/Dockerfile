# Outer builder container: agent-server + rootless podman.
# See docs/superpowers/specs/2026-06-10-outer-builder-container-design.md and
# docs/architecture/important/builder-container-architecture.md.

# --- Stage 1: build agent-server from this repo ----------------------------
FROM node:22-bookworm AS build
WORKDIR /src
COPY package.json package-lock.json tsconfig.json ./
ENV HUSKY=0
RUN npm ci
COPY src ./src
RUN npm run build && npm prune --omit=dev

# --- Stage 2: runtime -------------------------------------------------------
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Node 22 (NodeSource) + rootless podman stack.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y --no-install-recommends \
    nodejs \
    podman \
    fuse-overlayfs \
    uidmap \
    slirp4netns \
    passt \
    netavark \
    aardvark-dns \
    catatonit \
    git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Non-root builder user with subordinate id ranges for rootless podman.
# ubuntu:24.04 ships a default "ubuntu" uid-1000 user; replace it.
RUN userdel -r ubuntu 2>/dev/null || true \
  && useradd -m -u 1000 -s /bin/bash builder \
  && echo "builder:100000:65536" > /etc/subuid \
  && echo "builder:100000:65536" > /etc/subgid

# Rootless podman defaults tuned for running nested inside Docker.
COPY docker/builder/containers.conf /home/builder/.config/containers/containers.conf
COPY docker/builder/storage.conf /home/builder/.config/containers/storage.conf

# Builder-agent system prompt template; the entrypoint installs it into
# WORKSPACE_DIR/.pi-global/AGENTS.md, the shared agentDir used by runtimes.
COPY docker/builder/AGENTS.builder.md /usr/local/share/appx-builder/AGENTS.md

# agent-server runtime.
COPY --from=build /src/dist /app/dist
COPY --from=build /src/node_modules /app/node_modules
COPY package.json /app/package.json
COPY docker/builder/entrypoint.sh /usr/local/bin/builder-entrypoint

RUN mkdir -p /workspace /home/builder/.local/share/containers \
  && chown -R builder:builder /home/builder /workspace /app \
  && chmod +x /usr/local/bin/builder-entrypoint

USER builder
ENV HOME=/home/builder \
    WORKSPACE_DIR=/workspace \
    AGENT_SERVER_HOST=0.0.0.0 \
    AGENT_SERVER_PORT=4001

WORKDIR /workspace
EXPOSE 4001 3000-3010

ENTRYPOINT ["/usr/local/bin/builder-entrypoint"]
