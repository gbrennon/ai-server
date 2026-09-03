# ai-server — llama.cpp automation for Fedora Server / Rocky Linux

Complete, idempotent automation to **build, deploy, and run llama.cpp**
(`llama-server`, OpenAI-compatible API) on any `dnf`-based distro:
Fedora Server, Rocky Linux 8/9/10, AlmaLinux, RHEL.

## Delivery-day runbook

See **[DEPLOYMENT.md](DEPLOYMENT.md)** — step-by-step instructions for deploying to a fresh mini PC (OS install, one-command setup, verification, troubleshooting).

## Quick start (one command)

Clone this repo on the target machine and run:

```bash
sudo ./bootstrap.sh
```

That installs Ansible, builds llama.cpp from source (optimized for your CPU),
downloads a GGUF model, opens the firewall, and starts a hardened systemd
service. When it finishes:

```bash
curl http://localhost:8080/health
# Web UI:   http://<server>:8080/
# OpenAI API: http://<server>:8080/v1/chat/completions
```

For a remote server:

```bash
# add host to inventory.ini first, then:
sudo ./bootstrap.sh myserver
```

## Configuration

Everything lives in **`group_vars/all.yml`**:

| Variable | Default | Purpose |
|---|---|---|
| `llamacpp_version` | `b5446` | llama.cpp release tag (or `master`) |
| `llamacpp_backend` | `cpu` | `cpu`, `vulkan`, or `cuda` |
| `llamacpp_model_url` | Llama-3.2-3B Q4_K_M | Direct GGUF download URL (HF "resolve" links) |
| `llamacpp_model_file` | ... | Local filename for the model |
| `llamacpp_port` | `8080` | HTTP listen port |
| `llamacpp_ctx_size` | `8192` | Context window |
| `llamacpp_threads` | all cores | Inference threads |
| `llamacpp_extra_args` | (empty) | e.g. `-ngl 99 --flash-attn --mlock` |
| `llamacpp_open_firewall` | `true` | Open the port in firewalld |
| `manage_swap` | `false` | Create a 4G swap file (helps low-RAM boxes) |

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

## Day-2 operations

```bash
systemctl status llama-server
journalctl -u llama-server -f          # or: tail -f /var/log/llama.cpp/llama-server.log
systemctl restart llama-server
make models-only                       # re-run just the model download
```

To change the model or settings: edit `group_vars/all.yml`, then re-run
`sudo ./bootstrap.sh` (or `make deploy`) — it's fully idempotent; only real
changes trigger rebuilds/restarts.

## Layout

```
bootstrap.sh              # one-command entrypoint
site.yml                  # main playbook
inventory.ini             # target hosts
group_vars/all.yml        # ALL configuration
requirements.yml          # Ansible collections
roles/
  common/                 # packages, service user, dirs, swap, firewalld
  build/                  # git clone + cmake build (cpu/vulkan/cuda)
  models/                 # resumable GGUF download
  service/                # hardened systemd unit + health check
```
