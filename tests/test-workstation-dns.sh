#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root_dir/scripts/configure-workstation-dns.sh"
test -x "$script"
bash -n "$script"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/nmcli" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NMCLI_LOG"
case "$*" in
  "-t -f NAME,TYPE,DEVICE connection show --active")
    printf 'Home Wi-Fi:802-11-wireless:wlan0\n'
    ;;
  "-g ipv4.dns connection show Home Wi-Fi")
    printf '9.9.9.9 1.1.1.1\n'
    ;;
  "-g ipv4.dns-search connection show Home Wi-Fi")
    printf '~corp.example\n'
    ;;
  *)
    ;;
esac
FAKE

cat > "$tmp_dir/resolvectl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$RESOLVECTL_LOG"
FAKE
chmod +x "$tmp_dir/nmcli" "$tmp_dir/resolvectl"
NMCLI_BIN="$tmp_dir/nmcli" RESOLVECTL_BIN="$tmp_dir/resolvectl" \
  NMCLI_LOG="$tmp_dir/nmcli.log" RESOLVECTL_LOG="$tmp_dir/resolvectl.log" \
  WORKSTATION_DNS_ALLOW_NONROOT=1 "$script"

grep -q 'connection modify Home Wi-Fi ipv4.dns 9.9.9.9 1.1.1.1 192.168.0.2' \
  "$tmp_dir/nmcli.log"
grep -q 'ipv4.dns-search ~corp.example ~gbrennon.home.arpa' "$tmp_dir/nmcli.log"
grep -q 'connection up Home Wi-Fi' "$tmp_dir/nmcli.log"
grep -q 'query api.gbrennon.home.arpa' "$tmp_dir/resolvectl.log"

printf '%s\n' 'workstation DNS tests passed'
