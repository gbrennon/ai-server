#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
PROFILE="${2:-}"
PI_CONFIG="${3:-${HOME}/.pi/agent/models.json}"
OMP_CONFIG="${4:-${HOME}/.omp/agent/models.yml}"
OMP_RUNTIME_CONFIG="${5:-${HOME}/.omp/agent/config.yml}"

if [[ "${ACTION}" != register && "${ACTION}" != unregister ]]; then
  printf '%s\n' "usage: $0 register|unregister PROFILE [PI_CONFIG] [OMP_CONFIG] [OMP_RUNTIME_CONFIG]" >&2
  exit 2
fi

[[ -f "${PROFILE}" ]] || {
  printf '[ERROR] profile not found: %s\n' "${PROFILE}" >&2
  exit 1
}

python3 - "${ACTION}" "${PROFILE}" "${PI_CONFIG}" "${OMP_CONFIG}" "${OMP_RUNTIME_CONFIG}" <<'PY'
import json
import os
import pathlib
import sys
import tempfile
import urllib.request
from typing import Any

import yaml

action, profile_path, pi_path, omp_path, omp_runtime_path = sys.argv[1:]


def load_mapping(path: str, label: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as stream:
        value = yaml.safe_load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"{label} must contain a mapping: {path}")
    return value


def load_json(path: str) -> dict[str, Any]:
    with open(path, encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"Pi config must contain a mapping: {path}")
    return value


def load_profile(path: str) -> dict[str, Any]:
    profile = load_mapping(path, "profile")
    required = ("client_provider_name", "gateway_api_hostname")
    missing = [key for key in required if key not in profile]
    if missing:
        raise ValueError(f"profile missing registry fields: {', '.join(missing)}")
    return profile


def read_json_url(url: str) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=20) as response:
        value = json.load(response)
    if not isinstance(value, dict):
        raise ValueError(f"model metadata must contain a mapping: {url}")
    return value


def detect_model(profile: dict[str, Any]) -> dict[str, Any]:
    metadata_dir = os.environ.get("MODEL_METADATA_DIR")
    if metadata_dir:
        model_data = json.loads(
            pathlib.Path(metadata_dir, "model.json").read_text(encoding="utf-8")
        )
        props = json.loads(
            pathlib.Path(metadata_dir, "props.json").read_text(encoding="utf-8")
        )
    else:
        endpoint = f"https://{profile['gateway_api_hostname']}"
        model_data = read_json_url(f"{endpoint}/v1/models")
        props = read_json_url(f"{endpoint}/props")
    models = model_data.get("data")
    if not isinstance(models, list) or not models:
        raise ValueError("model metadata did not contain a model")
    first_model = models[0]
    if not isinstance(first_model, dict):
        raise ValueError("model metadata contained an invalid model")
    raw_model = props.get("model_alias") or first_model.get("id")
    if not isinstance(raw_model, str) or not raw_model:
        raise ValueError("model metadata did not contain a model identifier")
    model_id = pathlib.PurePosixPath(raw_model).name
    generation = props.get("default_generation_settings", {})
    if not isinstance(generation, dict):
        generation = {}
    context = generation.get("n_ctx")
    if not isinstance(context, int):
        metadata = first_model.get("meta", {})
        context = metadata.get("n_ctx") if isinstance(metadata, dict) else None
    if not isinstance(context, int) or context <= 0:
        raise ValueError("model metadata did not contain a positive context size")
    params = generation.get("params", {})
    reasoning_format = params.get("reasoning_format") if isinstance(params, dict) else None
    reasoning = isinstance(reasoning_format, str) and reasoning_format not in ("", "none")
    return {"id": model_id, "context": context, "reasoning": reasoning}


