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

### Deployment

For the authoritative GMKtec deployment procedure, use
[docs/deployment/overview.md](docs/deployment/overview.md):

```bash
make deploy-gmktec HOST=192.168.0.2 USER=gbrennon-local-ai
```

The overview defines which address is used for SSH and deployment
(`192.168.0.2`) and which address is used by inference clients
(`https://api.ai-gbrennon.home.arpa`).

## Documentation

| Topic | Guide |
|---|---|
| Documentation index | [docs/README.md](docs/README.md) |
| Deployment overview | [docs/deployment/overview.md](docs/deployment/overview.md) |
| GMKtec EVO X2 | [docs/hardware/gmktec-evo-x2.md](docs/hardware/gmktec-evo-x2.md) |
| Model switching | [docs/models/switching.md](docs/models/switching.md) |
| QEMU verification | [docs/verification/qemu.md](docs/verification/qemu.md) |

Guidance:

- **Verify** the automation in QEMU (`make qemu-verify`); **deploy** the
  systemd service to real hardware. See
  [docs/verification/qemu.md](docs/verification/qemu.md).
- **GMKtec EVO X2 owner?** Follow
  [the canonical deployment procedure](docs/deployment/overview.md):
  `make deploy-gmktec HOST=192.168.0.2 USER=gbrennon-local-ai`.

## Configuration

Everything lives in **`group_vars/all.yml`**:

| Variable | Default | Purpose |
|---|---|---|
| `llamacpp_version` | `master` | llama.cpp release tag (or `master`). Use a recent build. |
| `llamacpp_backend` | `cpu` | `cpu`, `vulkan`, `rocm`, or `cuda` |
| `llamacpp_model_url` | Llama-3.2-3B Q4_K_M | Direct GGUF URL (HF "resolve" link) **or** a GGUF repo root URL (file resolved from `llamacpp_model_file`) |
| `llamacpp_model_file` | ... | Filename for the model on the target (under `llamacpp_models_dir`) |
| `llamacpp_model_src` | `""` | Optional absolute path to a GGUF on the controller; when set it is rsynced to the target instead of downloading |
| `llamacpp_port` | `8080` | HTTP listen port |
| `llamacpp_ctx_size` | `8192` | Context window; `0` loads the selected GGUF's native context |
| `llamacpp_threads` | all cores | Inference threads |
| `llamacpp_extra_args` | (empty) | e.g. `-ngl 99 --flash-attn on --mlock` |
| `llamacpp_open_firewall` | `true` | Open the port in firewalld |
| `manage_swap` | `false` | Create a 4G swap file (helps low-RAM boxes) |
| `gpu_performance_mode` | `false` | Pin the AMD iGPU to max DPM clock at boot (lower request latency) |
| `gpu_performance_level` | `high` | DPM level when performance mode is on (`high`/`auto`/`low`) |
| `gateway_enabled` | false | Optional Caddy reverse proxy + dnsmasq resolver in front of llama-server (see [docs/deployment/gateway.md](docs/deployment/gateway.md)) |
| `gateway_domain` | `ai-gbrennon.home.arpa` | RFC 8375 zone served by the local resolver |
| `gateway_api_hostname` | `api.ai-gbrennon.home.arpa` | Hostname for the OpenAI-compatible API (SSE streaming, `tls internal`) |
| `gateway_lan_ip` | host LAN IP | Address `*.ai-gbrennon.home.arpa` resolves to |

### Picking a model

Use any Hugging Face GGUF "resolve" URL, e.g.:

```
https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf
```

Rule of thumb: Q4_K_M ≈ 0.6 GB per billion params (e.g. 8B → ~5 GB file,
needs ~8 GB RAM/VRAM with 8k context).

### GPU backends

- **ROCm/HIP** (AMD): install ROCm and set `llamacpp_backend: rocm`. Set
  `llamacpp_hip_architecture` to the target GPU architecture and add `-ngl 99`
  to `llamacpp_extra_args`.
- **Vulkan** (AMD / Intel / NVIDIA): set `llamacpp_backend: vulkan`. The
  playbook installs the Vulkan development packages. Add `-ngl 99` to
  `llamacpp_extra_args` to offload all layers to the GPU.
- **CUDA** (NVIDIA): install the driver and CUDA toolkit first, then set
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
  gateway/                 # optional Caddy reverse proxy + dnsmasq resolver
docs/
  README.md               # documentation index
  deployment/             # installation and operations
  hardware/               # machine and GPU guides
  models/                 # selection, switching, and context
  performance/            # tuning
  verification/           # QEMU and hardware verification
  installation/           # network installation
scripts/                  # bootstrap + deploy/verify wrappers
```

## Gateway (optional): Caddy reverse proxy + local DNS

Front `llama-server` with a TLS ingress and an authoritative local resolver so
tools use stable hostnames (`https://api.ai-gbrennon.home.arpa`) instead of raw ports:

```bash
# opt in (group_vars/all.yml or a profile) then enforce the gateway stage
make gateway-only
./scripts/verify-gateway.sh
sudo ./scripts/trust-caddy-ca.sh   # trust Caddy's internal TLS certs
```

Streaming is SSE-optimized (`flush_interval -1`), request bodies are
unlimited, and `*.ai-gbrennon.home.arpa` resolves via dnsmasq. See
[docs/deployment/gateway.md](docs/deployment/gateway.md).
