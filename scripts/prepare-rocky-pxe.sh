#!/usr/bin/env bash
# Prepare a temporary Rocky Linux PXE installer on the local LAN.
set -euo pipefail

readonly ROCKY_VERSION="10.2"
readonly ROCKY_ISO_NAME="Rocky-10.2-x86_64-boot.iso"
readonly ROCKY_ISO_URL="https://download.rockylinux.org/pub/rocky/10/isos/x86_64/${ROCKY_ISO_NAME}"
readonly ROCKY_CHECKSUM_URL="https://download.rockylinux.org/pub/rocky/10/isos/x86_64/CHECKSUM"
readonly ROCKY_REPO_URL="https://dl.rockylinux.org/pub/rocky/10/BaseOS/x86_64/os/"

INTERFACE=""
SERVER_IP=""
DHCP_RANGE=""
WORK_DIR="${HOME}/.local/share/rocky-pxe/${ROCKY_VERSION}"
HTTP_PORT=8088
SOURCE_DIR=""
DRY_RUN=0
HTTP_PID=""
DNSMASQ_PID=""

log() { printf '[rocky-pxe] %s\n' "$*"; }
die() { printf '[rocky-pxe] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Prepare a temporary Rocky Linux ${ROCKY_VERSION} PXE network installer.

Usage: sudo $0 --interface IFACE [options]

Options:
  --interface IFACE       LAN interface serving PXE (required for real runs)
  --server-ip ADDRESS     Workstation IPv4 address on IFACE (auto-detected)
  --dhcp-range START,END  Enable dnsmasq DHCP instead of safer proxy-DHCP mode
  --work-dir DIR          Working directory (default: ${WORK_DIR})
  --http-port PORT        HTTP port (default: ${HTTP_PORT})
  --source-dir DIR        Existing extracted Rocky installer tree (testing/offline)
  --dry-run               Prepare files without starting HTTP or dnsmasq
  -h, --help              Show this help

The target must be on the same wired LAN. Do not run DHCP mode on a network
that already has another DHCP server; proxy-DHCP mode is the default.
The Rocky ${ROCKY_VERSION} Boot ISO is downloaded from:
  ${ROCKY_ISO_URL}
EOF
}

cleanup() {
  local status=$?
  [[ -n "${DNSMASQ_PID}" ]] && kill "${DNSMASQ_PID}" 2>/dev/null || true
  [[ -n "${HTTP_PID}" ]] && kill "${HTTP_PID}" 2>/dev/null || true
  if (( status != 0 )); then
    log "logs and generated files remain in ${WORK_DIR}"
  fi
  exit "${status}"
}
trap cleanup EXIT INT TERM

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( 1 <= 10#$1 && 10#$1 <= 65535 )); }
valid_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; local octet; IFS=. read -ra octets <<< "$1"; for octet in "${octets[@]}"; do (( octet <= 255 )) || return 1; done; }

