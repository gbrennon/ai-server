#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEMP_DIR}"' EXIT

python3 - "${TEMP_DIR}" <<'PY'
import json
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
profile = {
    "client_provider_name": "test-ai-server",
    "gateway_api_hostname": "api.test.home.arpa",
}
(root / "profile.yml").write_text(yaml.safe_dump(profile), encoding="utf-8")
(root / "model.json").write_text(
    json.dumps(
        {
            "data": [
                {
                    "id": "/models/Detected-Q4.gguf",
                    "meta": {"n_ctx": 32768},
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "props.json").write_text(
    json.dumps(
        {
            "default_generation_settings": {
                "n_ctx": 32768,
                "params": {"reasoning_format": "deepseek"},
            },
            "model_path": "/models/Detected-Q4.gguf",
        }
    ),
    encoding="utf-8",
)
(root / "pi.json").write_text(json.dumps({"providers": {"unrelated": {"models": []}}}), encoding="utf-8")
(root / "omp.yml").write_text(
    yaml.safe_dump({"providers": {"unrelated": {"models": []}}}),
    encoding="utf-8",
)
(root / "omp-runtime.yml").write_text(
    yaml.safe_dump(
        {
            "modelRoles": {
                "task": "test-ai-server/Old-Q4.gguf:auto",
                "plan": "unrelated/Plan-Q4.gguf",
            },
            "retry": {
                "fallbackChains": {
                    "test-ai-server/*": ["test-ai-server/Old-Q4.gguf"],
                    "unrelated/*": ["unrelated/Plan-Q4.gguf"],
                }
            },
        }
    ),
    encoding="utf-8",
)
PY
export MODEL_METADATA_DIR="${TEMP_DIR}"

"${ROOT_DIR}/scripts/sync-client-model.sh" register \
  "${TEMP_DIR}/profile.yml" "${TEMP_DIR}/pi.json" "${TEMP_DIR}/omp.yml" \
  "${TEMP_DIR}/omp-runtime.yml"
"${ROOT_DIR}/scripts/sync-client-model.sh" register \
  "${TEMP_DIR}/profile.yml" "${TEMP_DIR}/pi.json" "${TEMP_DIR}/omp.yml" \
  "${TEMP_DIR}/omp-runtime.yml"

python3 - "${TEMP_DIR}" <<'PY'
import json
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
pi = json.loads((root / "pi.json").read_text(encoding="utf-8"))
omp = yaml.safe_load((root / "omp.yml").read_text(encoding="utf-8"))
runtime = yaml.safe_load((root / "omp-runtime.yml").read_text(encoding="utf-8"))
for config in (pi, omp):
    assert set(config["providers"]) == {"unrelated", "test-ai-server"}
    assert len(config["providers"]["test-ai-server"]["models"]) == 1
assert pi["providers"]["test-ai-server"]["baseUrl"] == "https://api.test.home.arpa/v1"
assert omp["providers"]["test-ai-server"]["baseUrl"] == "https://api.test.home.arpa/v1"
assert pi["providers"]["test-ai-server"]["models"][0]["id"] == "Detected-Q4.gguf"
assert omp["providers"]["test-ai-server"]["models"][0]["id"] == "Detected-Q4.gguf"
assert pi["providers"]["test-ai-server"]["models"][0]["contextWindow"] == 32768
assert pi["providers"]["test-ai-server"]["models"][0]["maxTokens"] == 8192
assert pi["providers"]["test-ai-server"]["models"][0]["reasoning"] is True
assert runtime["modelRoles"]["task"] == "test-ai-server/Detected-Q4.gguf:auto"
assert runtime["modelRoles"]["plan"] == "unrelated/Plan-Q4.gguf"
assert runtime["retry"]["fallbackChains"]["test-ai-server/*"] == [
    "test-ai-server/Detected-Q4.gguf"
]
PY

"${ROOT_DIR}/scripts/sync-client-model.sh" unregister \
  "${TEMP_DIR}/profile.yml" "${TEMP_DIR}/pi.json" "${TEMP_DIR}/omp.yml" \
  "${TEMP_DIR}/omp-runtime.yml"

python3 - "${TEMP_DIR}" <<'PY'
import json
import pathlib
import sys

import yaml

root = pathlib.Path(sys.argv[1])
pi = json.loads((root / "pi.json").read_text(encoding="utf-8"))
omp = yaml.safe_load((root / "omp.yml").read_text(encoding="utf-8"))
runtime = yaml.safe_load((root / "omp-runtime.yml").read_text(encoding="utf-8"))
assert set(pi["providers"]) == {"unrelated"}
assert set(omp["providers"]) == {"unrelated"}
assert "task" not in runtime["modelRoles"]
assert "test-ai-server/*" not in runtime["retry"]["fallbackChains"]
assert runtime["modelRoles"]["plan"] == "unrelated/Plan-Q4.gguf"
PY

printf '%s\n' '[OK] client registry synchronization tests passed'
