#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${ROOT}/profiles/gmktec-evo-x2.yml"

# Folded YAML scalars insert spaces at line breaks. The model URL must be one
# uninterrupted URL because the Ansible curl command consumes it as one arg.
url="$(awk '/^llamacpp_model_url:/ {print $2; exit}' "${PROFILE}")"
if [[ "${url}" != https://*.gguf ]]; then
  echo 'EVO X2 model URL must be one uninterrupted .gguf URL' >&2
  exit 1
fi

echo 'PASS'
