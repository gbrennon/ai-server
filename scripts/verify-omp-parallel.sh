#!/usr/bin/env bash
# ============================================================================
# verify-omp-parallel.sh — end-to-end verification of local LLM on GMKtec Evo X2
# with parallel factor 2 using OMP (Oh My Pi) agents and concurrency benchmarking
#
# Steps:
#   1. Connectivity & SSH Verification (192.168.0.2)
#   2. Verifies running llama-server args contain --parallel 2 (or deploys)
#   3. Micro-benchmark: Sequential vs Concurrent request timings across Slot 0 & 1
#   4. Concurrent OMP Agent Task: Dual agents generate Ratatui Rust components
#   5. Verifies generated Rust crate compiles cleanly (cargo check / cargo build)
#   6. Post-Task Stability & SSH Telemetry Audit (power, thermals, health, slots)
#
# Usage:
#   ./scripts/verify-omp-parallel.sh [host] [user]
#   ./scripts/verify-omp-parallel.sh --host 192.168.0.2 --user gbrennon-local-ai
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="192.168.0.2"
SSH_USER="gbrennon-local-ai"
TIMEOUT_SEC=300
MODEL_ID="/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
OMP_MODEL="evo-x2-llamacpp/Qwen3.8-27B-UD-Q4_K_M.gguf"
TEST_DIR="/tmp/omp-parallel-verification"

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
  MAGENTA="\033[0;35m"
  RESET="\033[0m"
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" MAGENTA="" RESET=""
fi

log()   { echo -e "${CYAN}[verify-omp]${RESET} $*"; }
ok()    { echo -e "${GREEN}[verify-omp] [OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[verify-omp] [WARN]${RESET} $*"; }
die()   { echo -e "${RED}[verify-omp] [ERROR]:${RESET} $*" >&2; exit 1; }

echo -e "${BOLD}${MAGENTA}============================================================${RESET}"
echo -e "${BOLD}${MAGENTA}   GMKtec Evo X2 OMP Parallel (2 Slots) Verification       ${RESET}"
echo -e "${BOLD}${MAGENTA}============================================================${RESET}"
echo "Target Host:    ${HOST}"
echo "SSH User:       ${SSH_USER}"
echo "Model ID:       ${MODEL_ID}"
echo "OMP Model:      ${OMP_MODEL}"
echo "Scratch Dir:    ${TEST_DIR}"
echo

# ---- Step 1: Connectivity Check --------------------------------------------
log "Step 1: Checking host reachability (${HOST})..."
if ! ping -c 1 -W 2 "${HOST}" >/dev/null 2>&1; then
  warn "Host ${HOST} is currently offline or unreachable."
  die "Host ${HOST} did not respond to ICMP ping."
fi
ok "Host ${HOST} is reachable via ICMP."

log "Verifying SSH availability..."
SSH_UP=false
for i in $(seq 1 15); do
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${HOST}" 'echo ok' >/dev/null 2>&1; then
    SSH_UP=true
    break
  fi
  sleep 1
done
[[ "${SSH_UP}" == true ]] || die "SSH connection to ${SSH_USER}@${HOST} failed."
ok "SSH connection established."

# ---- Step 2: Check Active Service & Parallel Factor -------------------------
log "Step 2: Inspecting running llama-server process on ${HOST}..."
RUNNING_ARGS="$(ssh "${SSH_USER}@${HOST}" 'ps aux | grep llama-server | grep -v grep' || true)"

if echo "${RUNNING_ARGS}" | grep -q -- '--parallel 2'; then
  ok "Flag --parallel 2 is confirmed active in running llama-server."
else
  warn "Flag --parallel 2 not detected in running process. Deploying profile..."
  "${REPO_DIR}/scripts/deploy-interactive.sh" \
    --host "${HOST}" \
    --user "${SSH_USER}" \
    --profile profiles/gmktec-evo-x2.yml \
    --non-interactive
  ok "Deployment completed."
fi

# Verify slots endpoint has 2 slots
log "Querying /slots endpoint on http://${HOST}:8080/slots..."
SLOT_COUNT="$(python3 -c "
import urllib.request, json
try:
    with urllib.request.urlopen('http://${HOST}:8080/slots', timeout=5) as r:
        slots = json.loads(r.read().decode())
        print(len(slots))
