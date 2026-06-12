#!/usr/bin/env bash
# Acceptance checks for the outer builder container (run on the docker host).
# Expects the container started via run.sh. See the design spec for context.
set -uo pipefail

NAME="${BUILDER_NAME:-appx-builder}"
PORT="${BUILDER_AGENT_PORT:-4001}"
BASE="http://127.0.0.1:$PORT"
fail=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "ok - $label"
  else
    echo "not ok - $label"
    fail=1
  fi
}

body() { curl -fsS --max-time 10 "$@"; }

# 1. REST surface up
check "healthz" body "$BASE/v1/healthz"

# 2. Idempotent project creation
P1=$(body -X POST "$BASE/v1/projects" -H 'content-type: application/json' -d '{"name":"demo"}')
P2=$(body -X POST "$BASE/v1/projects" -H 'content-type: application/json' -d '{"name":"demo"}')
if [ -n "$P1" ] && [ "$P1" = "$P2" ]; then echo "ok - project create idempotent"; else echo "not ok - project create idempotent"; fail=1; fi

# 3. Session creation (runtime boots, builder prompt loads — see container logs)
check "session create" body -X POST "$BASE/v1/projects/demo/sessions"

# 4. Nested rootless podman works
if docker exec -u builder "$NAME" podman run --rm docker.io/library/alpine echo nested-ok 2>/dev/null | grep -q nested-ok; then
  echo "ok - nested podman run"
else
  echo "not ok - nested podman run"; fail=1
fi

# 5. Inner app port chain: inner :3000 → outer -p → host
docker exec -u builder "$NAME" podman rm -f verify-web >/dev/null 2>&1
if docker exec -u builder "$NAME" podman run -d --name verify-web -p 3000:80 docker.io/library/nginx:alpine >/dev/null 2>&1; then
  sleep 3
  check "inner app reachable from host (:3000)" body "http://127.0.0.1:3000"
  docker exec -u builder "$NAME" podman rm -f verify-web >/dev/null 2>&1
else
  echo "not ok - inner app container start"; fail=1
fi

# 6. Registry survives an outer restart
docker restart "$NAME" >/dev/null
sleep 5
if body "$BASE/v1/projects" | grep -q '"demo"'; then
  echo "ok - project registry survives restart"
else
  echo "not ok - project registry survives restart"; fail=1
fi

# 7. No credential leak into inner containers
LEAK=$(docker exec -u builder "$NAME" podman run --rm docker.io/library/alpine env 2>/dev/null | grep -cE "ANTHROPIC_API_KEY|LITELLM_API_KEY")
if [ "${LEAK:-0}" = "0" ]; then echo "ok - no credentials in inner env"; else echo "not ok - credentials leaked into inner env"; fail=1; fi

exit $fail
