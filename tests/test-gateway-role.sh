#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKS="${ROOT}/roles/gateway/tasks/main.yml"
DEFAULTS="${ROOT}/roles/gateway/defaults/main.yml"
CADDY="${ROOT}/roles/gateway/templates/Caddyfile.j2"
DNSMASQ="${ROOT}/roles/gateway/templates/dnsmasq-ai.conf.j2"

# The gateway must be opt-in (off by default), like the performance role.
grep -q 'gateway_enabled: false' "${DEFAULTS}"

# Wildcard DNS: dnsmasq answers every host under the zone with the LAN IP.
grep -q 'address=/{{ gateway_domain }}/{{ gateway_lan_ip }}' "${DNSMASQ}"

# Caddy config: SSE streaming, no body limit, local CA, proxy to 127.0.0.1.
grep -q 'flush_interval -1' "${CADDY}"
grep -q 'max_size 0' "${CADDY}"
grep -q 'tls internal' "${CADDY}"
grep -q 'reverse_proxy 127.0.0.1:{{ gateway_llama_port }}' "${CADDY}"

# Tasks: install resolver + proxy, open the DNS/HTTP(S) ports, enable services.
grep -q 'name: dnsmasq$' "${TASKS}"
grep -q -- '- 53/tcp' "${TASKS}"
grep -q -- '- 80/tcp' "${TASKS}"
grep -q -- '- 443/tcp' "${TASKS}"
grep -q 'name: caddy$' "${TASKS}"

# Wired into the playbook and the Makefile.
grep -q -- '- role: gateway' "${ROOT}/site.yml"
grep -q 'gateway-only' "${ROOT}/Makefile"

# Verify + CA-trust helpers exist.
[[ -x "${ROOT}/scripts/verify-gateway.sh" ]]
[[ -x "${ROOT}/scripts/trust-caddy-ca.sh" ]]

# Caddy install directory is created before the binary is downloaded.
grep -q 'gateway_caddy_install | dirname' "${TASKS}"

# Caddyfile is owned by the caddy service user so the non-root process can read it.
grep -q 'owner: caddy' "${TASKS}"

grep -q 'gateway_ca_anchor' "${DEFAULTS}"
grep -q 'gateway_ca_bundle' "${DEFAULTS}"
grep -q 'gateway_ca_profile' "${DEFAULTS}"
grep -q 'gateway_ca_source' "${TASKS}"
grep -q 'remote_src: true' "${TASKS}"
grep -q 'ai-gateway-ca.sh.j2' "${TASKS}"
grep -q 'Update system CA trust' "${ROOT}/roles/gateway/handlers/main.yml"
grep -q 'REQUESTS_CA_BUNDLE' \
  "${ROOT}/roles/gateway/templates/ai-gateway-ca.sh.j2"
grep -q 'gateway_manage_hosts' "${DEFAULTS}"
grep -q 'gateway_api_hostname' "${TASKS}"
grep -q 'strict TLS health' "${ROOT}/scripts/deploy-gateway.sh"
grep -q -- '--cacert ${ca_bundle}' \
  "${ROOT}/scripts/deploy-gateway.sh"
grep -q 'strict TLS LLM API' "${ROOT}/scripts/deploy-gateway.sh"
grep -q '/v1/models' "${ROOT}/scripts/deploy-gateway.sh"
! grep -q -- 'curl -k' "${ROOT}/scripts/deploy-gateway.sh"


echo 'PASS'
