#!/usr/bin/env bash
# ============================================================================
# deploy-interactive.sh — interactive deployment wizard for llama.cpp server.
#
# Prompts the user for:
#   1. Target IP or hostname
#   2. SSH username
#   3. Hardware profile (default: profiles/gmktec-evo-x2.yml)
#   4. SSH/sudo password (only if requested or key-based auth is missing)
#
# Automatically probes connectivity, handles SSH key install and passwordless
# sudo bootstrap when needed, runs the Ansible deployment, and verifies
# the running service (/health and /v1/chat/completions).
#
# Usage:
#   ./scripts/deploy-interactive.sh
#   ./scripts/deploy-interactive.sh --host 192.168.0.2 --user gbrennon-local-ai
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT_HTTP=8080

# Colors for terminal output
if [[ -t 1 ]]; then
  BOLD="\033[1m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  RED="\033[0;31m"
  BLUE="\033[0;34m"
  CYAN="\033[0;36m"
  RESET="\033[0m"
else
  BOLD=""
  GREEN=""
  YELLOW=""
  RED=""
  BLUE=""
  CYAN=""
  RESET=""
fi

log_info()  { echo -e "${BLUE}[deploy]${RESET} $*"; }
log_ok()    { echo -e "${GREEN}[deploy] [OK]${RESET} $*"; }
log_warn()  { echo -e "${YELLOW}[deploy] [WARN]${RESET} $*"; }
log_error() { echo -e "${RED}[deploy] [ERROR]:${RESET} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# Parse optional CLI flags (allows non-interactive or pre-seeded usage)
HOST="${GMKTEC_HOST:-}"
SSH_USER="${GMKTEC_USER:-}"
PROFILE="${GMKTEC_PROFILE:-}"
SSH_PASS=""
SUDO_PASS=""
NON_INTERACTIVE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)             HOST="$2"; shift 2 ;;
    --user)             SSH_USER="$2"; shift 2 ;;
    --profile)          PROFILE="$2"; shift 2 ;;
    --password|--pass)  SSH_PASS="$2"; shift 2 ;;
    --sudo-password)    SUDO_PASS="$2"; shift 2 ;;
    --non-interactive)  NON_INTERACTIVE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --host <ip|hostname>      Target host IP or hostname"
      echo "  --user <username>         SSH username on target"
      echo "  --profile <file>          Hardware profile in profiles/"
      echo "  --password <password>     SSH password (if key auth is not set up)"
      echo "  --sudo-password <pass>    Sudo password (if different from SSH)"
      echo "  --non-interactive         Do not prompt interactively"
      echo "  -h, --help                Show this help message"
      exit 0
      ;;
    *)
      if [[ -z "${HOST}" ]]; then
        HOST="$1"
      elif [[ -z "${SSH_USER}" ]]; then
        SSH_USER="$1"
      elif [[ -z "${PROFILE}" ]]; then
        PROFILE="$1"
      else
        die "Unknown argument: $1"
      fi
      shift
      ;;
  esac
done

echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo -e "${BOLD}${CYAN}          llama.cpp Server Deployment Wizard                ${RESET}"
echo -e "${BOLD}${CYAN}============================================================${RESET}"

# ---- Step 1: Target Host / IP ----------------------------------------------
DEFAULT_HOST="192.168.0.2"
if [[ -z "${HOST}" ]]; then
  if [[ "${NON_INTERACTIVE}" == true ]]; then
    HOST="${DEFAULT_HOST}"
  else
    INPUT_HOST=""
    read -r -p "$(echo -e "${BOLD}Target IP or hostname${RESET} [default: ${DEFAULT_HOST}]: ")" INPUT_HOST || true
    HOST="${INPUT_HOST:-${DEFAULT_HOST}}"
  fi
fi
[[ -n "${HOST}" ]] || die "Target IP/hostname cannot be empty"

