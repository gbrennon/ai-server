#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cat >"${TMP_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SSH_ARGS_FILE}"
EOF
chmod +x "${TMP_DIR}/ssh"

SSH_ARGS_FILE="${TMP_DIR}/args" PATH="${TMP_DIR}:${PATH}" \
  "${ROOT_DIR}/scripts/ssh-gmktec.sh" >/dev/null

mapfile -t args <"${TMP_DIR}/args"
[[ "${args[0]}" == "-o" ]]
[[ "${args[1]}" == "IdentitiesOnly=yes" ]]
[[ "${args[2]}" == "-i" ]]
[[ "${args[3]}" == "${HOME}/.ssh/id_ed25519" ]]
[[ "${args[4]}" == "-o" ]]
[[ "${args[5]}" == "PreferredAuthentications=publickey" ]]
[[ "${args[6]}" == "-o" ]]
[[ "${args[7]}" == "PasswordAuthentication=no" ]]
[[ "${args[8]}" == "gbrennon-local-ai@192.168.0.2" ]]

SSH_ARGS_FILE="${TMP_DIR}/args" PATH="${TMP_DIR}:${PATH}" \
  "${ROOT_DIR}/scripts/ssh-gmktec.sh" 192.168.0.9 test-user >/dev/null
mapfile -t args <"${TMP_DIR}/args"
[[ "${args[8]}" == "test-user@192.168.0.9" ]]

printf '%s\n' '[OK] ssh-gmktec wrapper tests passed'
