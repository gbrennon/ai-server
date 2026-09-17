#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASKS="${ROOT}/roles/models/tasks/main.yml"

# Model download must run as the already-privileged play user. Becoming the
# unprivileged service account makes Ansible require unsupported remote ACLs.
if grep -q 'become_user:' "${TASKS}"; then
  echo 'model download must not become an unprivileged user' >&2
  exit 1
fi
grep -q 'name: Ensure model file ownership' "${TASKS}"
grep -q 'owner: "{{ llamacpp_user }}"' "${TASKS}"

echo 'PASS'