# ---- Step 2: SSH Username --------------------------------------------------
DEFAULT_USER="gbrennon-local-ai"
# Fall back to current user if default user doesn't match
if [[ -z "${SSH_USER}" ]]; then
  if [[ "${NON_INTERACTIVE}" == true ]]; then
    SSH_USER="${DEFAULT_USER}"
  else
    INPUT_USER=""
    read -r -p "$(echo -e "${BOLD}SSH username on target${RESET} [default: ${DEFAULT_USER}]: ")" INPUT_USER || true
    SSH_USER="${INPUT_USER:-${DEFAULT_USER}}"
  fi
fi
[[ -n "${SSH_USER}" ]] || die "SSH username cannot be empty"

# ---- Step 3: Hardware Profile ----------------------------------------------
DEFAULT_PROFILE="profiles/gmktec-evo-x2.yml"
if [[ -z "${PROFILE}" ]]; then
  AVAILABLE_PROFILES=($(find "${REPO_DIR}/profiles" -name "*.yml" -exec basename {} \; 2>/dev/null || true))
  if [[ ${#AVAILABLE_PROFILES[@]} -eq 0 ]]; then
    PROFILE="${DEFAULT_PROFILE}"
  elif [[ "${NON_INTERACTIVE}" == true ]]; then
    PROFILE="${DEFAULT_PROFILE}"
  else
    echo -e "${BOLD}Available hardware profiles:${RESET}"
    for i in "${!AVAILABLE_PROFILES[@]}"; do
      p="${AVAILABLE_PROFILES[$i]}"
      desc="Profile: ${p}"
      if [[ "${p}" == "gmktec-evo-x2.yml" ]]; then
        desc="GMKtec Evo X2 (AMD Strix Halo 16-core, Radeon 8060S, Vulkan)"
      fi
      echo "  $((i+1))) ${p} — ${desc}"
    done
    INPUT_PROFILE=""
    read -r -p "$(echo -e "${BOLD}Select profile${RESET} [default: ${DEFAULT_PROFILE}]: ")" INPUT_PROFILE || true
    if [[ -z "${INPUT_PROFILE}" ]]; then
      PROFILE="${DEFAULT_PROFILE}"
    elif [[ "${INPUT_PROFILE}" =~ ^[0-9]+$ ]] && (( INPUT_PROFILE >= 1 && INPUT_PROFILE <= ${#AVAILABLE_PROFILES[@]} )); then
      PROFILE="profiles/${AVAILABLE_PROFILES[$((INPUT_PROFILE-1))]}"
    elif [[ -f "${REPO_DIR}/${INPUT_PROFILE}" ]]; then
      PROFILE="${INPUT_PROFILE}"
    elif [[ -f "${REPO_DIR}/profiles/${INPUT_PROFILE}" ]]; then
      PROFILE="profiles/${INPUT_PROFILE}"
    else
      PROFILE="${INPUT_PROFILE}"
    fi
  fi
fi

# Ensure profile path is relative or absolute exists
if [[ ! -f "${REPO_DIR}/${PROFILE}" && ! -f "${PROFILE}" ]]; then
  die "Profile not found: ${PROFILE}"
fi
if [[ -f "${REPO_DIR}/${PROFILE}" ]]; then
  PROFILE_PATH="${REPO_DIR}/${PROFILE}"
else
  PROFILE_PATH="${PROFILE}"
fi

log_info "Target Host: ${BOLD}${HOST}${RESET}"
log_info "SSH User:    ${BOLD}${SSH_USER}${RESET}"
log_info "Profile:     ${BOLD}${PROFILE}${RESET}"

# ---- Step 4: Connectivity & Authentication Probing -------------------------
echo
echo -e "${BOLD}--- [1/4] Probing Target Reachability & Authentication ---${RESET}"

# Check ICMP ping
PING_OK=true
if ! ping -c 1 -W 2 "${HOST}" >/dev/null 2>&1; then
  PING_OK=false
  log_warn "Host ${HOST} does not respond to ICMP ping (might be offline or blocking ping)."
  if [[ "${NON_INTERACTIVE}" == false ]]; then
    PING_CONFIRM=""
    read -r -p "Attempt SSH connection anyway? [Y/n]: " PING_CONFIRM || true
    if [[ "${PING_CONFIRM}" =~ ^[Nn] ]]; then
      die "Deployment aborted by user (host unreachable)"
    fi
  fi
fi

# Check SSH key-based authentication
KEY_AUTH_OK=false
log_info "Checking passwordless SSH key authentication to ${SSH_USER}@${HOST}..."
if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
  KEY_AUTH_OK=true
  log_ok "SSH key authentication succeeded!"
else
  log_warn "Passwordless SSH key authentication is not active for ${SSH_USER}@${HOST}"
fi

# Check sudo access
SUDO_NOPASS_OK=false
if [[ "${KEY_AUTH_OK}" == true ]]; then
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${HOST}" 'sudo -n true' >/dev/null 2>&1; then
    SUDO_NOPASS_OK=true
    log_ok "Passwordless sudo is active on target!"
  else
    log_warn "Sudo requires a password on target."
  fi
fi

# If password is required for SSH or Sudo, request it
PASSWORD_NEEDED=false
if [[ "${KEY_AUTH_OK}" == false || "${SUDO_NOPASS_OK}" == false ]]; then
  PASSWORD_NEEDED=true
fi

if [[ "${PASSWORD_NEEDED}" == true && -z "${SSH_PASS}" ]]; then
  if [[ "${NON_INTERACTIVE}" == true ]]; then
    die "Target requires authentication credentials but none provided in non-interactive mode"
  fi

  echo
  echo -e "${BOLD}${YELLOW}Authentication Credentials Required${RESET}"
  if [[ "${KEY_AUTH_OK}" == false ]]; then
    echo "SSH key access is not configured for ${SSH_USER}@${HOST}."
  else
    echo "Sudo requires a password for ${SSH_USER}@${HOST}."
  fi
  while [[ -z "${SSH_PASS}" ]]; do
    if ! read -r -s -p "$(echo -e "${BOLD}Enter password for ${SSH_USER}@${HOST}:${RESET} ")" SSH_PASS; then
      echo
      die "End of input reached while waiting for password."
    fi
    echo
    if [[ -z "${SSH_PASS}" ]]; then
      echo "Password cannot be empty. Please enter the password."
    fi
  done
fi

# Check if sshpass is available
HAVE_SSHPASS=false
if command -v sshpass >/dev/null 2>&1; then
  HAVE_SSHPASS=true
fi

# If we have password but key auth is not yet set up, offer to bootstrap SSH key and sudo
if [[ "${KEY_AUTH_OK}" == false && -n "${SSH_PASS}" ]]; then
  if [[ "${HAVE_SSHPASS}" == false ]]; then
    log_warn "sshpass is not installed on this machine. Trying to install it or use standard ssh..."
    if command -v dnf >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
      sudo dnf install -y sshpass >/dev/null 2>&1 && HAVE_SSHPASS=true || true
    fi
  fi

  BOOTSTRAP_KEY=true
  if [[ "${NON_INTERACTIVE}" == false ]]; then
    BOOTSTRAP_CHOICE=""
    read -r -p "$(echo -e "${BOLD}Install local SSH key on target for future unattended deploys?${RESET} [Y/n]: ")" BOOTSTRAP_CHOICE || true
    if [[ "${BOOTSTRAP_CHOICE}" =~ ^[Nn] ]]; then
      BOOTSTRAP_KEY=false
    fi
  fi

  if [[ "${BOOTSTRAP_KEY}" == true ]]; then
    # Ensure local SSH key exists
    if [[ ! -f "${HOME}/.ssh/id_ed25519.pub" && ! -f "${HOME}/.ssh/id_rsa.pub" ]]; then
      log_info "Generating local SSH key pair (~/.ssh/id_ed25519)..."
      ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" >/dev/null 2>&1 || true
    fi

    log_info "Installing SSH public key to ${SSH_USER}@${HOST}..."
    if [[ "${HAVE_SSHPASS}" == true ]]; then
      SSHPASS="${SSH_PASS}" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" >/dev/null 2>&1 || {
        log_warn "Automatic ssh-copy-id with sshpass failed; trying direct install..."
      }
    else
      ssh-copy-id -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" || true
    fi

    # Test if key auth works now
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
      KEY_AUTH_OK=true
      log_ok "SSH public key installed and verified!"
    else
      log_warn "SSH key install did not succeed; proceeding with password authentication."
    fi
  fi
fi

# Check / configure passwordless sudo if needed
if [[ "${SUDO_NOPASS_OK}" == false && -n "${SSH_PASS}" ]]; then
  BOOTSTRAP_SUDO=true
  if [[ "${NON_INTERACTIVE}" == false ]]; then
    SUDO_CHOICE=""
    read -r -p "$(echo -e "${BOLD}Configure passwordless sudo on target for ${SSH_USER}?${RESET} [Y/n]: ")" SUDO_CHOICE || true
    if [[ "${SUDO_CHOICE}" =~ ^[Nn] ]]; then
      BOOTSTRAP_SUDO=false
    fi
  fi

  if [[ "${BOOTSTRAP_SUDO}" == true ]]; then
    log_info "Configuring passwordless sudo on target machine..."
    SUDO_CMD="echo '${SSH_PASS}' | sudo -S sh -c 'echo \"${SSH_USER} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/90-${SSH_USER} && chmod 0440 /etc/sudoers.d/90-${SSH_USER}'"
    
    if [[ "${KEY_AUTH_OK}" == true ]]; then
      ssh -o BatchMode=yes "${SSH_USER}@${HOST}" "${SUDO_CMD}" >/dev/null 2>&1 || true
    elif [[ "${HAVE_SSHPASS}" == true ]]; then
      SSHPASS="${SSH_PASS}" sshpass -e ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" "${SUDO_CMD}" >/dev/null 2>&1 || true
    fi

    # Verify sudo
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${HOST}" 'sudo -n true' >/dev/null 2>&1; then
      SUDO_NOPASS_OK=true
      log_ok "Passwordless sudo configured and verified!"
    else
      log_warn "Passwordless sudo configuration did not succeed; Ansible will use become password."
    fi
  fi
fi

# ---- Step 5: Verify Target OS Requirements ---------------------------------
echo
echo -e "${BOLD}--- [2/4] Verifying Target OS Requirements ---${RESET}"
log_info "Checking target OS (must be dnf-based: Fedora / Rocky Linux)..."

CHECK_DNF_CMD="command -v dnf >/dev/null"
DNF_OK=false
if [[ "${KEY_AUTH_OK}" == true ]]; then
  if ssh -o BatchMode=yes "${SSH_USER}@${HOST}" "${CHECK_DNF_CMD}"; then
    DNF_OK=true
  fi
elif [[ "${HAVE_SSHPASS}" == true && -n "${SSH_PASS}" ]]; then
  if SSHPASS="${SSH_PASS}" sshpass -e ssh "${SSH_USER}@${HOST}" "${CHECK_DNF_CMD}"; then
    DNF_OK=true
  fi
fi

if [[ "${DNF_OK}" == true ]]; then
  log_ok "Target OS has dnf package manager."
else
  die "Target machine ${HOST} does not have 'dnf'. Only Fedora Server / Rocky Linux are supported."
fi

# ---- Step 6: Controller Dependencies & Collections -------------------------
echo
echo -e "${BOLD}--- [3/4] Preparing Ansible & Collections ---${RESET}"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found on controller. Run: sudo dnf install -y ansible"

log_info "Installing Ansible collections from requirements.yml..."
ansible-galaxy collection install -r "${REPO_DIR}/requirements.yml" -f >/dev/null
log_ok "Ansible collections ready."

# ---- Step 7: Build Dynamic Inventory & Run Deployment ----------------------
echo
echo -e "${BOLD}--- [4/4] Executing Deployment ---${RESET}"

INVENTORY_FILE="$(mktemp /tmp/deploy-inv-XXXXXX.ini)"
cleanup_inventory() { rm -f "${INVENTORY_FILE}"; }
trap cleanup_inventory EXIT

# Build inventory file with authentication vars if needed
cat >"${INVENTORY_FILE}" <<EOF
[llama_servers]
target ansible_host=${HOST} ansible_user=${SSH_USER}

[llama_servers:vars]
ansible_python_interpreter=auto_silent
EOF

# If key auth is not working or sudo requires password, supply password variables to Ansible
if [[ "${KEY_AUTH_OK}" == false && -n "${SSH_PASS}" ]]; then
  echo "ansible_ssh_pass=${SSH_PASS}" >>"${INVENTORY_FILE}"
fi
if [[ "${SUDO_NOPASS_OK}" == false ]]; then
  ACTUAL_SUDO_PASS="${SUDO_PASS:-${SSH_PASS}}"
  if [[ -n "${ACTUAL_SUDO_PASS}" ]]; then
    echo "ansible_become_password=${ACTUAL_SUDO_PASS}" >>"${INVENTORY_FILE}"
  fi
fi

EXTRA_VARS_ARGS=( -e "@${PROFILE_PATH}" )

log_info "Running Ansible playbook against ${BOLD}${SSH_USER}@${HOST}${RESET}..."
log_info "Profile: ${BOLD}${PROFILE}${RESET}"

cd "${REPO_DIR}"
ansible-playbook site.yml \
  -i "${INVENTORY_FILE}" \
  --become \
  "${EXTRA_VARS_ARGS[@]}"

# ---- Step 8: Post-Deploy Verification --------------------------------------
echo
echo -e "${BOLD}============================================================${RESET}"
echo -e "${BOLD}               Post-Deployment Verification                 ${RESET}"
echo -e "${BOLD}============================================================${RESET}"

log_info "Waiting for /health endpoint on http://${HOST}:${PORT_HTTP}/health..."
HEALTH_OK=false
for i in $(seq 1 60); do
  if curl -fsS --max-time 5 "http://${HOST}:${PORT_HTTP}/health" >/dev/null 2>&1; then
    HEALTH_OK=true
    log_ok "Health check OK!"
    break
  fi
  sleep 3
done

if [[ "${HEALTH_OK}" == false ]]; then
  die "Health check timed out after 180s. Check logs on target: ssh ${SSH_USER}@${HOST} 'journalctl -u llama-server -n 50'"
fi

log_info "Sending verification chat completion to http://${HOST}:${PORT_HTTP}/v1/chat/completions..."
TEST_RESPONSE="$(curl -fsS --max-time 30 "http://${HOST}:${PORT_HTTP}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Respond with exactly: VERIFIED"}],"max_tokens":20}' 2>&1 || true)"

if echo "${TEST_RESPONSE}" | grep -q 'VERIFIED'; then
  log_ok "Chat completion verified successfully!"
else
  log_warn "Chat completion responded, but 'VERIFIED' not detected in response: ${TEST_RESPONSE}"
fi

echo
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  SUCCESS: llama.cpp server is deployed and operational!    ${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "  Target Host: ${BOLD}${HOST}${RESET}"
echo -e "  API Base:    ${CYAN}http://${HOST}:${PORT_HTTP}/v1${RESET}"
echo -e "  Health Check:${CYAN}http://${HOST}:${PORT_HTTP}/health${RESET}"
echo -e "  Web UI:      ${CYAN}http://${HOST}:${PORT_HTTP}/${RESET}"
echo -e "  Server Logs: ssh ${SSH_USER}@${HOST} 'tail -f /var/log/llama.cpp/llama-server.log'"
echo -e "  Service:     ssh ${SSH_USER}@${HOST} 'systemctl status llama-server'"
echo
