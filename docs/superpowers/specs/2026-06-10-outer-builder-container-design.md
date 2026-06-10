# Outer Builder Container — Design

Date: 2026-06-10
Status: implemented & verified (2026-06-10, Ubuntu noble arm64 VM, Docker 29)

Acceptance results: all checks in `docker/builder/verify.sh` pass — REST up,
idempotent project create, session create, nested `podman run`, inner app
published on :3000 reachable from the host, registry survives container
restart, no credentials in inner env. Two flags were added to the spawn
contract during verification: `--cap-add SYS_ADMIN` (newuidmap EPERM on
uid/gid maps without it) and `--security-opt systempaths=unconfined` +
`--device /dev/net/tun` (crun sysctl writes and slirp4netns tap device).
Open item: user-level builder prompt pickup needs one live LLM turn to
confirm pi context discovery.
Scope: items 1, 2, and 4 of "What Needs to Be Built" in
`docs/architecture/important/builder-container-architecture.md`. Item 3
(project provisioning) already exists (`POST /v1/projects`); item 5
(idle eviction) stays out of scope.

## Goal

A self-contained Docker image and run script so that one `docker run` on any
Linux host yields the outer builder container from the architecture doc:
agent-server (project registry + shared auth) plus rootless podman, with
project sources on a volume and agent-built apps running as inner containers.

Out of scope for this slice: orchestrator (appx) spawn integration, the chat
web shell (stays outside the container and talks REST/SSE to port 4001),
per-project port registries, and multi-user isolation.

## Topology

```
Linux host (verification: Ubuntu arm64 VM via OrbStack, Docker installed)
└── docker run appx-builder            ← OUTER container, unprivileged
    ├── agent-server  (node, :4001)    ← WORKSPACE_DIR=/workspace
    ├── rootless podman (user: builder)
    ├── /workspace                     ← named volume `appx-workspace`
    │   ├── .pi-global/                ← auth.json, projects.json, sessions/
    │   └── <project-id>/              ← created by POST /v1/projects
    └── inner containers (podman)      ← built/run by the builder agent,
                                          ports published inside the outer
                                          container's net ns → reachable via
                                          the outer container's -p mappings
```

Trust zones follow the architecture doc: host trusted; outer container holds
LLM credentials in process memory; inner containers run generated code and
get no credentials.

## Deliverables (all in this repo)

```
docker/builder/
├── Dockerfile          # multi-stage: build agent-server → runtime image
├── entrypoint.sh       # podman warmup + exec agent-server
├── containers.conf     # rootless podman defaults for nested operation
├── storage.conf        # overlay + fuse-overlayfs storage for user `builder`
├── AGENTS.builder.md   # builder-agent system prompt (podman, /workspace, ports)
└── run.sh              # canonical build+run wrapper (the "spawn" contract)
docs/architecture/important/builder-container-architecture.md  # status update
README.md               # "Run it in Docker" section
```

## Dockerfile

Multi-stage:

1. **build** — `node:22-bookworm`: `npm ci && npm run build` of this repo
   (`dist/` + production `node_modules`).
