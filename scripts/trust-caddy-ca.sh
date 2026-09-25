#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${CADDY_DATA_DIR:-/var/lib/caddy}"
CA_SRC="${DATA_DIR}/caddy/pki/authorities/local/root.crt"

log() { echo "[trust-ca] $*"; }
die() { echo "[trust-ca] ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || { echo "[trust-ca] run as root:  sudo $0" >&2; exit 1; }
[[ -s "$CA_SRC" ]] || die "no CA at $CA_SRC — run the gateway role first (make gateway-only)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cp "$CA_SRC" "$tmp"
log "exported Caddy local root CA: $CA_SRC"

if grep -qiE 'ID(_LIKE)?="?(fedora|rhel|rocky|alma|centos|ol)' /etc/os-release 2>/dev/null; then
  DEST=/etc/pki/ca-trust/source/anchors/caddy-local-ai-root.crt
  install -m 0644 "$tmp" "$DEST"
  update-ca-trust extract
  log "installed: $DEST (update-ca-trust extract)"
elif grep -qiE 'ID(_LIKE)?="?(debian|ubuntu)' /etc/os-release 2>/dev/null; then
  DEST=/usr/local/share/ca-certificates/ai-gateway-root.crt
  install -m 0644 "$tmp" "$DEST"
  update-ca-certificates >/dev/null
  log "installed: $DEST (update-ca-certificates)"
else
  DEST="$(pwd)/caddy-local-root.crt"
  install -m 0644 "$tmp" "$DEST"
  log "WARN: unknown distro — CA written to $DEST; trust it manually"
fi

log "done. Verify with:  ./scripts/verify-gateway.sh"
