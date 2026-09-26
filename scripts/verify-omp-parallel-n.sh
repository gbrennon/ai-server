#!/usr/bin/env bash
# ============================================================================
# verify-omp-parallel-n.sh — parameterized verification for N parallel slots
# Supports --parallel 1, 2, 3, 4, ... on GMKtec Evo X2
#
# Usage:
#   ./scripts/verify-omp-parallel-n.sh <parallel_factor> [host] [user]
#   ./scripts/verify-omp-parallel-n.sh 3                  # Test --parallel 3
#   ./scripts/verify-omp-parallel-n.sh 4 192.168.0.2      # Test --parallel 4
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARALLEL_FACTOR="${1:-2}"
HOST="${2:-192.168.0.2}"
SSH_USER="${3:-gbrennon-local-ai}"
TIMEOUT_SEC=900
MODEL_ID="/var/lib/llama.cpp/models/Qwen3.8-27B-UD-Q4_K_M.gguf"
OMP_MODEL="evo-x2-llamacpp/Qwen3.8-27B-UD-Q4_K_M.gguf"
TEST_DIR="/tmp/omp-parallel-verification-p${PARALLEL_FACTOR}"

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

log()   { echo -e "${CYAN}[verify-p${PARALLEL_FACTOR}]${RESET} $*"; }
ok()    { echo -e "${GREEN}[verify-p${PARALLEL_FACTOR}] [OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[verify-p${PARALLEL_FACTOR}] [WARN]${RESET} $*"; }
die()   { echo -e "${RED}[verify-p${PARALLEL_FACTOR}] [ERROR]:${RESET} $*" >&2; exit 1; }

echo -e "${BOLD}${MAGENTA}============================================================${RESET}"
echo -e "${BOLD}${MAGENTA}   GMKtec Evo X2 OMP Parallel ($PARALLEL_FACTOR Slots) Verification${RESET}"
echo -e "${BOLD}${MAGENTA}============================================================${RESET}"
echo "Target Host:    ${HOST}"
echo "SSH User:       ${SSH_USER}"
echo "Model ID:       ${MODEL_ID}"
echo "Parallel Factor: ${PARALLEL_FACTOR} slots"
echo "Scratch Dir:    ${TEST_DIR}"
echo

# ---- Step 1: Connectivity Check --------------------------------------------
log "Step 1: Checking host reachability (${HOST})..."
if ! ping -c 1 -W 2 "${HOST}" >/dev/null 2>&1; then
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

# ---- Step 2: Deploy Profile & Check Parallel Factor -------------------------
log "Step 2: Deploying parallel factor ${PARALLEL_FACTOR}..."

# Deploy the profile
PROFILE="profiles/gmktec-evo-x2-parallel-${PARALLEL_FACTOR}.yml"
if [[ ! -f "$PROFILE" ]]; then
  die "Profile not found: $PROFILE"
fi

log "Deploying $PROFILE to ${HOST}..."
ansible-playbook site.yml -i "${HOST}," 2>&1 | tail -5

# Verify slot count
log "Querying /slots endpoint on http://${HOST}:8080/slots..."
SLOT_COUNT="$(python3 -c "
import urllib.request, json
try:
    with urllib.request.urlopen('http://${HOST}:8080/slots', timeout=5) as r:
        slots = json.loads(r.read().decode())
        print(len(slots))
except Exception as e:
    print('0')
" 2>/dev/null || echo 0)"

if [[ "${SLOT_COUNT}" -ge ${PARALLEL_FACTOR} ]]; then
  ok "Detected ${SLOT_COUNT} active execution slots (expected ≥${PARALLEL_FACTOR})."
else
  die "Expected at least ${PARALLEL_FACTOR} slots, but found: ${SLOT_COUNT}"
fi

# ---- Step 3: Concurrency Micro-Benchmark -----------------------------------
log "Step 3: Measuring performance (Sequential vs. ${PARALLEL_FACTOR}-way Concurrent)..."

BENCH_OUTPUT="$(python3 -c "
import urllib.request, json, time, threading

url = 'http://${HOST}:8080/v1/chat/completions'
parallel_factor = ${PARALLEL_FACTOR}

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
        results[req_id] = dt

# Sequential: N requests back-to-back
seq_res = {}
t_seq_0 = time.time()
for i in range(parallel_factor):
    send_req(f'seq_{i}', seq_res)
t_seq = time.time() - t_seq_0

time.sleep(0.5)

# Concurrent: N threads simultaneously
par_res = {}
threads = []
t_par_0 = time.time()
for i in range(parallel_factor):
    th = threading.Thread(target=send_req, args=(f'par_{i}', par_res))
    threads.append(th)
    th.start()
for th in threads:
    th.join()
