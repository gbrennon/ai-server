#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — one-command setup of llama.cpp on Fedora Server / Rocky Linux
#
# Usage:
#   sudo ./bootstrap.sh              # run on this machine (localhost)
#   sudo ./bootstrap.sh myserver     # run against a remote host in inventory
#
# What it does:
#   1. Installs Ansible + collections (dnf + galaxy)
#   2. Runs the playbook: packages, firewall, user, builds llama.cpp,
#      downloads the model, installs & starts the systemd service.
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-localhost}"

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
dnf install -y ansible || {
  echo "Falling back to pip..."
  dnf install -y python3-pip
  python3 -m pip install --upgrade ansible
}

echo "==> [2/3] Installing required Ansible collections"
ansible-galaxy collection install -r "${REPO_DIR}/requirements.yml" --force

echo "==> [3/3] Running playbook against: ${TARGET}"
cd "${REPO_DIR}"

if [[ "${TARGET}" == "localhost" ]]; then
  ansible-playbook site.yml --connection=local
else
  # Remote host: assumes root SSH access or sudo-capable user
  ansible-playbook site.yml --limit "${TARGET}" --ask-become-pass
fi

echo
echo "Done! llama-server should be listening. Quick test:"
echo "  curl http://localhost:8080/health"
echo "  curl http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \\\n       -d '{\"model\":\"llama\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}'"
