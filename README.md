# ai-server — llama.cpp automation for Fedora Server / Rocky Linux

Idempotent automation to **build, deploy, and run llama.cpp** (`llama-server`,
OpenAI-compatible API) on any `dnf`-based distro: Fedora Server, Rocky Linux
8/9/10, AlmaLinux, RHEL.

## Quick start

Clone the repo on the target machine and run:

```bash
sudo ./bootstrap.sh
```

That installs Ansible, builds llama.cpp for the CPU, downloads a GGUF model,
opens the firewall, and starts a hardened systemd service. When it finishes:

```bash
curl http://localhost:8080/health
# Web UI:     http://<server>:8080/
# OpenAI API: http://<server>:8080/v1/chat/completions
```

For a remote server (add it to `inventory.ini` first):

```bash
sudo ./bootstrap.sh myserver
```

## Documentation

| Topic | Guide |
|---|---|
| Delivery-day runbook | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| GMKtec EVO X2 (GPU/Vulkan) | [docs/gmktec-evo-x2.md](docs/gmktec-evo-x2.md) |
| Rocky PXE network installation | [docs/rocky-network-install.md](docs/rocky-network-install.md) |
| QEMU end-to-end verification | [docs/qemu-verification.md](docs/qemu-verification.md) |

Guidance:

- **Verify** the automation in QEMU (`make qemu-verify`); **deploy** the
  systemd service to real hardware. See
  [docs/qemu-verification.md](docs/qemu-verification.md).
- **GMKtec EVO X2 owner?** Deploy with
  `./scripts/deploy-gmktec.sh <host> [user]` (optional `--setup` for a fresh
  box). See [docs/gmktec-evo-x2.md](docs/gmktec-evo-x2.md).

## Configuration

Everything lives in **`group_vars/all.yml`**:

| Variable | Default | Purpose |
|---|---|---|
| `llamacpp_version` | `master` | llama.cpp release tag (or `master`). Use a recent build — pre-2025-08 builds have broken MoE Vulkan prefill (~15x slower). |
| `llamacpp_backend` | `cpu` | `cpu`, `vulkan`, or `cuda` |
| `llamacpp_model_url` | Llama-3.2-3B Q4_K_M | Direct GGUF download URL (HF "resolve" links) |
| `llamacpp_model_file` | ... | Local filename for the model |
| `llamacpp_port` | `8080` | HTTP listen port |
| `llamacpp_ctx_size` | `8192` | Context window |
| `llamacpp_threads` | all cores | Inference threads |
| `llamacpp_extra_args` | (empty) | e.g. `-ngl 99 --flash-attn on --mlock` (recent builds need a value for `--flash-attn`) |
| `llamacpp_open_firewall` | `true` | Open the port in firewalld |
| `manage_swap` | `false` | Create a 4G swap file (helps low-RAM boxes) |
| `gpu_performance_mode` | `false` | Pin the AMD iGPU to max DPM clock at boot (lower request latency) |
| `gpu_performance_level` | `high` | DPM level when performance mode is on (`high`/`auto`/`low`) |

### Picking a model

Use any Hugging Face GGUF "resolve" URL, e.g.:

```
https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf
```

Rule of thumb: Q4_K_M ≈ 0.6 GB per billion params (e.g. 8B → ~5 GB file,
needs ~8 GB RAM/VRAM with 8k context).

### GPU backends

- **Vulkan** (AMD / Intel / NVIDIA): set `llamacpp_backend: vulkan`. The
  playbook installs the Vulkan dev packages. Add `-ngl 99` to
  `llamacpp_extra_args` to offload all layers to the GPU.
- **CUDA** (NVIDIA): install the driver + CUDA toolkit first, then set
  `llamacpp_backend: cuda`.

## Layout

```
bootstrap.sh              # one-command entrypoint
site.yml                  # main playbook
inventory.ini             # target hosts
group_vars/all.yml        # ALL configuration
requirements.yml          # Ansible collections
profiles/                 # hardware profiles (e.g. gmktec-evo-x2.yml)
roles/
  common/                 # packages, service user, dirs, swap, firewalld
  build/                  # git clone + cmake build (cpu/vulkan/cuda)
  models/                 # resumable GGUF download
  service/                # hardened systemd unit + health check
docs/
  DEPLOYMENT.md           # delivery-day runbook
  gmktec-evo-x2.md        # GMKtec EVO X2 guide
  qemu-verification.md    # QEMU end-to-end verification guide
scripts/                  # bootstrap + deploy/verify wrappers
```