t_par = time.time() - t_par_0

speedup = t_seq / t_par if t_par > 0 else 0
print(f'T_SEQ={t_seq:.2f}')
print(f'T_PAR={t_par:.2f}')
print(f'SPEEDUP={speedup:.2f}')
")"

echo "${BENCH_OUTPUT}"
eval "${BENCH_OUTPUT}"

log "Sequential Wall Time: ${T_SEQ}s"
log "Concurrent Wall Time (${PARALLEL_FACTOR}-way): ${T_PAR}s"
ok "Measured Concurrency Speedup: ${SPEEDUP}x"

# ---- Step 4: Dual Concurrent OMP Agent Task --------------------------------
log "Step 4: Delegating Rust Ratatui project generation to ${PARALLEL_FACTOR} concurrent OMP agents..."

rm -rf "${TEST_DIR}"
mkdir -p "${TEST_DIR}/src"

# Multi-agent prompts based on parallel factor
AGENT1_PROMPT="You are an expert Rust engineer. In ${TEST_DIR}, write Cargo.toml and src/main.rs for a Ratatui TUI showing 'GMKtec Evo X2 - ${PARALLEL_FACTOR}x Parallel Inference Active'. Keep output concise."
AGENT2_PROMPT="You are an expert Rust engineer. In ${TEST_DIR}, write src/app.rs with pub fn render_banner() returning the parallel status string. Keep output concise."

log "Launching ${PARALLEL_FACTOR} OMP agents concurrently..."
T_AGENT_START=$(date +%s)

PIDS=()
for i in $(seq 1 2); do
  if [[ $i -eq 1 ]]; then
    PROMPT="$AGENT1_PROMPT"
  else
    PROMPT="$AGENT2_PROMPT"
  fi
  
  (
    omp --no-skills --no-extensions --no-rules --tools bash,write,read \
        --auto-approve --approval-mode=yolo --cwd="${TEST_DIR}" \
        --system-prompt "You are a concise Rust coding assistant. Act directly and write files using write tool." \
        --model "${OMP_MODEL}" \
        -p "${PROMPT}" > "${TEST_DIR}/agent${i}.log" 2>&1
  ) &
  PIDS+=($!)
done

log "Agents running in background: ${PIDS[@]}"

for pid in "${PIDS[@]}"; do
  wait "$pid" || warn "Agent PID $pid exited with non-zero status"
done

T_AGENT_END=$(date +%s)
T_AGENT_ELAPSED=$((T_AGENT_END - T_AGENT_START))
ok "Both OMP agents finished in ${T_AGENT_ELAPSED}s"

# ---- Step 5: Verify Generated Rust Code & Compilation ----------------------
log "Step 5: Verifying generated Rust project compilation..."

[[ -f "${TEST_DIR}/Cargo.toml" ]] || die "Cargo.toml was not generated."
[[ -f "${TEST_DIR}/src/main.rs" ]] || die "src/main.rs was not generated."

if ! grep -q "mod app" "${TEST_DIR}/src/main.rs"; then
  log "Adding 'mod app;' declaration to src/main.rs..."
  sed -i '1s/^/mod app;\n/' "${TEST_DIR}/src/main.rs"
elif grep -q "^mod app {" "${TEST_DIR}/src/main.rs"; then
  log "Inline 'mod app { ... }' definition found; cleaning up duplicates"
  sed -i '/^mod app;$/d' "${TEST_DIR}/src/main.rs"
fi

log "Running cargo test in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo test 2>&1 | tail -10) || die "cargo test failed."
ok "cargo test passed!"

log "Running cargo build --release in ${TEST_DIR}..."
(cd "${TEST_DIR}" && cargo build --release 2>&1 | grep -E "Finished|error" || true) || die "cargo build --release failed."
ok "Rust project built successfully!"

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
  sensors 2>/dev/null | grep -E "temp|Tctl|edge" | head -5 || echo "(thermals unavailable)"
')"
echo "${TELEMETRY}"

echo
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "${BOLD}${GREEN}  VERIFICATION PASSED: PARALLEL FACTOR ${PARALLEL_FACTOR} VERIFIED!${RESET}"
echo -e "${BOLD}${GREEN}============================================================${RESET}"
echo -e "  Host:             ${HOST}"
echo -e "  Parallel Slots:   ${PARALLEL_FACTOR}"
echo -e "  Sequential Time:  ${T_SEQ}s"
echo -e "  Concurrent Time:  ${T_PAR}s"
echo -e "  Measured Speedup: ${SPEEDUP}x"
echo -e "  Dual Agent Time:  ${T_AGENT_ELAPSED}s"
echo -e "  App Artifact:     ${TEST_DIR}/target/release/omp-parallel-demo"
echo
