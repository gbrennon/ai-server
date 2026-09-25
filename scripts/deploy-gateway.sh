#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_HOSTNAME="api.ai-gbrennon.home.arpa"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
INVENTORY_FILE=""

log() { echo "[deploy-gateway] $*"; }
die() { echo "[deploy-gateway] ERROR: $*" >&2; exit 1; }

remove_inventory() { rm -f "${INVENTORY_FILE}"; }

require_ansible() {
  command -v ansible-playbook >/dev/null \
    || die "ansible not installed (python3 -m pip install --user ansible)"
}

assert_ssh_reachable() {
  local endpoint="$1"
  log "checking SSH connectivity to ${endpoint}"
  ssh "${SSH_OPTS[@]}" "${endpoint}" 'echo ok' >/dev/null \
    || die "cannot SSH to ${endpoint} (ssh-copy-id ${endpoint})"
}

assert_passwordless_sudo() {
  local endpoint="$1" user="$2"
  log "checking passwordless/cached sudo on ${endpoint}"
  ssh "${SSH_OPTS[@]}" "${endpoint}" 'sudo -n true' \
    || die "sudo needs a password: echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-${user}"
}

install_ansible_collections() {
  log "installing Ansible collections (controller-side)"
  ansible-galaxy collection install -r "${REPO_DIR}/requirements.yml" -f >/dev/null
}

write_target_inventory() {
  local path="$1" host="$2" user="$3"
  cat >"${path}" <<EOF
[llama_servers]
target ansible_host=${host} ansible_user=${user}

[llama_servers:vars]
ansible_python_interpreter=auto_silent
EOF
}

deploy_gateway_role() {
  local inventory="$1" host="$2" lan_ip="$3"
  log "deploying gateway (Caddy + dnsmasq) to ${host}, resolving *.ai-gbrennon.home.arpa -> ${lan_ip}"
  (cd "${REPO_DIR}" && ansible-playbook site.yml \
    -i "${inventory}" \
    --become \
    --tags gateway \
    -e gateway_enabled=true \
    -e gateway_dns_lan_listen=true \
    -e "gateway_lan_ip=${lan_ip}")
}

assert_dnsmasq_resolves() {
  local endpoint="$1" lan_ip="$2"
  log "verifying DNS on ${endpoint} (dnsmasq @127.0.0.1:53)"
  ssh "${SSH_OPTS[@]}" "${endpoint}" python3 - "${lan_ip}" "${API_HOSTNAME}" \
    <"${REPO_DIR}/scripts/dns-probe.py" \
    || die "dnsmasq did not resolve ${API_HOSTNAME} to ${lan_ip}"
}

check_gateway_health() {
  local endpoint="$1"
  local ca_bundle="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
  log "checking strict TLS health on ${endpoint}"
  ssh "${SSH_OPTS[@]}" "${endpoint}" \
    "curl --fail --silent --show-error --cacert ${ca_bundle} \
      --resolve ${API_HOSTNAME}:443:127.0.0.1 \
      https://${API_HOSTNAME}/health | grep -q '\"status\":\"ok\"'" \
    || die "strict TLS health check failed for ${API_HOSTNAME}"
}
check_llm_api() {
  local endpoint="$1"
  local ca_bundle="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
  log "checking strict TLS LLM API on ${endpoint}"
  ssh "${SSH_OPTS[@]}" "${endpoint}" \
    "curl --fail --silent --show-error --cacert ${ca_bundle} \
      --resolve ${API_HOSTNAME}:443:127.0.0.1 \
      --output /dev/null --write-out 'HTTP=%{http_code}\\n' \
      https://${API_HOSTNAME}/v1/models" \
    || die "strict TLS LLM API check failed for ${API_HOSTNAME}"
}


main() {
  local host="${1:?Usage: deploy-gateway.sh <host> [ssh-user] [lan-ip]}"
  local user="${2:-$(id -un)}"
  local lan_ip="${3:-$host}"
  local endpoint="${user}@${host}"

  require_ansible
  assert_ssh_reachable "${endpoint}"
  assert_passwordless_sudo "${endpoint}" "${user}"
  install_ansible_collections

  INVENTORY_FILE="$(mktemp)"
  trap remove_inventory EXIT
  write_target_inventory "${INVENTORY_FILE}" "${host}" "${user}"

  deploy_gateway_role "${INVENTORY_FILE}" "${host}" "${lan_ip}"
  assert_dnsmasq_resolves "${endpoint}" "${lan_ip}"
  check_gateway_health "${endpoint}"
  check_llm_api "${endpoint}"

  log "SUCCESS: gateway live on ${host} (https://${API_HOSTNAME})"
}

main "$@"
