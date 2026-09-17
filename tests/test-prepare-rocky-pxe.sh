#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/prepare-rocky-pxe.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

help="$(${SCRIPT} --help)"
grep -q 'Rocky Linux 10.2' <<<"${help}"
grep -q 'PXE' <<<"${help}"

if ${SCRIPT} --interface lo --dry-run >/dev/null 2>&1; then
  echo 'loopback interface unexpectedly accepted' >&2
  exit 1
fi

mkdir -p "${TMP}/source/images/pxeboot" "${TMP}/source/EFI/BOOT"
printf 'kernel' > "${TMP}/source/images/pxeboot/vmlinuz"
printf 'initrd' > "${TMP}/source/images/pxeboot/initrd.img"
printf 'efi loader' > "${TMP}/source/EFI/BOOT/BOOTX64.EFI"

${SCRIPT} --dry-run \
  --interface test0 \
  --server-ip 192.168.50.1 \
  --source-dir "${TMP}/source" \
  --work-dir "${TMP}/work" \
  --http-port 8088 >/dev/null

test -s "${TMP}/work/dnsmasq.conf"
test -s "${TMP}/work/http/boot.ipxe"
test -s "${TMP}/work/http/images/pxeboot/vmlinuz"
test -s "${TMP}/work/http/images/pxeboot/initrd.img"
test -s "${TMP}/work/http/EFI/BOOT/BOOTX64.EFI"
grep -q 'inst.repo=' "${TMP}/work/http/boot.ipxe"
grep -q 'dhcp-range=192.168.50.1,proxy' "${TMP}/work/dnsmasq.conf"
grep -q '8088' "${TMP}/work/dnsmasq.conf"

echo 'PASS'
