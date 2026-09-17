# Deployment overview

This guide covers first installation and deployment. For day-2 operations, see
[operations.md](operations.md). For the GMKtec EVO X2, start with
[hardware/gmktec-evo-x2.md](../hardware/gmktec-evo-x2.md).

## Before deployment

- Choose a model in [model selection](../models/selection.md).
- Set `llamacpp_model_url` and `llamacpp_model_file` in
  [`group_vars/all.yml`](../../group_vars/all.yml), or use a hardware profile.
  To ship a GGUF you already have on the controller, set `llamacpp_model_src`
  to its absolute path (rsynced to the target instead of downloaded).
- For AMD/Intel GPUs, use `llamacpp_backend: vulkan` and `-ngl 99`.
- Verify changes in QEMU with `make qemu-verify` when practical.

## Install the OS

Install Fedora Server or Rocky Linux 9/10, create a sudo user, and enable SSH.
The target needs SSH, sudo, and Python 3; Ansible runs on the workstation.

## Deploy locally

```bash
sudo dnf install -y git
git clone <your-repo-url>
cd ai-server
sudo ./bootstrap.sh
```

## Deploy remotely

```bash
ssh-copy-id <user>@<mini-pc-ip>
./scripts/deploy-remote.sh <mini-pc-ip> <user> [profile.yml]
```

For the known GMKtec host:

```bash
./scripts/deploy-remote.sh \
  192.168.0.2 \
  gbrennon-local-ai \
  profiles/gmktec-evo-x2.yml
```

The script checks connectivity and sudo, installs Ansible collections, runs the
playbook, builds llama.cpp, downloads or pushes the selected GGUF, installs the systemd
service, and verifies `/health` plus a test completion.

## Idempotency

Re-running the deployment applies changed configuration and restarts services
when necessary. Model files are downloaded (or pushed from the controller when
`llamacpp_model_src` is set) only when the configured filename is missing on the
target. See [model switching](../models/switching.md) before changing models.
