#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT

mkdir -p "${TMP}/bin"

# Mock ping
cat >"${TMP}/bin/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Mock ssh
cat >"${TMP}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ -f "${MOCK_STATE_DIR}/ssh_fail" ]]; then
  if [[ "$*" == *"BatchMode=yes"* ]]; then
    exit 1
  fi
fi
if [[ "$*" == *"command -v dnf"* || "$*" == *"echo ok"* || "$*" == *"sudo -n true"* ]]; then
  exit 0
fi
exit 0
EOF

# Mock sshpass
cat >"${TMP}/bin/sshpass" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|-e) shift ;;
    *) break ;;
  esac
done
exec "$@"
EOF

# Mock ssh-copy-id
cat >"${TMP}/bin/ssh-copy-id" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Mock ansible-galaxy
cat >"${TMP}/bin/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

# Mock curl
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'/v1/chat/completions'* ]]; then
  printf '{"choices":[{"message":{"content":"VERIFIED"}}]}\n'
fi
exit 0
EOF

# Mock ansible-playbook
cat >"${TMP}/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
set -e
inventory=''
while (($#)); do
  case "$1" in
    -i) inventory="$2"; shift 2 ;;
    *) shift ;;
  esac
done

grep -q '^\[llama_servers\]$' "$inventory"
grep -q 'ansible_host=192.0.2.100' "$inventory"
grep -q 'ansible_user=wizard-user' "$inventory"
if [[ -n "${EXPECT_PASS:-}" ]]; then
  grep -q "ansible_ssh_pass=${EXPECT_PASS}" "$inventory"
fi
EOF

chmod +x "${TMP}/bin"/*

export MOCK_STATE_DIR="${TMP}"

# Test 1: Non-interactive execution with explicit parameters
echo "--- Testing deploy-interactive.sh (non-interactive mode) ---"
PATH="${TMP}/bin:${PATH}" \
  "${ROOT}/scripts/deploy-interactive.sh" \
    --host 192.0.2.100 \
    --user wizard-user \
    --profile profiles/gmktec-evo-x2.yml \
    --password secretpass \
    --non-interactive >"${TMP}/test1.log" 2>&1

grep -q "SUCCESS: llama.cpp server is deployed and operational!" "${TMP}/test1.log"
grep -q "Target Host: 192.0.2.100" "${TMP}/test1.log"

# Test 2: Interactive execution with simulated standard input (key auth succeeds)
echo "--- Testing deploy-interactive.sh (interactive key-based) ---"
printf "192.0.2.100\nwizard-user\n1\n" | \
  PATH="${TMP}/bin:${PATH}" \
  "${ROOT}/scripts/deploy-interactive.sh" >"${TMP}/test2.log" 2>&1

grep -q "SUCCESS: llama.cpp server is deployed and operational!" "${TMP}/test2.log"
grep -q "SSH key authentication succeeded!" "${TMP}/test2.log"

# Test 3: Interactive execution where key auth fails and password is supplied
echo "--- Testing deploy-interactive.sh (interactive password-based) ---"
touch "${MOCK_STATE_DIR}/ssh_fail"
printf "192.0.2.100\nwizard-user\n1\nmypassword123\nn\nn\n" | \
  EXPECT_PASS="mypassword123" \
  PATH="${TMP}/bin:${PATH}" \
  "${ROOT}/scripts/deploy-interactive.sh" >"${TMP}/test3.log" 2>&1

grep -q "SUCCESS: llama.cpp server is deployed and operational!" "${TMP}/test3.log"

echo 'PASS'
