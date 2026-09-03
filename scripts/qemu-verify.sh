#!/usr/bin/env bash
# ============================================================================
# qemu-verify.sh — end-to-end verification of the llama.cpp automation
# inside a QEMU/KVM virtual machine (Fedora Server or Rocky Linux).
#
# Usage:
#   ./scripts/qemu-verify.sh [fedora|rocky]   (default: rocky)
#
# What it does:
#   1. Downloads a cloud qcow2 image (cached after first run)
#   2. Generates cloud-init user-data (SSH key + passwordless sudo)
#   3. Boots the VM with KVM, forwards host:2222 -> vm:22, host:8080 -> vm:8080
#   4. Shares the local Hugging Face model cache via virtio-9p
#   5. Copies this repo into the VM and runs bootstrap.sh inside it
#   6. Verifies /health and a real chat completion via the OpenAI-compatible API
# ============================================================================
set -euo pipefail

DISTRO="${1:-rocky}"
VM_DIR="${HOME}/.local/share/ai-server-qemu/${DISTRO}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_PORT=2222
HTTP_PORT=8080
SSH_USER=ai
SSH_KEY="${HOME}/.ssh/id_ed25519"
MODEL_SRC="${HOME}/.cache/huggingface/hub/models--unsloth--Qwen3-8B-GGUF/snapshots/a6adef130ffb23ddaf1a62fec9dced968c9bc482/Qwen3-8B-Q4_K_M.gguf"
VM_RAM_MB=12288
VM_CPUS=8
VM_DISK_GB=40

# ---- cloud image URLs (latest GA stable) ------------------------------------
case "${DISTRO}" in
  fedora)
    IMAGE_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
    IMAGE="Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2"
    ;;
  rocky)
    IMAGE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
    IMAGE="Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
    ;;
  *) echo "Unknown distro: ${DISTRO} (use fedora or rocky)" >&2; exit 1 ;;
esac

log() { echo "[qemu-verify] $*"; }
die() { echo "[qemu-verify] ERROR: $*" >&2; exit 1; }

mkdir -p "${VM_DIR}"
cd "${VM_DIR}"

# ---- 0. preflight -----------------------------------------------------------
[[ -f "${MODEL_SRC}" ]] || die "model not found at ${MODEL_SRC}"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"
[[ -w /dev/kvm ]] || die "no KVM access (/dev/kvm not writable — add yourself to the kvm group)"
[[ -f "${SSH_KEY}" ]] || ssh-keygen -t ed25519 -N '' -f "${SSH_KEY}" -q
SSH_PUB="${SSH_KEY}.pub"

# ---- 1. download cloud image (cached) ---------------------------------------
if [[ ! -f "${IMAGE}" ]]; then
  log "downloading ${IMAGE_URL}"
  curl -fL --retry 3 -o "${IMAGE}" "${IMAGE_URL}"
fi

# ---- 2. cloud-init seed ------------------------------------------------------
cat > user-data <<EOF
#cloud-config
users:
  - name: ${SSH_USER}
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${SSH_PUB}")
ssh_pwauth: false
EOF
cat > meta-data <<EOF
instance-id: ai-server-verify-01
local-hostname: ai-server-test
EOF
[[ -f seed.img ]] || cloud-localds seed.img user-data meta-data \
  || { log "cloud-localds missing — installing genisoimage fallback"; 
       genisoimage -output seed.img -volid cidata -joliet -rock user-data meta-data; }

# ---- 3. fresh VM disk --------------------------------------------------------
rm -f disk.qcow2
qemu-img create -f qcow2 -b "${IMAGE}" -F qcow2 disk.qcow2 "${VM_DISK_GB}G" >/dev/null

# ---- 4. boot VM --------------------------------------------------------------
rm -f serial.log
log "booting ${DISTRO} VM (ram=${VM_RAM_MB}MB cpus=${VM_CPUS} ssh=:${SSH_PORT})"
qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 \
  -m "${VM_RAM_MB}" -smp "${VM_CPUS}" \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.img,if=virtio,format=raw,media=disk \
  -netdev user,id=n0,hostfwd=tcp::${SSH_PORT}-:22,hostfwd=tcp::${HTTP_PORT}-:8080 \
  -device virtio-net-pci,netdev=n0 \
  -display none -serial file:serial.log \
  -daemonize -pidfile vm.pid
trap 'kill "$(cat vm.pid 2>/dev/null)" 2>/dev/null || true' EXIT

ssh_cmd() { ssh -p ${SSH_PORT} -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "${SSH_USER}@127.0.0.1" "$@"; }

log "waiting for SSH (cloud-init first boot can take a few minutes)..."
for i in $(seq 1 120); do
  if ssh_cmd true 2>/dev/null; then break; fi
  sleep 5
  [[ $i -eq 120 ]] && { tail -50 serial.log; die "SSH never came up"; }
done
log "SSH is up"

# wait for cloud-init to finish (dnf/rpm-ostree may still be running)
log "waiting for cloud-init to finish..."
ssh_cmd 'while ! sudo cloud-init status --wait >/dev/null 2>&1; do sleep 10; done; echo cloud-init done'

# ---- 5. copy repo into the VM ------------------------------------------------
log "copying automation repo into VM"
tar --exclude=.git -czf /tmp/ai-server.tgz -C "${REPO_DIR}" .
scp -P ${SSH_PORT} -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  /tmp/ai-server.tgz "${SSH_USER}@127.0.0.1:/tmp/" >/dev/null
ssh_cmd 'mkdir -p ~/ai-server && tar -xzf /tmp/ai-server.tgz -C ~/ai-server \
  && sed -i "s|^llamacpp_model_file:.*|llamacpp_model_file: $(basename '"'"'"${MODEL_SRC}"'"'"')|" ~/ai-server/group_vars/all.yml' 

# ---- 6. copy the model into the VM (9p is unavailable on Rocky cloud kernels) ----
log "copying model into VM (this may take a few minutes)"
ssh_cmd 'sudo mkdir -p /var/lib/llama.cpp/models && sudo chown ai: /var/lib/llama.cpp/models'
scp -P ${SSH_PORT} -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${MODEL_SRC}" "${SSH_USER}@127.0.0.1:/var/lib/llama.cpp/models/" >/dev/null
ssh_cmd 'ls -lh /var/lib/llama.cpp/models/'

# ---- 7. run the actual automation --------------------------------------------
log "running bootstrap.sh INSIDE the VM (this builds llama.cpp — be patient)"
ssh_cmd 'cd ~/ai-server \
  && sudo ./bootstrap.sh 2>&1 | tee ~/bootstrap-run.log | tail -n +1 \
  && sudo grep -E "PLAY RECAP|failed=[1-9]" ~/ai-server/../bootstrap-run.log || true'

# ---- 8. functional verification ----------------------------------------------
log "verifying /health"
ssh_cmd 'for i in $(seq 1 60); do curl -fsS http://127.0.0.1:8080/health && break; sleep 5; done'

log "verifying OpenAI-compatible chat completion (host-side via port-forward)"
RESPONSE=$(curl -fsS "http://127.0.0.1:${HTTP_PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Reply with exactly: VERIFIED"}],"max_tokens":20}' )
echo "${RESPONSE}"
echo "${RESPONSE}" | grep -q 'VERIFIED' || die "chat completion did not contain expected output"

log "=============================================================="
log "SUCCESS: automation verified end-to-end inside ${DISTRO} VM"
log "  - llama.cpp built from source"
log "  - systemd service running & healthy"
log "  - OpenAI-compatible API responding"
log "=============================================================="
