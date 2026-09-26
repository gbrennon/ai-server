#!/usr/bin/env bash
# ============================================================================
# verify-pi-ratatui.sh — end-to-end verification of local LLM on GMKtec Evo X2
#
# Steps:
#   1. Waits for / verifies target host connectivity (192.168.0.2)
#   2. Deploys updated configuration with stability flags
#   3. Delegates a coding task to the local Qwen3.8-27B model via Pi agent:
#      - Initializing a Rust application using cargo CLI
#      - Adding ratatui and crossterm dependencies
#      - Creating a functioning ratatui terminal UI
#   4. Verifies the Rust application builds cleanly (cargo check / cargo build)
#   5. Verifies llama-server remains healthy without crashing or restarts
#
# Usage:
#   ./scripts/verify-pi-ratatui.sh [host] [user]
#   ./scripts/verify-pi-ratatui.sh 192.168.0.2 gbrennon-local-ai
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="192.168.0.2"
SSH_USER="gbrennon-local-ai"
TIMEOUT_SEC=300
MODEL_NAME="Qwen3.8-27B-UD-Q4_K_M.gguf"
PROVIDER_NAME="evo-x2-llamacpp"
TEST_DIR="/tmp/pi-ratatui-verification"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)     HOST="$2"; shift 2 ;;
    --user)     SSH_USER="$2"; shift 2 ;;
    --timeout)  TIMEOUT_SEC="$2"; shift 2 ;;
    *)
      if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        HOST="$1"
      else
        SSH_USER="$1"
      fi
      shift
      ;;
  esac
done

# Colors
if [[ -t 1 ]]; then
  BOLD="\033[1m"
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  RED="\033[0;31m"
  CYAN="\033[0;36m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

log()   { echo -e "${CYAN}[verify-pi]${RESET} $*"; }
ok()    { echo -e "${GREEN}[verify-pi] [OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[verify-pi] [WARN]${RESET} $*"; }
die()   { echo -e "${RED}[verify-pi] [ERROR]:${RESET} $*" >&2; exit 1; }

echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo -e "${BOLD}${CYAN}   GMKtec Evo X2 Local Model Verification with Pi Agent    ${RESET}"
echo -e "${BOLD}${CYAN}============================================================${RESET}"
echo "Target Host:    ${HOST}"
echo "SSH User:       ${SSH_USER}"
echo "Model:          ${MODEL_NAME}"
echo "Provider:       ${PROVIDER_NAME}"
echo "Scratch Dir:    ${TEST_DIR}"
echo

# ---- Step 1: Connectivity Check --------------------------------------------
log "Step 1: Checking host reachability (${HOST})..."

if ! ping -c 1 -W 2 "${HOST}" >/dev/null 2>&1; then
  warn "Host ${HOST} is currently offline or unreachable."
  echo -e "${YELLOW}Please press the physical power button on the GMKtec Evo X2 mini PC to turn it on.${RESET}"
  echo "Waiting up to ${TIMEOUT_SEC}s for host to become reachable..."

  HOST_ONLINE=false
  MAX_ATTEMPTS=$((TIMEOUT_SEC / 3))
  for i in $(seq 1 "${MAX_ATTEMPTS}"); do
    if ping -c 1 -W 2 "${HOST}" >/dev/null 2>&1; then
      HOST_ONLINE=true
      break
    fi
    printf "."
    sleep 3
  done
  echo
  if [[ "${HOST_ONLINE}" == false ]]; then
    die "Host ${HOST} did not become reachable. Verify power cable and network connection."
  fi
fi

ok "Host ${HOST} is reachable via ICMP."

# Wait for SSH
log "Verifying SSH availability..."
SSH_UP=false
for i in $(seq 1 30); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
    SSH_UP=true
    break
  fi
  sleep 2
done
[[ "${SSH_UP}" == true ]] || die "SSH connection to ${SSH_USER}@${HOST} failed."
ok "SSH connection established."

# ---- Step 2: Deployment ----------------------------------------------------
log "Step 2: Deploying llama.cpp with Strix Halo stability profile..."
"${REPO_DIR}/scripts/deploy-interactive.sh" \
  --host "${HOST}" \
  --user "${SSH_USER}" \
  --profile profiles/gmktec-evo-x2.yml \
  --non-interactive

ok "Deployment completed and server /health verified."

# ---- Step 3: Check Systemd & Active Flags ----------------------------------
log "Step 3: Verifying running service command-line arguments..."
RUNNING_ARGS="$(ssh "${SSH_USER}@${HOST}" 'ps aux | grep llama-server | grep -v grep' || true)"
echo "${RUNNING_ARGS}"

if echo "${RUNNING_ARGS}" | grep -q -- '--no-cache-prompt'; then
  ok "Flag --no-cache-prompt is active."
else
  warn "Flag --no-cache-prompt not detected in running process."
fi

# ---- Step 4: Delegate to Pi Agent ------------------------------------------
log "Step 4: Delegating Rust ratatui project creation to local model via Pi..."

rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}"
cd "${TEST_DIR}"

log "Starting Pi non-interactive session in ${TEST_DIR}..."

PI_PROMPT="You are building a terminal UI Rust project in the current working directory.
Follow these steps:
1. Run \`cargo init --bin\` to initialize a new Rust binary crate.
2. Add dependencies \`ratatui = \"0.29\"\` and \`crossterm = \"0.28\"\` to Cargo.toml.
3. Replace src/main.rs with a complete, compiling Ratatui application that renders a centered Paragraph widget with the text 'Hello from GMKtec Evo X2!'. Use crossterm for backend initialization and restore the terminal cleanly on exit.
4. Run \`cargo check\` to verify compilation."

pi --provider "${PROVIDER_NAME}" \
   --model "${MODEL_NAME}" \
   -p "${PI_PROMPT}" || die "Pi execution failed"

# ---- Step 5: Verify Rust Code & Build --------------------------------------
log "Step 5: Verifying generated Rust application..."

[[ -f "${TEST_DIR}/Cargo.toml" ]] || die "Cargo.toml was not created by the model."
[[ -f "${TEST_DIR}/src/main.rs" ]] || die "src/main.rs was not created by the model."

log "Running cargo check in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo check) || die "Rust project failed cargo check."
ok "Rust project passed cargo check!"

log "Running cargo build in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo build --release) || die "Rust project failed release build."
ok "Rust project built successfully!"

# ---- Step 6: Post-Task Stability Check -------------------------------------
log "Step 6: Verifying llama-server stability after multi-turn generation..."

HEALTH_STATUS="$(curl -fsS --max-time 5 "http://${HOST}:8080/health" 2>/dev/null || true)"
if [[ "${HEALTH_STATUS}" == *'"status":"ok"'* || "${HEALTH_STATUS}" == *'"status": "ok"'* ]]; then
  ok "llama-server health is OK after generation."
else
  die "llama-server health check failed after generation (server may have crashed)."
fi

SERVICE_STATUS="$(ssh "${SSH_USER}@${HOST}" 'systemctl is-active llama-server' || true)"
if [[ "${SERVICE_STATUS}" == "active" ]]; then
  ok "llama-server systemd service is active."
else
  die "llama-server systemd service is not active (${SERVICE_STATUS})."
fi

echo
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  VERIFICATION PASSED: Mini PC hosts a fully usable model!  ${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "  Host:         ${HOST}"
echo -e "  Model:        ${MODEL_NAME}"
echo -e "  Ratatui App:  ${TEST_DIR}/target/release"
echo
