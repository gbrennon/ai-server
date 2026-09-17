#!/usr/bin/env bash
# ============================================================================
# deploy-remote.sh — deploy llama.cpp to a remote dnf machine (e.g. the
# GMKtec Evo X2) from THIS machine, over SSH. Ansible runs on the controller;
# the mini PC only needs SSH + python3 (both distros ship python3).
#
# Usage:
#   ./scripts/deploy-remote.sh <host> [ssh-user] [profile]
#   ./scripts/deploy-remote.sh 192.168.1.50 gabriel profiles/gmktec-evo-x2.yml
#
# Defaults: user = current user, profile = none (use group_vars as-is).
# ============================================================================
set -euo pipefail

HOST="${1:?Usage: deploy-remote.sh <host> [ssh-user] [profile.yml]}"
SSH_USER="${2:-$(id -un)}"
PROFILE="${3:-}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_HTTP=8080

log()  { echo "[deploy-remote] $*"; }
die()  { echo "[deploy-remote] ERROR: $*" >&2; exit 1; }

command -v ansible-playbook >/dev/null || die "ansible not installed on this machine (python3 -m pip install --user ansible)"

# ---- 1. connectivity & sudo check ------------------------------------------
log "checking SSH connectivity to ${SSH_USER}@${HOST}"
ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${HOST}" 'echo ok' >/dev/null \
  || die "cannot SSH to ${SSH_USER}@${HOST} (set up your key: ssh-copy-id ${SSH_USER}@${HOST})"

log "checking passwordless/cached sudo on the target"
ssh -o BatchMode=yes "${SSH_USER}@${HOST}" 'sudo -n true' \
  || die "sudo requires a password over SSH. Fix on the target: echo '${SSH_USER} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-${SSH_USER}"

log "checking OS is dnf-based"
ssh -o BatchMode=yes "${SSH_USER}@${HOST}" 'command -v dnf >/dev/null' \
  || die "target does not have dnf (only Fedora Server / Rocky Linux are supported)"

# ---- 2. collections ---------------------------------------------------------
log "installing Ansible collections (controller-side)"
ansible-galaxy collection install -r "${REPO_DIR}/requirements.yml" -f >/dev/null

# ---- 3. run the playbook ----------------------------------------------------
EXTRA_ARGS=( )
[[ -n "${PROFILE}" ]] && EXTRA_ARGS+=( -e "@${REPO_DIR}/${PROFILE}" )

# site.yml targets the llama_servers group, so build a temporary grouped
# inventory rather than using Ansible's host-list shorthand.
INVENTORY_FILE="$(mktemp)"
cleanup_inventory() { rm -f "${INVENTORY_FILE}"; }
trap cleanup_inventory EXIT
cat >"${INVENTORY_FILE}" <<EOF
[llama_servers]
target ansible_host=${HOST} ansible_user=${SSH_USER}

[llama_servers:vars]
ansible_python_interpreter=auto_silent
EOF

cd "${REPO_DIR}"
log "running playbook against ${HOST} (this builds llama.cpp — 10–25 min first run)"
ansible-playbook site.yml \
  -i "${INVENTORY_FILE}" \
  --become \
  "${EXTRA_ARGS[@]}"

# ---- 4. verify from the controller ------------------------------------------
log "verifying /health on ${HOST}:${PORT_HTTP}"
for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "http://${HOST}:${PORT_HTTP}/health" >/dev/null 2>&1; then
    log "health OK"
    break
  fi
  [[ $i -eq 60 ]] && die "health check never came up (check: ssh ${SSH_USER}@${HOST} journalctl -u llama-server -e)"
  sleep 5
done

log "sending a test chat completion"
curl -fsS "http://${HOST}:${PORT_HTTP}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Reply with exactly: VERIFIED"}],"max_tokens":20}' \
  | tee /tmp/deploy-verify.json | grep -q 'VERIFIED' \
  || die "chat completion failed — see /tmp/deploy-verify.json"

log "=============================================================="
log "SUCCESS: llama-server is live on ${HOST}"
log "  API:    http://${HOST}:${PORT_HTTP}/v1/chat/completions"
log "  Web UI: http://${HOST}:${PORT_HTTP}/"
log "  Model logs: ssh ${SSH_USER}@${HOST} 'tail -f /var/log/llama.cpp/llama-server.log'"
log "=============================================================="
