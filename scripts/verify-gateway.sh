#!/usr/bin/env bash
# ============================================================================
# verify-gateway.sh — idempotent health check for the Caddy + dnsmasq gateway.
#
#   1. DNS:      dig @127.0.0.1 -p 53 api.ai-gbrennon.home.arpa +short == <LAN IP>
#   2. API:      curl -k https://api.ai-gbrennon.home.arpa/health        -> {"status":"ok"}
#   3. Streaming: curl -k -N https://api.ai-gbrennon.home.arpa/v1/models -> HTTP 200 / local TLS
#   4. (bonus)   a wildcard hostname resolves to the same LAN IP
#
# Usage:  ./scripts/verify-gateway.sh
# Values come from group_vars/all.yml; override with env vars GATEWAY_DOMAIN,
# GATEWAY_API_HOSTNAME, GATEWAY_LAN_IP, GATEWAY_LLAMA_PORT.
#
# curl uses --resolve so it bypasses the system resolver and talks straight to
# the address the DNS record returns (DNS correctness is checked separately).
# ============================================================================
set -uo pipefail

GV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/group_vars/all.yml"

read_literal() {
  local v
  v="$(grep -E "^${1}:" "${GV}" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '"\r')"
  if [[ -n "$v" && "$v" != *'{{'* ]]; then printf '%s' "$v"; fi
}

DOMAIN="$(read_literal gateway_domain)";          DOMAIN="${GATEWAY_DOMAIN:-${DOMAIN:-ai-gbrennon.home.arpa}}"
API_HOST="$(read_literal gateway_api_hostname)";  API_HOST="${GATEWAY_API_HOSTNAME:-${API_HOST:-api.${DOMAIN}}}"
LLAMA_PORT="$(read_literal gateway_llama_port)"; LLAMA_PORT="${GATEWAY_LLAMA_PORT:-${LLAMA_PORT:-8080}}"

EXPECTED_IP="${GATEWAY_LAN_IP:-}"
if [[ -z "$EXPECTED_IP" ]]; then
  EXPECTED_IP="$(read_literal gateway_lan_ip)"
fi
if [[ -z "$EXPECTED_IP" ]]; then
  EXPECTED_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -nE 's/.*src ([0-9.]+).*/\1/p' | head -1)"
  [[ -z "$EXPECTED_IP" ]] && EXPECTED_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi
: "${EXPECTED_IP:?cannot determine host LAN IP — set GATEWAY_LAN_IP}"

RESOLVER="127.0.0.1"
API_URL="https://${API_HOST}"
RESOLVE_ARG="${API_HOST}:443:${EXPECTED_IP}"

pass=0; fail=0
ok()   { echo "  PASS: $*";  pass=$((pass+1)); }
bad()  { echo "  FAIL: $*";  fail=$((fail+1)); }
warn() { echo "  WARN: $*"; }

echo "== ai-server gateway verification =="
echo "  zone:     $DOMAIN"
echo "  api host: $API_HOST -> $EXPECTED_IP"
echo "  resolver: $RESOLVER:53 | llama: $LLAMA_PORT"
echo

# --- 1. DNS resolution --------------------------------------------------------
echo "[1] DNS: $API_HOST via $RESOLVER:53"
if ! command -v dig >/dev/null 2>&1; then
  warn "dig not installed; skipping DNS checks (install bind-utils / dnsutils)"
else
  got="$(dig +short @"$RESOLVER" -p 53 "$API_HOST" A 2>/dev/null | head -1)"
  if [[ "$got" == "$EXPECTED_IP" ]]; then
    ok "$API_HOST = $got"
  else
    bad "expected $EXPECTED_IP, got '${got:-<empty>}' (is dnsmasq running? journalctl -u dnsmasq)"
  fi
  printf "  [wildcard] any host under %s -> LAN IP\n" "$DOMAIN"
  wg="$(dig +short @"$RESOLVER" -p 53 "edge.${DOMAIN}" A 2>/dev/null | head -1)"
  if [[ "$wg" == "$EXPECTED_IP" ]]; then
    ok "*.${DOMAIN} resolves to $wg"
  else
    bad "wildcard *.${DOMAIN} = '${wg:-<empty>}'"
  fi
fi

# --- 2. Inference API health ---------------------------------------------------
echo "[2] API health: $API_URL/health (curl -k)"
HEALTH_BODY="$(mktemp)"
code="$(curl -k -sS --resolve "$RESOLVE_ARG" -o "$HEALTH_BODY" -w '%{http_code}' \
        --max-time 10 "${API_URL}/health" 2>/dev/null)"
if [[ "$code" == "200" ]] && grep -q '"status":"ok"' "$HEALTH_BODY"; then
  ok "/health -> HTTP 200, {\"status\":\"ok\"}"
else
  bad "/health -> HTTP $code, body=$(tr -d '\n' <"$HEALTH_BODY")"
fi
rm -f "$HEALTH_BODY"

# --- 3. Streaming endpoint responsiveness --------------------------------------
echo "[3] streaming: $API_URL/v1/models (curl -k -N, local TLS)"
MODELS_BODY="$(mktemp)"
code="$(curl -k -N -sS --resolve "$RESOLVE_ARG" -o "$MODELS_BODY" -w '%{http_code}' \
        --max-time 15 "${API_URL}/v1/models" 2>/dev/null)"
if [[ "$code" == "200" ]] && [[ -s "$MODELS_BODY" ]]; then
  ok "/v1/models -> HTTP 200 ($(wc -c <"$MODELS_BODY") bytes, streaming over local TLS)"
else
  bad "/v1/models -> HTTP $code, body=$(tr -d '\n' <"$MODELS_BODY")"
fi
rm -f "$MODELS_BODY"

echo
echo "== result: $pass passed, $fail failed =="
exit $(( fail > 0 ? 1 : 0 ))
