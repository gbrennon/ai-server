#!/usr/bin/env bash
# Benchmark one already-downloaded GGUF without changing the canonical profile.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REMOTE_MODEL_DIR="/var/lib/llama.cpp/models"
readonly REMOTE_BINARY="/opt/llama.cpp/build-hip/bin/llama-server"
readonly REMOTE_RUNTIME_PATH="/opt/rocm/lib:/opt/rocm/lib64:/opt/rocm/core-7.14/lib"
readonly REMOTE_LOG_FILE="/tmp/benchmark-model.log"
readonly HELPER="${REPO_DIR}/scripts/benchmark-model.py"

TARGET_HOST="${GMKTEC_HOST:-192.168.0.2}"
TARGET_USER="${GMKTEC_USER:-$(id -un)}"
MODEL_NAME=""
TARGET=""
SERVICE_STATE=""
CANDIDATE_PID=""
CANDIDATE_STARTED=false
CLEANED_UP=false

log() { printf '[benchmark-model] %s\n' "$*"; }
die() { printf '[benchmark-model] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: benchmark-deploy-model.sh MODEL.gguf [HOST] [SSH_USER]

Environment overrides:
  GMKTEC_HOST  target host (default: 192.168.0.2)
  GMKTEC_USER  SSH user (default: current user)

The model must already exist as a regular .gguf file in the target's
/var/lib/llama.cpp/models directory. The production service is restored when
the benchmark exits, including on interruption.
EOF
}

parse_args() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") usage >&2; exit 2 ;;
    *) MODEL_NAME="$1" ;;
  esac
  [[ "${2:-}" == "" || "$#" -le 3 ]] || die "too many arguments"
  [[ "${2:-}" == "" ]] || TARGET_HOST="$2"
  [[ "${3:-}" == "" ]] || TARGET_USER="$3"
  TARGET="${TARGET_USER}@${TARGET_HOST}"
}

require_dependencies() {
  command -v ssh >/dev/null || die "ssh is required"
  [[ -f "${HELPER}" ]] || die "missing benchmark helper: ${HELPER}"
  [[ "${MODEL_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.gguf$ ]] || \
    die "model must be a simple .gguf basename"
}

remote() { ssh -o BatchMode=yes -o ConnectTimeout=10 "${TARGET}" "$@"; }

validate_remote_model() {
  local remote_model="${REMOTE_MODEL_DIR}/${MODEL_NAME}"
  remote "test -f '${remote_model}' && test ! -L '${remote_model}'" || \
    die "remote model is not a regular file: ${remote_model}"
}

wait_for_stable_service() {
  for _ in $(seq 1 30); do
    SERVICE_STATE="$(remote 'systemctl is-active llama-server.service || true')"
    case "${SERVICE_STATE}" in
      active|inactive|failed|unknown) return ;;
      *) sleep 2 ;;
    esac
  done
  die "service did not reach a stable state: ${SERVICE_STATE}"
}

capture_service_state() {
  wait_for_stable_service
  [[ "${SERVICE_STATE}" == active || "${SERVICE_STATE}" == inactive || \
    "${SERVICE_STATE}" == failed || "${SERVICE_STATE}" == unknown ]] || \
    die "unexpected service state: ${SERVICE_STATE}"
}

stop_production_service() {
  log "stopping production service (${SERVICE_STATE})"
  remote 'sudo -n systemctl stop llama-server.service'
  remote '! pgrep -x llama-server >/dev/null'
}

start_candidate() {
  local model_path="${REMOTE_MODEL_DIR}/${MODEL_NAME}"
  local process_match="${model_path} --host 127.0.0.1 --port 8080"
  log "starting temporary candidate: ${MODEL_NAME}"
  CANDIDATE_STARTED=true
  remote "sudo -n rm -f '${REMOTE_LOG_FILE}'; sudo -n -u llamacpp nohup env LD_LIBRARY_PATH=${REMOTE_RUNTIME_PATH} ${REMOTE_BINARY} --model ${model_path} --host 127.0.0.1 --port 8080 --ctx-size 32768 --threads 16 -ngl 999 --device ROCm0 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 --split-mode layer --parallel 1 --reasoning off --temp 0.2 --repeat-penalty 1.1 --repeat-last-n 512 --frequency-penalty 0.1 --n-predict 256 </dev/null >${REMOTE_LOG_FILE} 2>&1 &"
  CANDIDATE_PID="$(remote "for i in \$(seq 1 30); do candidate_pid=\$(pgrep -u llamacpp -f -- '${process_match}' | head -n 1); test -n \"\$candidate_pid\" && printf '%s\\n' \"\$candidate_pid\" && exit 0; sleep 1; done; cat '${REMOTE_LOG_FILE}' >&2; exit 1")"
  wait_for_health
}

wait_for_health() {
  for _ in $(seq 1 60); do
    if remote 'curl --fail --silent --max-time 5 http://127.0.0.1:8080/health' >/dev/null; then
      log "candidate health: ok"
      return
    fi
    sleep 2
  done
  remote "cat '${REMOTE_LOG_FILE}'" >&2 || true
  die "candidate did not become healthy"
}

run_measurement() {
  log "running three short and three long fresh requests"
  scp -q "${HELPER}" "${TARGET}:/tmp/benchmark-model.py"
  remote "python3 /tmp/benchmark-model.py --model '${REMOTE_MODEL_DIR}/${MODEL_NAME}'"
}

terminate_candidate_pid() {
  local pid="$1"
  local model_path="${REMOTE_MODEL_DIR}/${MODEL_NAME}"
  remote "if test -r /proc/${pid}/cmdline && tr '\\0' ' ' < /proc/${pid}/cmdline | grep -F -- '${model_path}' >/dev/null; then sudo -n kill -TERM '${pid}' 2>/dev/null || true; for i in \$(seq 1 15); do ! kill -0 '${pid}' 2>/dev/null && exit 0; sleep 1; done; sudo -n kill -KILL '${pid}' 2>/dev/null || true; fi" || true
}

stop_candidate() {
  local pid=""
  local model_path="${REMOTE_MODEL_DIR}/${MODEL_NAME}"
  [[ "${CANDIDATE_STARTED}" == true ]] || return 0
  pid="${CANDIDATE_PID:-$(remote "pgrep -u llamacpp -f -- '${model_path} --host 127.0.0.1 --port 8080' | head -n 1")}" 
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    terminate_candidate_pid "${pid}"
  fi
  CANDIDATE_PID=""
  CANDIDATE_STARTED=false
}

restore_service() {
  case "${SERVICE_STATE}" in
    active)
      log "restoring production service"
      remote 'sudo -n systemctl start llama-server.service'
      for _ in $(seq 1 60); do
        if remote 'curl --fail --silent --max-time 5 http://127.0.0.1:8080/health' >/dev/null; then
          log "production health: ok"
          return
        fi
        sleep 2
      done
      die "production service did not recover"
      ;;
    inactive|failed|unknown)
      remote 'sudo -n systemctl stop llama-server.service' || true
      log "production service left ${SERVICE_STATE} as found"
      ;;
  esac
}

cleanup() {
  local status=$?
  [[ "${CLEANED_UP}" == true ]] && exit "${status}"
  CLEANED_UP=true
  trap - EXIT INT TERM
  stop_candidate
  restore_service || status=1
  exit "${status}"
}

main() {
  parse_args "$@"
  require_dependencies
  validate_remote_model
  capture_service_state
  trap cleanup EXIT INT TERM
  stop_production_service
  start_candidate
  run_measurement
}

main "$@"
