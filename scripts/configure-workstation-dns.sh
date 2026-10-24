#!/usr/bin/env bash
set -euo pipefail

nmcli_bin="${NMCLI_BIN:-nmcli}"
resolvectl_bin="${RESOLVECTL_BIN:-resolvectl}"
dns_server="${WORKSTATION_DNS_SERVER:-192.168.0.2}"
internal_domain="${WORKSTATION_DNS_DOMAIN:-gbrennon.home.arpa}"
api_hostname="${WORKSTATION_DNS_API_HOSTNAME:-api.gbrennon.home.arpa}"

fail() {
  printf '%s\n' "$1" >&2
  exit 2
}

require_root() {
  if [[ "${WORKSTATION_DNS_ALLOW_NONROOT:-0}" != 1 && "$(id -u)" != 0 ]]; then
    fail "Run this command with sudo."
  fi
}

active_connection() {
  "$nmcli_bin" -t -f NAME,TYPE,DEVICE connection show --active \
    | awk -F: '$2 == "802-3-ethernet" || $2 == "802-11-wireless" {print $1; exit}'
}

contains_value() {
  local values="$1"
  local expected="$2"
  local value
  for value in $values; do
    [[ "$value" == "$expected" ]] && return 0
  done
  return 1
}

update_dns() {
  local connection="$1"
  local dns_values
  local search_values
  dns_values="$($nmcli_bin -g ipv4.dns connection show "$connection")"
  search_values="$($nmcli_bin -g ipv4.dns-search connection show "$connection")"
  if ! contains_value "$dns_values" "$dns_server"; then
    dns_values="${dns_values} ${dns_server}"
  fi
  if ! contains_value "$search_values" "~${internal_domain}"; then
    search_values="${search_values} ~${internal_domain}"
  fi
  read -r -a dns_values <<< "$dns_values"
  read -r -a search_values <<< "$search_values"
  "$nmcli_bin" connection modify "$connection" \
    ipv4.dns "${dns_values[*]}" \
    ipv4.dns-search "${search_values[*]}"
  "$nmcli_bin" connection up "$connection" >/dev/null
}

verify_resolution() {
  "$resolvectl_bin" query "$api_hostname" >/dev/null \
    || fail "Could not resolve ${api_hostname} through the workstation resolver."
}

require_root
connection="${NETWORK_CONNECTION:-$(active_connection)}"
[[ -n "$connection" ]] || fail "No active NetworkManager connection was found."
update_dns "$connection"
verify_resolution
printf 'Workstation DNS now routes %s through %s on %s.\n' \
  "$internal_domain" "$dns_server" "$connection"
