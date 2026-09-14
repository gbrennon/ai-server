#!/usr/bin/env bash
# ============================================================================
# deploy-gmktec.sh — one-command deploy to a GMKtec EVO X2 mini PC.
#
# Wraps deploy-remote.sh with the GMKtec EVO X2 GPU profile (Vulkan backend,
# -ngl 99, Qwen3-30B-A3B) so you never pass the hardware profile by hand.
# An optional --setup flag handles the one-time host bootstrap (SSH key
# install + passwordless sudo), turning a fresh mini PC into a live server
# with a single command.
#
# Usage:
#   ./scripts/deploy-gmktec.sh                       # host from $GMKTEC_HOST
#   ./scripts/deploy-gmktec.sh <host>                # user from $GMKTEC_USER or current user
#   ./scripts/deploy-gmktec.sh <host> <ssh-user>     # explicit user
#   ./scripts/deploy-gmktec.sh <host> <ssh-user> --setup   # one-time bootstrap + deploy
#
# Configuration (environment variables, 12-factor style):
#   GMKTEC_HOST      target IP/hostname (may also be passed as an argument)
#   GMKTEC_USER      SSH user        (default: current user)
#   GMKTEC_PROFILE   profile file    (default: profiles/gmktec-evo-x2.yml)
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DEPLOY_SCRIPT="${REPO_DIR}/scripts/deploy-remote.sh"
readonly DEFAULT_PROFILE="profiles/gmktec-evo-x2.yml"

HOST="${GMKTEC_HOST:-}"
SSH_USER="${GMKTEC_USER:-$(id -un)}"
PROFILE="${GMKTEC_PROFILE:-${DEFAULT_PROFILE}}"
SETUP_BOOTSTRAP=false

log() { echo "[deploy-gmktec] $*"; }
die() { echo "[deploy-gmktec] ERROR: $*" >&2; exit 1; }

POSITIONAL=()
for arg in "$@"; do
  case "${arg}" in
    --setup) SETUP_BOOTSTRAP=true ;;
    --*)     die "unknown option: ${arg}" ;;
    *)       POSITIONAL+=("${arg}") ;;
  esac
done

(( ${#POSITIONAL[@]} >= 1 )) && HOST="${POSITIONAL[0]}"
(( ${#POSITIONAL[@]} >= 2 )) && SSH_USER="${POSITIONAL[1]}"

[[ -n "${HOST}" ]] || die "no target host — pass <host> or set GMKTEC_HOST"
[[ -f "${REPO_DIR}/${PROFILE}" ]] || die "profile not found: ${PROFILE}"
[[ -f "${DEPLOY_SCRIPT}" ]]     || die "missing dependency: ${DEPLOY_SCRIPT}"

bootstrap_target() {
  local host="$1"
  local user="$2"
  log "bootstrap: installing SSH public key on ${user}@${host}"
  ssh-copy-id "${user}@${host}"
  log "bootstrap: enabling passwordless sudo for ${user} (enter the sudo password when prompted)"
  ssh -t "${user}@${host}" \
    "echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-${user}"
  log "bootstrap: ${host} is ready for unattended deploys"
}

if [[ "${SETUP_BOOTSTRAP}" == true ]]; then
  bootstrap_target "${HOST}" "${SSH_USER}"
fi

log "deploying to ${SSH_USER}@${HOST} with profile ${PROFILE}"
"${DEPLOY_SCRIPT}" "${HOST}" "${SSH_USER}" "${PROFILE}"
