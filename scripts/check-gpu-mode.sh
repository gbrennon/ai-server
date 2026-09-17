#!/usr/bin/env bash
# ============================================================================
# check-gpu-mode.sh — report the AMD iGPU DPM performance mode and whether it
# persists across reboots (via the gpu-performance.service systemd unit).
#
# Answers: "after I shut down, do I have to re-enable performance mode?"
#   - If gpu-performance.service is ENABLED, the answer is NO: systemd
#     re-applies the level on every boot.
#   - If it is not installed/enabled, the GPU falls back to the kernel
#     default ('auto') on reboot.
#
# Usage:
#   ./scripts/check-gpu-mode.sh                 # inspect THIS machine
#   ./scripts/check-gpu-mode.sh <host> [user]   # inspect a remote host via SSH
#   ./scripts/check-gpu-mode.sh 192.168.0.2 gbrennon-local-ai
# ============================================================================
set -euo pipefail

HOST="${1:-}"
SSH_USER="${2:-$(id -un)}"

# Inspection logic runs either locally or on the remote host (no sudo needed:
# the sysfs level file and systemctl state are world-readable).
read -r -d '' INSPECT <<'SCRIPT' || true
set -u

echo "== AMD iGPU DPM performance mode (current) =="
found=0
for d in /sys/class/drm/card*/device; do
  [ -e "$d/uevent" ] || continue
  grep -q '^DRIVER=amdgpu$' "$d/uevent" || continue
  found=1
  card=$(basename "$(dirname "$d")")
  lvl_file="$d/power_dpm_force_performance_level"
  if [ -r "$lvl_file" ]; then
    lvl=$(cat "$lvl_file" 2>/dev/null)
  else
    lvl="(unreadable — try: sudo cat $lvl_file)"
  fi
  echo "  $card: power_dpm_force_performance_level = $lvl"
  if [ -r "$d/pp_dpm_sclk" ]; then
    cur=$(grep '\*' "$d/pp_dpm_sclk" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]\+/ /g')
    echo "        active sclk state:               ${cur:-n/a}"
  fi
done
[ "$found" = 1 ] || echo "  no amdgpu card found on this host"

echo
echo "  legend: high = pinned top clock | auto = firmware-managed (default)"
echo "          low = min clock | manual/profile_* = manual control"

echo
echo "== Persistence across reboots (gpu-performance.service) =="
if systemctl cat gpu-performance.service >/dev/null 2>&1; then
  pinned=$(systemctl cat gpu-performance.service 2>/dev/null \
           | grep -oE 'echo [a-z_]+ > "\$f"' | head -1 | awk '{print $2}')
  en=$(systemctl is-enabled gpu-performance.service 2>/dev/null || true)
  ac=$(systemctl is-active  gpu-performance.service 2>/dev/null || true)
  echo "  unit pins level to:     ${pinned:-unknown}"
  echo "  enabled (runs at boot): $en"
  echo "  active now:             $ac"
  echo
  if [ "$en" = "enabled" ]; then
    echo "  => NO re-enable needed. The level is re-applied automatically on"
    echo "     every boot. Shut down / reboot freely."
  else
    echo "  => The unit is installed but NOT enabled. On reboot the level resets"
    echo "     to the kernel default ('auto'). Enable it to persist:"
    echo "       sudo systemctl enable --now gpu-performance"
  fi
else
  echo "  gpu-performance.service is NOT installed."
  echo "  => Nothing pins the GPU; it uses the kernel default ('auto') and"
  echo "     resets every boot. Deploy with gpu_performance_mode: true to pin it."
fi
SCRIPT

if [[ -z "$HOST" || "$HOST" == "local" || "$HOST" == "localhost" ]]; then
  echo "[check-gpu-mode] inspecting local machine"
  bash -c "$INSPECT"
else
  echo "[check-gpu-mode] inspecting ${SSH_USER}@${HOST} over SSH"
  ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${HOST}" "bash -s" <<<"$INSPECT"
fi
