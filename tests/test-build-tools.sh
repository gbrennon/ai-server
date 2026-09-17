#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_TASKS="${ROOT}/roles/build/tasks/main.yml"
SERVICE_TASKS="${ROOT}/roles/service/tasks/main.yml"

grep -q -- '-DLLAMA_BUILD_SERVER=ON' "${BUILD_TASKS}"
grep -q -- '-DLLAMA_BUILD_EXAMPLES=ON' "${BUILD_TASKS}"
grep -q 'target: all' "${BUILD_TASKS}"
grep -q 'all-cli' "${BUILD_TASKS}"
grep -q '/usr/local/bin' "${BUILD_TASKS}"
grep -q 'enabled: true' "${SERVICE_TASKS}"

echo 'PASS'