except Exception as e:
    print('0')
")"

if [[ "${SLOT_COUNT}" -ge 2 ]]; then
  ok "Detected ${SLOT_COUNT} active execution slots in llama-server."
else
  die "Expected at least 2 slots, but found: ${SLOT_COUNT}"
fi

# ---- Step 3: Concurrency Micro-Benchmark -----------------------------------
log "Step 3: Measuring performance improvement (Sequential vs. Parallel)..."

BENCH_OUTPUT="$(python3 -c "
import urllib.request, json, time, threading

url = 'http://${HOST}:8080/v1/chat/completions'

def send_req(req_id, results):
    payload = {
        'model': '${MODEL_ID}',
        'messages': [
            {'role': 'system', 'content': 'You are a concise assistant. Answer directly in one sentence without reasoning.'},
            {'role': 'user', 'content': f'Task {req_id}: Count from 1 to 5 with commas.'}
        ],
        'max_tokens': 50,
        'temperature': 0.1
    }
    t0 = time.time()
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read().decode())
        dt = time.time() - t0
        content = data['choices'][0]['message']['content']
        results[req_id] = (dt, content, data.get('usage', {}))

# 1. Sequential
seq_res = {}
t_seq_0 = time.time()
send_req('seq_1', seq_res)
send_req('seq_2', seq_res)
t_seq = time.time() - t_seq_0

time.sleep(0.5)

# 2. Parallel
par_res = {}
t_par_0 = time.time()
th1 = threading.Thread(target=send_req, args=('par_1', par_res))
th2 = threading.Thread(target=send_req, args=('par_2', par_res))
th1.start(); th2.start()
th1.join(); th2.join()
t_par = time.time() - t_par_0

speedup = t_seq / t_par if t_par > 0 else 0
print(f'T_SEQ={t_seq:.2f}')
print(f'T_PAR={t_par:.2f}')
print(f'SPEEDUP={speedup:.2f}')
")"

echo "${BENCH_OUTPUT}"
eval "${BENCH_OUTPUT}"

log "Sequential Wall Time: ${T_SEQ}s"
log "Concurrent Wall Time: ${T_PAR}s"
ok "Measured Concurrency Speedup: ${SPEEDUP}x"

# ---- Step 4: Dual Concurrent OMP Agent Task --------------------------------
log "Step 4: Delegating Rust Ratatui project generation to concurrent OMP agents..."

rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}/src"

# Agent 1 prompt: Cargo.toml and src/main.rs
AGENT1_PROMPT="You are an expert Rust engineer. In the current working directory (${TEST_DIR}), do the following:
1. Write Cargo.toml with:
[package]
name = \"omp-parallel-demo\"
version = \"0.1.0\"
edition = \"2021\"

[dependencies]
ratatui = \"0.29\"
crossterm = \"0.28\"

2. Write src/main.rs:
A complete compiling Ratatui binary that calls app::render_banner() to get the title string 'GMKtec Evo X2 - 2x Parallel Inference Active', renders it in a centered Paragraph within a bordered Block, polls for exit on 'q' or Esc with timeout 50ms, and cleanly restores the terminal on exit. Make stdout mutable and handle terminal cleanup properly.
3. Keep your output concise."

# Agent 2 prompt: src/app.rs modular library
AGENT2_PROMPT="You are an expert Rust engineer. In the current working directory (${TEST_DIR}), do the following:
1. Write src/app.rs containing:
pub fn render_banner() -> &'static str {
    \"GMKtec Evo X2 - 2x Parallel Inference Active\"
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn test_render_banner() {
        assert_eq!(render_banner(), \"GMKtec Evo X2 - 2x Parallel Inference Active\");
    }
}
2. Keep your output concise."

log "Launching OMP Agent 1 (main.rs & Cargo.toml) and OMP Agent 2 (app.rs) concurrently..."
T_AGENT_START=$(date +%s)

