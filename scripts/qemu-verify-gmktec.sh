#!/usr/bin/env bash
# ============================================================================
# qemu-verify-gmktec.sh — verify the GMKtec EVO X2 deploy profile in a local
# QEMU VM before powering on the real mini PC.
#
# QEMU has no GPU, so this runs the playbook with the real EVO X2 profile
# (profiles/gmktec-evo-x2.yml) applied as extra vars, adapted for the VM:
# CPU backend, a small model, reduced context. This proves the profile file,
# the Ansible playbook, the systemd service, and the OpenAI-compatible API
# all work end to end. Actual Vulkan/GPU offload can only be confirmed on the
# real hardware.
#
# Usage:
#   ./scripts/qemu-verify-gmktec.sh [fedora|rocky]   (default: rocky)
# ============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISTRO="${1:-rocky}"

exec "${REPO_DIR}/scripts/qemu-verify.sh" "${DISTRO}" profiles/gmktec-evo-x2.yml
