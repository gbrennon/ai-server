#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — one-command setup of llama.cpp on Fedora Server / Rocky Linux
#
# Usage:
#   sudo ./bootstrap.sh                        # run on this machine (localhost)
#   sudo ./bootstrap.sh myserver               # run against a remote host in inventory
#   sudo ./bootstrap.sh localhost '@profiles/gmktec-evo-x2.yml' 'key=value' ...
#                                              # optional extra vars forwarded to
#                                              # ansible-playbook (e.g. a profile)
#
# What it does:
#   1. Installs Ansible + collections (dnf + galaxy)
#   2. Runs the playbook: packages, firewall, user, builds llama.cpp,
#      downloads the model, installs & starts the systemd service.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-localhost}"
shift 2>/dev/null || true
EXTRA_ARGS=("$@")

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root (e.g. 'sudo ./bootstrap.sh $TARGET')." >&2
  exit 1
fi

# Detect dnf-based distro
if ! command -v dnf >/dev/null 2>&1; then
  echo "ERROR: 'dnf' not found — this automation targets Fedora Server / Rocky Linux." >&2
  exit 1
fi

echo "==> [1/3] Installing Ansible (dnf)"
if ! dnf install -y ansible; then
  echo "Falling back to pip..."
  dnf install -y python3-pip || true
  python3 -m pip install --upgrade ansible || true
fi

# make sure ansible tools are on PATH regardless of install method
export PATH=/usr/local/bin:$PATH

echo "==> [2/3] Installing required Ansible collections"
ansible-galaxy collection install -r "${REPO_DIR}/requirements.yml" --force

echo "==> [3/3] Running playbook against: ${TARGET}"
cd "${REPO_DIR}"

# Each extra arg (a `key=value` or `@file`) becomes its own -e flag so Ansible
# parses extra vars correctly rather than rejecting them as positional args.
EXTRA_VAR_FLAGS=()
for arg in "${EXTRA_ARGS[@]}"; do
  EXTRA_VAR_FLAGS+=(-e "${arg}")
done

if [[ "${TARGET}" == "localhost" ]]; then
  ansible-playbook site.yml --connection=local "${EXTRA_VAR_FLAGS[@]}"
else
  # Remote host: assumes root SSH access or sudo-capable user
  ansible-playbook site.yml --limit "${TARGET}" --ask-become-pass "${EXTRA_VAR_FLAGS[@]}"
fi

echo
echo "Done! llama-server should be listening. Quick test:"
echo "  curl http://localhost:8080/health"
echo "  curl http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \\\n       -d '{\"model\":\"llama\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