def model_record(
    provider: str, profile: dict[str, Any], detected: dict[str, Any]
) -> dict[str, Any]:
    model = str(detected["id"])
    context = int(detected["context"])
    configured_max_tokens = int(profile.get("client_max_tokens", 8192))
    max_tokens = min(context, configured_max_tokens)
    return {
        "id": model,
        "name": f"{model} ({provider})",
        "contextWindow": context,
        "maxTokens": max_tokens,
        "reasoning": bool(detected["reasoning"]),
        "input": ["text"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
    }


def provider_records(
    profile: dict[str, Any], detected: dict[str, Any]
) -> tuple[str, dict[str, Any], dict[str, Any]]:
    provider = str(profile["client_provider_name"])
    base_url = f"https://{profile['gateway_api_hostname']}/v1"
    model = model_record(provider, profile, detected)
    pi_provider = {
        "baseUrl": base_url,
        "api": "openai-completions",
        "apiKey": "not-needed",
        "compat": {"supportsDeveloperRole": False, "supportsReasoningEffort": False},
        "models": [model],
    }
    omp_provider = {
        "api": "openai-completions",
        "auth": "none",
        "baseUrl": base_url,
        "discovery": {"type": "llama.cpp"},
        "models": [model],
    }
    return provider, pi_provider, omp_provider


def atomic_write(path: str, value: Any, formatter: str) -> None:
    destination = pathlib.Path(path).expanduser()
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix=f".{destination.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            if formatter == "json":
                json.dump(value, stream, indent=2)
                stream.write("\n")
            else:
                yaml.safe_dump(value, stream, sort_keys=False, default_flow_style=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    except BaseException:
        pathlib.Path(temporary).unlink(missing_ok=True)
        raise


profile = load_profile(profile_path)
provider = str(profile["client_provider_name"])
detected = detect_model(profile) if action == "register" else {
    "id": str(profile.get("llamacpp_model_file", "unknown-model"))
}
_, pi_provider, omp_provider = provider_records(profile, detected) if action == "register" else (
    provider,
    {},
    {},
)
model_id = str(detected["id"])
managed_model = f"{provider}/{model_id}"
pi = load_json(pi_path)
omp = load_mapping(omp_path, "OMP model config")
omp_runtime = load_mapping(omp_runtime_path, "OMP runtime config")
pi_providers = pi.setdefault("providers", {})
omp_providers = omp.setdefault("providers", {})
if not isinstance(pi_providers, dict) or not isinstance(omp_providers, dict):
    raise ValueError("both client configs must contain providers mappings")

if action == "register":
    pi_providers[provider] = pi_provider
    omp_providers[provider] = omp_provider
    roles = omp_runtime.setdefault("modelRoles", {})
    if not isinstance(roles, dict):
        raise ValueError("OMP runtime config modelRoles must be a mapping")
    for role, value in list(roles.items()):
        if isinstance(value, str) and value.startswith(f"{provider}/"):
            suffix = ":auto" if value.endswith(":auto") else ""
            roles[role] = f"{managed_model}{suffix}"
    fallback_chains = omp_runtime.setdefault("retry", {}).setdefault("fallbackChains", {})
    if not isinstance(fallback_chains, dict):
        raise ValueError("OMP runtime fallbackChains must be a mapping")
    if f"{provider}/*" in fallback_chains:
        fallback_chains[f"{provider}/*"] = [managed_model]
else:
    pi_providers.pop(provider, None)
    omp_providers.pop(provider, None)
    roles = omp_runtime.get("modelRoles", {})
    if isinstance(roles, dict):
        for role, value in list(roles.items()):
            if isinstance(value, str) and value.startswith(f"{provider}/"):
                del roles[role]
    retry = omp_runtime.get("retry", {})
    if isinstance(retry, dict):
        fallback_chains = retry.get("fallbackChains", {})
        if isinstance(fallback_chains, dict):
            fallback_chains.pop(f"{provider}/*", None)

atomic_write(pi_path, pi, "json")
atomic_write(omp_path, omp, "yaml")
atomic_write(omp_runtime_path, omp_runtime, "yaml")
verb = "registered" if action == "register" else "unregistered"
detail = (
    f" model={model_id} context={detected['context']} reasoning={detected['reasoning']}"
    if action == "register"
    else ""
)
print(f"[OK] {verb} profile provider {provider} in Pi and OMP{detail}")
PY
