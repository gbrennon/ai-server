#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"

cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${TMP}/bin/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'/v1/chat/completions'* ]]; then
  printf '{"content":"VERIFIED"}\n'
fi
exit 0
EOF
cat >"${TMP}/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
set -e
inventory=''
while (($#)); do
  if [[ "$1" == '-i' ]]; then inventory=$2; shift 2; else shift; fi
done
grep -q '^\[llama_servers\]$' "$inventory"
grep -q 'ansible_host=192.0.2.10' "$inventory"
grep -q 'ansible_user=test-user' "$inventory"
EOF
chmod +x "${TMP}/bin"/*

PATH="${TMP}/bin:${PATH}" \
  "${ROOT}/scripts/deploy-remote.sh" 192.0.2.10 test-user profiles/gmktec-evo-x2.yml >/dev/null

echo 'PASS'