while (($#)); do
  case "$1" in
    --interface) [[ $# -ge 2 ]] || die '--interface needs a value'; INTERFACE=$2; shift 2 ;;
    --server-ip) [[ $# -ge 2 ]] || die '--server-ip needs a value'; SERVER_IP=$2; shift 2 ;;
    --dhcp-range) [[ $# -ge 2 ]] || die '--dhcp-range needs a value'; DHCP_RANGE=$2; shift 2 ;;
    --work-dir) [[ $# -ge 2 ]] || die '--work-dir needs a value'; WORK_DIR=$2; shift 2 ;;
    --http-port) [[ $# -ge 2 ]] || die '--http-port needs a value'; HTTP_PORT=$2; shift 2 ;;
    --source-dir) [[ $# -ge 2 ]] || die '--source-dir needs a value'; SOURCE_DIR=$2; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

if [[ -z "${INTERFACE}" ]]; then
  (( DRY_RUN )) || die '--interface is required'
  INTERFACE=test0
fi
[[ "${INTERFACE}" != lo && "${INTERFACE}" != lo:* ]] || die 'refusing loopback interface'
if (( ! DRY_RUN )); then
  [[ -d "/sys/class/net/${INTERFACE}" ]] || die "interface not found: ${INTERFACE}"
  (( EUID == 0 )) || die 'real runs must be started with sudo'
fi
valid_port "${HTTP_PORT}" || die "invalid HTTP port: ${HTTP_PORT}"
if [[ -n "${DHCP_RANGE}" && ! "${DHCP_RANGE}" =~ ^[^,]+,[^,]+$ ]]; then die 'DHCP range must be START,END'; fi
if [[ -n "${SERVER_IP}" ]]; then valid_ipv4 "${SERVER_IP}" || die "invalid server IPv4 address: ${SERVER_IP}"; fi

if [[ -z "${SERVER_IP}" ]] && (( ! DRY_RUN )); then
  SERVER_IP="$(ip -4 -o addr show dev "${INTERFACE}" scope global | awk 'NR == 1 { sub(/\/.*/, "", $4); print $4 }')"
fi
SERVER_IP="${SERVER_IP:-192.168.50.1}"

if [[ -z "${SOURCE_DIR}" ]]; then
  command -v curl >/dev/null || die 'curl is required'
  ISO="${WORK_DIR}/${ROCKY_ISO_NAME}"
  mkdir -p "${WORK_DIR}"
  if [[ ! -s "${ISO}" ]]; then log "downloading ${ROCKY_ISO_NAME}"; curl -fL --retry 3 -o "${ISO}.part" "${ROCKY_ISO_URL}"; mv "${ISO}.part" "${ISO}"; fi
  CHECKSUM_FILE="${WORK_DIR}/CHECKSUM"
  curl -fL --retry 3 -o "${CHECKSUM_FILE}" "${ROCKY_CHECKSUM_URL}"
  EXPECTED="$(awk -v name="${ROCKY_ISO_NAME}" 'index($0, "SHA256 (" name ") =") == 1 {print $NF; exit}' "${CHECKSUM_FILE}")"
  [[ "${EXPECTED}" =~ ^[[:xdigit:]]{64}$ ]] || die "checksum for ${ROCKY_ISO_NAME} not found in CHECKSUM"
  ACTUAL="$(sha256sum "${ISO}" | awk '{print $1}')"
  [[ "${ACTUAL}" == "${EXPECTED}" ]] || die "ISO checksum mismatch"
  SOURCE_DIR="${WORK_DIR}/iso-tree"
  rm -rf "${SOURCE_DIR}"; mkdir -p "${SOURCE_DIR}"
  if command -v bsdtar >/dev/null; then
    bsdtar -xf "${ISO}" -C "${SOURCE_DIR}"
  elif command -v 7z >/dev/null; then
    7z x -y "${ISO}" "-o${SOURCE_DIR}" >/dev/null
  elif command -v mount >/dev/null && command -v umount >/dev/null; then
    MOUNT_DIR="$(mktemp -d "${WORK_DIR}/iso-mount.XXXXXX")"
    mount -o loop,ro "${ISO}" "${MOUNT_DIR}"
    cp -a "${MOUNT_DIR}/." "${SOURCE_DIR}/"
    umount "${MOUNT_DIR}"
    rmdir "${MOUNT_DIR}"
  else
    die 'bsdtar, 7z, or mount/umount is required to read the Boot ISO'
  fi
fi

[[ -d "${SOURCE_DIR}" ]] || die "source directory not found: ${SOURCE_DIR}"
[[ -f "${SOURCE_DIR}/images/pxeboot/vmlinuz" ]] || die 'source has no images/pxeboot/vmlinuz'
[[ -f "${SOURCE_DIR}/images/pxeboot/initrd.img" ]] || die 'source has no images/pxeboot/initrd.img'
mkdir -p "${WORK_DIR}/http/images/pxeboot" "${WORK_DIR}/pxelinux.cfg" "${WORK_DIR}/logs"
cp "${SOURCE_DIR}/images/pxeboot/vmlinuz" "${WORK_DIR}/http/images/pxeboot/vmlinuz"
cp "${SOURCE_DIR}/images/pxeboot/initrd.img" "${WORK_DIR}/http/images/pxeboot/initrd.img"
if [[ -f "${SOURCE_DIR}/EFI/BOOT/BOOTX64.EFI" ]]; then
  mkdir -p "${WORK_DIR}/http/EFI/BOOT"
  cp "${SOURCE_DIR}/EFI/BOOT/BOOTX64.EFI" "${WORK_DIR}/http/EFI/BOOT/BOOTX64.EFI"
fi

cat > "${WORK_DIR}/http/boot.ipxe" <<EOF
#!ipxe
kernel http://${SERVER_IP}:${HTTP_PORT}/images/pxeboot/vmlinuz initrd=initrd.img inst.repo=${ROCKY_REPO_URL} ip=dhcp
initrd http://${SERVER_IP}:${HTTP_PORT}/images/pxeboot/initrd.img
boot
EOF
cat > "${WORK_DIR}/dnsmasq.conf" <<EOF
port=0
interface=${INTERFACE}
bind-interfaces
listen-address=${SERVER_IP}
enable-tftp
tftp-root=${WORK_DIR}/tftp
dhcp-no-override
log-dhcp
log-facility=${WORK_DIR}/logs/dnsmasq.log
EOF
mkdir -p "${WORK_DIR}/tftp"

if [[ -n "${DHCP_RANGE}" ]]; then
  GATEWAY="$(ip route show default dev "${INTERFACE}" | awk 'NR == 1 {print $3}')"
  [[ -n "${GATEWAY}" ]] || die "no default gateway found on ${INTERFACE}; use proxy-DHCP mode"
  printf 'dhcp-range=%s\ndhcp-option=3,%s\ndhcp-option=6,%s\n' "${DHCP_RANGE}" "${GATEWAY}" "${GATEWAY}" >> "${WORK_DIR}/dnsmasq.conf"
else
  printf 'dhcp-range=%s,proxy\n' "${SERVER_IP}" >> "${WORK_DIR}/dnsmasq.conf"
fi
cat >> "${WORK_DIR}/dnsmasq.conf" <<EOF
dhcp-userclass=set:ipxe,iPXE
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:ipxe,http://${SERVER_IP}:${HTTP_PORT}/boot.ipxe
dhcp-boot=tag:efi64,ipxe.efi
dhcp-boot=tag:!efi64,undionly.kpxe
EOF

if (( DRY_RUN )); then log "dry run complete: ${WORK_DIR}"; exit 0; fi
for command in python3 dnsmasq curl; do command -v "${command}" >/dev/null || die "${command} is required"; done
curl -fL --retry 3 -o "${WORK_DIR}/tftp/ipxe.efi" https://boot.ipxe.org/x86_64-efi/ipxe.efi
curl -fL --retry 3 -o "${WORK_DIR}/tftp/undionly.kpxe" https://boot.ipxe.org/undionly.kpxe
python3 -m http.server "${HTTP_PORT}" --bind "${SERVER_IP}" --directory "${WORK_DIR}/http" >"${WORK_DIR}/logs/http.log" 2>&1 & HTTP_PID=$!
dnsmasq --no-daemon --conf-file="${WORK_DIR}/dnsmasq.conf" >"${WORK_DIR}/logs/dnsmasq.stdout" 2>&1 & DNSMASQ_PID=$!
sleep 1
kill -0 "${HTTP_PID}" 2>/dev/null || die 'HTTP server failed; see logs/http.log'
kill -0 "${DNSMASQ_PID}" 2>/dev/null || die 'dnsmasq failed; see logs/dnsmasq.stdout'
log 'PXE services running; power on the EVO X2 and select IPv4 Network/PXE Boot'
log "HTTP root: ${WORK_DIR}/http"
log 'Press Ctrl-C after Rocky installation starts to stop the temporary services.'
wait "${HTTP_PID}"
