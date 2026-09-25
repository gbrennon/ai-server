#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${GATEWAY_TEST_IMAGE:-quay.io/rockylinux/rockylinux:9}"
CONTAINER="gateway-verify-$(date +%s)"
BASE="${CONTAINER}-base"
BUILT="localhost/gateway-verify:${CONTAINER}"

log()  { echo "[gateway-container] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

command -v podman >/dev/null 2>&1 || fail "podman is required"

cleanup() {
  podman rm -f "$CONTAINER" "$BASE" >/dev/null 2>&1 || true
  podman rmi -f "$BUILT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

resolve_image() {
  if podman image exists "$IMAGE"; then
    return 0
  fi
  if podman pull "$IMAGE" >/dev/null 2>&1; then
    return 0
  fi
  local cached
  cached="$(podman images --format '{{.Repository}}:{{.Tag}}' \
    | grep -Ei 'rockylinux|fedora' | head -n1 || true)"
  [[ -n "$cached" ]] || fail "cannot pull $IMAGE and no cached Rocky/Fedora image found"
  log "quay.io unreachable; using cached image $cached"
  IMAGE="$cached"
}

resolve_network() {
  if command -v slirp4netns >/dev/null 2>&1; then
    echo slirp4netns
  else
    echo host
  fi
}

cexec()  { podman exec "$CONTAINER" "$@"; }
crun()   { podman exec -w /root/ai-server "$CONTAINER" "$@"; }

wait_for_systemd() {
  local i
  for i in $(seq 1 30); do
    if cexec systemctl is-system-running >/dev/null 2>&1; then
      return 0
    fi
    local state
    state="$(cexec systemctl is-system-running 2>/dev/null || true)"
    [[ "$state" == "degraded" ]] && return 0
    sleep 1
  done
  fail "systemd did not become available inside the container"
}

start_mock_llama() {
  local mock=/root/mock-llama.py
  cat >"$MOCK_SRC" <<'PY'
import http.server
import socketserver

ROUTES = {
    "/health": b'{"status":"ok"}',
    "/v1/models": b'{"object":"list","data":[]}',
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with socketserver.TCPServer(("127.0.0.1", 8080), Handler) as httpd:
    httpd.serve_forever()
PY
  podman cp "$MOCK_SRC" "$CONTAINER:$mock"
  podman exec -d "$CONTAINER" python3 "$mock"
  local i
  for i in $(seq 1 15); do
    if cexec curl -sS --max-time 2 http://127.0.0.1:8080/health >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  fail "mock llama-server did not come up on 127.0.0.1:8080"
}

MOCK_SRC="$(mktemp)"
trap 'rm -f "$MOCK_SRC"; cleanup' EXIT

NETWORK="$(resolve_network)"
resolve_image

log "installing systemd and dependencies into a base image"
podman run -d --name "$BASE" --network="$NETWORK" "$IMAGE" sleep infinity >/dev/null
podman exec "$BASE" dnf install -y --allowerasing \
  systemd ansible-core bind-utils procps-ng iproute python3 >/dev/null
podman commit "$BASE" "$BUILT" >/dev/null
podman rm -f "$BASE" >/dev/null

log "starting $CONTAINER with systemd (network=$NETWORK)"
podman run -d --name "$CONTAINER" --systemd=always --network="$NETWORK" \
  "$BUILT" /sbin/init >/dev/null
wait_for_systemd

log "copying repository into container"
cexec mkdir -p /root/ai-server
podman cp "$REPO_DIR/." "$CONTAINER:/root/ai-server"

log "installing ansible collections"
crun ansible-galaxy collection install -r requirements.yml >/dev/null

log "deploying gateway role"
crun ansible-playbook site.yml --tags gateway --connection=local \
  -e gateway_enabled=true -e gateway_lan_ip=127.0.0.1 -e gateway_open_firewall=false

log "starting mock llama-server upstream"
start_mock_llama

log "running gateway health check"
podman exec -w /root/ai-server -e GATEWAY_LAN_IP=127.0.0.1 \
  "$CONTAINER" ./scripts/verify-gateway.sh

log "trusting Caddy internal root CA"
crun ./scripts/trust-caddy-ca.sh

log "validating strict TLS without -k"
body="$(cexec curl -sS --resolve api.ai-gbrennon.home.arpa:443:127.0.0.1 \
  https://api.ai-gbrennon.home.arpa/health)"
[[ "$body" == '{"status":"ok"}' ]] || fail "unexpected /health body: $body"

echo "[OK] Gateway container verification completed successfully"