2. **runtime** — `ubuntu:24.04`:
   - apt: `nodejs` (NodeSource 22), `podman`, `fuse-overlayfs`, `uidmap`,
     `slirp4netns`, `netavark`/`aardvark-dns` (noble defaults), `passt`,
     `ca-certificates`, `git`, `curl`.
   - non-root user `builder` (uid/gid 1000) with `/etc/subuid` and
     `/etc/subgid` ranges (`builder:100000:65536`) for rootless podman.
   - `containers.conf` + `storage.conf` baked into
     `/home/builder/.config/containers/`: overlay driver with
     `fuse-overlayfs`, network backend left at noble defaults with
     `slirp4netns` as the rootless network fallback (most reliable nested).
   - builder system prompt baked at `/home/builder/.pi/agent/AGENTS.md`
     (pi's user-level context discovery applies it to every project; the
     acceptance run must confirm pickup — fallback is copying it into each
     project's `.pi/AGENTS.md` at provisioning time).
   - `ENV WORKSPACE_DIR=/workspace AGENT_SERVER_HOST=0.0.0.0`.
   - `USER builder`, `EXPOSE 4001 3000-3010`, entrypoint below.

`.dockerignore` keeps the context small (node_modules, docs, test).

## entrypoint.sh

1. `mkdir -p "$WORKSPACE_DIR"` (volume may mount empty; agent-server requires
   the directory to exist).
2. `podman info >/dev/null 2>&1 || true` — first-run storage init warmup
   (non-fatal: REST surface must come up even if nesting is broken; the
   failure then surfaces in agent tool calls and logs).
3. `exec node /app/dist/server.js`.

## run.sh — the spawn contract

The single canonical way to launch (and later the exact contract appx will
implement):

```bash
docker build -t appx-builder -f docker/builder/Dockerfile .
docker run -d --name appx-builder \
  --device /dev/fuse \
  --security-opt seccomp=unconfined \
  --security-opt apparmor=unconfined \
  -v appx-workspace:/workspace \
  -v appx-podman:/home/builder/.local/share/containers \
  -p 4001:4001 -p 3000-3010:3000-3010 \
  -e ANTHROPIC_API_KEY -e AGENT_SERVER_TOKEN \
  -e LITELLM_BASE_URL -e LITELLM_API_KEY -e LITELLM_MODELS \
  -e LITELLM_MODELS_JSON -e LITELLM_DEFAULT_MODEL -e LITELLM_DEFAULT_THINKING \
  appx-builder
```

Notes:

- **No `--privileged`.** `--device /dev/fuse` is required for fuse-overlayfs;
  the relaxed seccomp/apparmor profiles are required for nested user
  namespaces on stock Docker (documented in run.sh; a future hardening pass
  can replace them with a custom seccomp profile).
- `appx-podman` volume keeps inner-container images/state across outer
  restarts (limitation 6 in the architecture doc).
- Flags are parameterized via env (`BUILDER_IMAGE`, `BUILDER_NAME`,
  `BUILDER_PORTS`), with the above as defaults.

## Builder system prompt (AGENTS.builder.md)

Short, factual contract for every builder agent:

- you work in a project directory under `/workspace/<project-id>`
- `podman` is available for building and running app containers
  (`podman build`, `podman run -d -p <port>:<port>`)
- publish app ports in the 3000–3010 range; they are forwarded to the host
- never pass provider API keys or env secrets into containers you run
- long-running apps: run detached, verify with `curl`, check `podman ps`/logs

## Verification (acceptance on the OrbStack VM)

Environment: new arm64 Ubuntu noble VM `appx-builder-vm` via
`orb create ubuntu appx-builder-vm`, Docker installed inside.

1. **Image builds**: `docker build` succeeds from a clean checkout.
2. **REST up**: `run.sh`, then `curl :4001/v1/healthz` → ok;
   `POST /v1/projects {"name":"demo"}` twice → idempotent; restart container
   → project still listed (volume-backed registry).
3. **Nesting works**: `docker exec -u builder appx-builder podman run --rm
   docker.io/library/alpine echo nested-ok` → prints `nested-ok`.
4. **Inner app reachable**: inside the outer container run a podman container
   publishing :3000 (static http server), then `curl <vm>:3000` from the VM →
   responds. This proves the diagram's port-forward chain
   (host → outer → inner).
5. **Prompt pickup**: create a session in `demo`, `GET` history after a
   prompt; with LLM credentials available, ask the agent to run an inner
   container itself (full diagram walkthrough). Without credentials this step
   degrades to checking the system prompt is loaded (server logs).
6. **No credential leak**: `docker exec ... podman run --rm alpine env` shows
   no `ANTHROPIC_API_KEY`/`LITELLM_API_KEY` (they live in the agent-server
   process env, which the bash tool inherits — the prompt forbids passing
   them on; this check documents the current boundary rather than enforcing
   it. A `spawnHook` env-strip is a named follow-up, not in this slice).

## Risks / open points

- **Nested rootless podman quirks** (network backend, cgroups v2 delegation)
  are the main unknown; that is exactly what the VM acceptance run flushes
  out. Fallbacks: `--network slirp4netns` per inner container; switching
  storage to `vfs` (slow but always works) as a last resort.
- **Prompt discovery**: if pi does not auto-load
  `/home/builder/.pi/agent/AGENTS.md`, fall back to copying the builder
  prompt into each project at provisioning (template copy in entrypoint is
  not possible per-project; the fallback would be an agent-server change —
  flagged during implementation if needed).
- Port range 3000–3010 is a fixed convention for this slice; a port registry
  is an explicit non-goal (limitation 5 in the architecture doc).
