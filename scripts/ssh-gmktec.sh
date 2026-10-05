#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-192.168.0.2}"
SSH_USER="${2:-gbrennon-local-ai}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_ed25519}"

if (( $# > 2 )); then
  printf 'usage: %s [host] [user]\n' "$0" >&2
  exit 2
fi

exec ssh \
  -o IdentitiesOnly=yes \
  -i "${SSH_KEY}" \
  -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no \
  "${SSH_USER}@${HOST}"
