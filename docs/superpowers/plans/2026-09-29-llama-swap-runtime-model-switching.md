# llama-swap Runtime Model Switching Plan

**Goal:** Add optional runtime model switching without redeploying or editing the managed `llama-server` unit. Preserve the current single-model deployment when disabled.

**Target host:** `ssh gbrennon-local-ai@192.168.0.2`

**Architecture:** Install llama-swap as a localhost-only systemd proxy. It launches the existing `/opt/llama.cpp/build-hip/bin/llama-server` on demand for configured GGUF files under `/var/lib/llama.cpp/models/`, using the existing ROCm runtime and profile arguments. Configure one-model-at-a-time eviction to avoid GPU memory contention. When enabled, route the existing gateway upstream through llama-swap; when disabled, retain the current `llama-server` service and port.

## Constraints

- Default behavior remains unchanged with `llama_swap_enabled: false`.
- Do not download models; configured files must already exist on the target.
- Bind llama-swap to `127.0.0.1`; preserve the public gateway hostname and TLS behavior.
- Keep model identifiers explicit and compatible with Pi/OMP client registration.
- Do not disable or replace the existing deployment until the new service is verified.
- Support rollback by disabling llama-swap and restoring the standalone service.

## Tasks

### 1. Confirm llama-swap contract on the target

- [ ] Inspect the current llama.cpp version, architecture, service arguments, model files, gateway upstream, and available llama-swap release for compatibility.
- [ ] Confirm the llama-swap configuration syntax, model request semantics, process replacement behavior, health endpoint, and release checksum.
- [ ] Record the selected pinned version and the exact request field used to select a model.

### 2. Add configuration variables

**Files:**

- Modify: `group_vars/all.yml`
- Modify: `profiles/gmktec-evo-x2.yml`

- [ ] Add `llama_swap_enabled`, pinned version, binary path, config path, localhost port, and one-model-at-a-time settings.
- [ ] Add a profile-owned model list containing stable model IDs and exact existing GGUF filenames.
- [ ] Keep the current `llamacpp_model_*` values intact for rollback and disabled-mode behavior.

### 3. Add the Ansible role

**Files:**

- Create: `roles/llama-swap/defaults/main.yml`
- Create: `roles/llama-swap/tasks/main.yml`
- Create: `roles/llama-swap/handlers/main.yml`
- Create: `roles/llama-swap/templates/llama-swap.service.j2`
- Create: `roles/llama-swap/templates/llama-swap.yml.j2`
- Modify: `site.yml`

- [ ] Install the pinned binary idempotently with checksum verification.
- [ ] Validate every configured GGUF exists before enabling the proxy.
- [ ] Render commands using the existing HIP binary, ROCm library path, model directory, and profile runtime flags.
- [ ] Run llama-swap as the existing service user with systemd hardening matching `llama-server`.
- [ ] Ensure the standalone `llama-server` and llama-swap do not compete for the GPU when the feature is enabled.
- [ ] Add restart, readiness, status, and failure-log handling.

### 4. Integrate the gateway

**Files:**

- Modify: `roles/gateway/defaults/main.yml`
- Modify: the existing Caddy template
- Modify: `roles/gateway/tasks/main.yml` if needed

- [ ] Resolve the gateway upstream to llama-swap when enabled and the existing `gateway_llama_port` otherwise.
- [ ] Keep the public API hostname, certificates, DNS, and authentication behavior unchanged.
- [ ] Verify the Caddy configuration before reload.

### 5. Add deployment and verification coverage

**Files:**

- Modify: `Makefile`
- Create: `scripts/verify-llama-swap.sh`
- Modify: `docs/models/switching.md`
- Modify: `docs/deployment/overview.md`

- [ ] Add a targeted role/deployment command that does not require changing unrelated profile values.
- [ ] Verify model A through the existing gateway, request model B, and verify that the served model changes without redeploying.
- [ ] Verify only one model process is resident and GPU memory remains within the host budget.
- [ ] Verify the disabled path leaves the current `llama-server` behavior unchanged.
- [ ] Document model selection, operational commands, logs, health checks, and rollback.

## Rollout

1. Deploy the role with the proxy disabled and validate the existing service.
2. Install and validate llama-swap on `192.168.0.2` without changing the gateway.
3. Enable the proxy with two already-downloaded models and test its localhost endpoint.
4. Switch the gateway upstream and run end-to-end API checks through the existing hostname.
5. If validation fails, stop/disable llama-swap, restore/start `llama-server`, and revert the gateway upstream.

## Verification Checklist

- [ ] Ansible syntax and repository checks pass.
- [ ] Existing single-model service passes health checks with the feature disabled.
- [ ] Each configured model is selectable by its documented ID.
- [ ] A model switch occurs without an Ansible redeploy.
- [ ] Only one model is loaded at once.
- [ ] Gateway and client behavior remain compatible.
- [ ] Rollback restores the current service successfully.