(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo --cwd="${TEST_DIR}" \
      --system-prompt "You are a concise Rust coding assistant. Act directly and write files using write tool." \
      --model "${OMP_MODEL}" \
      -p "${AGENT1_PROMPT}" > "${TEST_DIR}/agent1.log" 2>&1
) &
PID_AGENT1=$!

(
  omp --no-skills --no-extensions --no-rules --tools bash,write,read \
      --auto-approve --approval-mode=yolo --cwd="${TEST_DIR}" \
      --system-prompt "You are a concise Rust coding assistant. Act directly and write files using write tool." \
      --model "${OMP_MODEL}" \
      -p "${AGENT2_PROMPT}" > "${TEST_DIR}/agent2.log" 2>&1
) &
PID_AGENT2=$!

log "Agents running in background: Agent 1 (PID $PID_AGENT1), Agent 2 (PID $PID_AGENT2)"

wait "${PID_AGENT1}" || warn "Agent 1 exited with non-zero status"
wait "${PID_AGENT2}" || warn "Agent 2 exited with non-zero status"

T_AGENT_END=$(date +%s)
T_AGENT_ELAPSED=$((T_AGENT_END - T_AGENT_START))
ok "Both OMP agents finished in ${T_AGENT_ELAPSED}s"

# ---- Step 5: Verify Generated Rust Code & Compilation ----------------------
log "Step 5: Verifying generated Rust project compilation..."

[[ -f "${TEST_DIR}/Cargo.toml" ]] || die "Cargo.toml was not generated."
[[ -f "${TEST_DIR}/src/main.rs" ]] || die "src/main.rs was not generated."
[[ -f "${TEST_DIR}/src/app.rs" ]] || die "src/app.rs was not generated."

# Ensure main.rs declares mod app if not already present (inline or via mod app;)
# Handle case where OMP agent defined mod app { ... } inline
if grep -q "^mod app {" "${TEST_DIR}/src/main.rs"; then
  log "Inline 'mod app { ... }' definition found in main.rs; removing duplicate 'mod app;' if any"
  sed -i '/^mod app;$/d' "${TEST_DIR}/src/main.rs"
elif ! grep -q "mod app" "${TEST_DIR}/src/main.rs"; then
  log "Adding 'mod app;' declaration to src/main.rs..."
  sed -i '1s/^/mod app;\n/' "${TEST_DIR}/src/main.rs"
fi

log "Running cargo test in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo test) || die "cargo test failed in generated project."
ok "cargo test passed!"

log "Running cargo build --release in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo build --release) || die "cargo build --release failed."
ok "Rust project built successfully in release mode!"

# ---- Step 6: Post-Task Stability & SSH Telemetry ---------------------------
log "Step 6: Auditing remote server telemetry via SSH..."

HEALTH="$(python3 -c "
import urllib.request, json
try:
    with urllib.request.urlopen('http://${HOST}:8080/health', timeout=5) as r:
        print(json.loads(r.read().decode()).get('status', 'unknown'))
except:
    print('down')
")"

if [[ "${HEALTH}" == "ok" ]]; then
  ok "llama-server /health is OK."
else
  die "llama-server /health failed: ${HEALTH}"
fi

TELEMETRY="$(ssh "${SSH_USER}@${HOST}" '
  echo "--- UPTIME ---"
  uptime
  echo "--- SERVICE STATUS ---"
  systemctl status llama-server --no-pager | head -n 12
  echo "--- MEMORY ---"
  free -h
  echo "--- THERMALS ---"
  sensors 2>/dev/null | grep -E "temp|Tctl|edge" || true
')"
echo "${TELEMETRY}"

echo
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  VERIFICATION PASSED: EVO X2 PARALLEL FACTOR 2 VERIFIED!   ${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "  Host:             ${HOST}"
echo -e "  Sequential Time:  ${T_SEQ}s"
echo -e "  Concurrent Time:  ${T_PAR}s"
echo -e "  Measured Speedup: ${SPEEDUP}x"
echo -e "  Dual Agent Time:  ${T_AGENT_ELAPSED}s"
echo -e "  App Artifact:     ${TEST_DIR}/target/release/omp-parallel-demo"
echo
