# Verifying the llama.cpp automation in QEMU

This guide proves the automation actually works before touching a real
server: it boots a throwaway **Fedora Server** or **Rocky Linux** VM with
QEMU/KVM, runs the full `bootstrap.sh` inside it, and validates the API
end-to-end.

---

## Option 1 — fully automated (recommended)

One script does everything:

```bash
./scripts/qemu-verify.sh rocky    # or: fedora
```

The script:

1. Downloads a cloud qcow2 image (cached in `~/.local/share/ai-server-qemu/`),
2. Generates a cloud-init seed with your SSH key (`~/.ssh/id_ed25519`) and
   passwordless sudo for user `ai`,
3. Boots the VM with KVM — **12 GB RAM / 8 vCPUs** — and forwards:
   - host `2222` → VM `22` (SSH)
   - host `8080` → VM `8080` (llama-server)
4. Copies your local Hugging Face model
   (`~/.cache/huggingface/.../Qwen3-8B-Q4_K_M.gguf`) into the VM via scp and
   rewrites `group_vars/all.yml` so the playbook serves **Qwen3-8B**,
5. Copies this repo into the VM and runs `sudo ./bootstrap.sh` inside it
   (installs packages, builds llama.cpp, configures firewalld, starts the
   systemd service),
6. Verifies:
   - `curl http://127.0.0.1:8080/health` → `{"status":"ok"}`
   - a real chat completion on `POST /v1/chat/completions` (expects the
     literal token `VERIFIED` in the response),
7. Prints `SUCCESS: automation verified end-to-end` and shuts the VM down.

### Requirements

- Linux host with KVM (`ls -l /dev/kvm` and be in the `kvm` group)
- `qemu-system-x86_64`, `cloud-localds` (package `cloud-image-utils` on
  Fedora), `sshpass` not needed — keys only
- ~15 GB free disk (image cache + VM disk)
- The Qwen3-8B model present at the path configured inside the script
  (`MODEL_SRC` variable) — adjust it if yours differs

### Expected duration

| Phase | Time (typical) |
|---|---|
| Image download (first run) | 2–5 min |
| VM boot + cloud-init | 2–4 min |
| Model copy into VM (scp) | 1–3 min |
| dnf packages + llama.cpp build | 5–15 min |
| Health check + chat test | < 1 min |
| **Total (first run)** | **~10–25 min** |

Live progress:

```bash
tail -f /tmp/qemu-verify.log          # script output
```

If the script fails, the VM serial console is at
`~/.local/share/ai-server-qemu/<distro>/serial.log` and the bootstrap log is
in `~/bootstrap-run.log` *inside* the VM.

---

## Verify the GMKtec EVO X2 profile specifically

Running `./scripts/qemu-verify.sh` (or `make qemu-verify`) verifies the 
automation with the default CPU setup. To check the **GMKtec EVO X2** deploy 
profile before you power the real mini PC on, use:

```bash
./scripts/qemu-verify-gmktec.sh      # or: make qemu-verify-gmktec
```

This passes the real hardware profile (`profiles/gmktec-evo-x2.yml`) as Ansible 
extra vars — the same way `deploy-remote.sh` applies it on real hardware — but 
adapted for the VM, which has **no GPU** and limited RAM:

- `llamacpp_backend` is forced to `cpu` (QEMU exposes no Vulkan device)
- `llamacpp_extra_args` (`-ngl 99 --flash-attn on`) is emptied (GPU-only flags)
- context is reduced to 8k and threads to the VM's vCPUs
- the small Qwen3-8B model is used instead of the 30B GPU model

So this proves the profile YAML parses, the playbook consumes it cleanly, and 
the hardened systemd service + OpenAI-compatible API come up end to end. 
Genuine Vulkan/GPU offload and the real 30B model can only be confirmed on the 
mini PC itself (see `docs/hardware/gmktec-evo-x2.md`).

---

## Option 2 — manual, step by step

Useful if you want to poke around inside the VM yourself.

### 1. Download a cloud image

```bash
mkdir -p ~/.local/share/ai-server-qemu/rocky && cd $_
# Rocky Linux 9:
curl -LO https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
# Or Fedora Server (cloud base):
# curl -LO https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-42-1.1.x86_64.qcow2
```

### 2. Create cloud-init seed

```bash
cat > user-data <<'CLOUD_CFG'
#cloud-config
users:
  - name: ai
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    ssh_authorized_keys:
      - REPLACE_WITH_YOUR_KEY   # paste the content of ~/.ssh/id_ed25519.pub
ssh_pwauth: false
CLOUD_CFG
cat > meta-data <<'META_CFG'
instance-id: ai-server-verify-01
local-hostname: ai-server-test
META_CFG
cloud-localds seed.img user-data meta-data
```

### 3. Boot the VM

```bash
qemu-img create -f qcow2 -b Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 \
  -F qcow2 disk.qcow2 40G

qemu-system-x86_64 \
  -enable-kvm -cpu host -machine q35 \
  -m 12288 -smp 8 \
  -drive file=disk.qcow2,if=virtio,format=qcow2 \
  -drive file=seed.img,if=virtio,format=raw,media=disk \
  -virtfs local,path="$HOME/.cache/huggingface/hub/models--unsloth--Qwen3-8B-GGUF/snapshots/a6adef130ffb23ddaf1a62fec9dced968c9bc482",mount_tag=hostmodel,security_model=none,readonly=on \
  -netdev user,id=n0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080 \
  -device virtio-net-pci,netdev=n0 \
  -nographic
```

Wait for the login prompt (~1–2 min first boot).

### 4. Log in and run the automation

From another terminal on the host:

```bash
ssh -p 2222 -o StrictHostKeyChecking=no ai@127.0.0.1

# inside the VM:
sudo cloud-init status --wait        # let first-boot finish

# copy the repo in (from the host):
tar --exclude=.git -czf /tmp/ai-server.tgz -C ~/Documents/repos/gbrennon/ai-server .
scp -P 2222 /tmp/ai-server.tgz ai@127.0.0.1:/tmp/

# inside the VM:
mkdir -p ~/ai-server && tar -xzf /tmp/ai-server.tgz -C ~/ai-server

# stage the model (from the host): note Rocky cloud kernels have no 9p
# support, so copy the file over the SSH port-forward instead:
scp -P 2222 ~/.cache/huggingface/hub/models--unsloth--Qwen3-8B-GGUF/snapshots/a6adef130ffb23ddaf1a62fec9dced968c9bc482/Qwen3-8B-Q4_K_M.gguf \
  ai@127.0.0.1:/var/lib/llama.cpp/models/   # dir must be chown'ed to ai first

# and point the playbook at it (inside the VM):
sed -i 's|^llamacpp_model_file:.*|llamacpp_model_file: Qwen3-8B-Q4_K_M.gguf|' \
  ~/ai-server/group_vars/all.yml
```

Then **the actual test** — run the full automation:

```bash
cd ~/ai-server && sudo ./bootstrap.sh
```

### 5. Verify

Inside the VM (or from the host via the `8080` port-forward):

```bash
curl http://localhost:8080/health
# → {"status":"ok",...}

curl http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'
# → JSON with a real completion from Qwen3-8B
```

Also check:

```bash
systemctl status llama-server
sudo ss -tlnp | grep 8080
sudo firewall-cmd --list-ports          # should include 8080/tcp
```

The web UI is available at **http://localhost:8080/** from the host browser.

---

## What "working" means (acceptance checklist)

- [ ] `ansible-playbook site.yml --syntax-check` passes
- [ ] `bootstrap.sh` completes inside the VM with `failed=0` in the recap
- [ ] `systemctl is-active llama-server` → `active`
- [ ] `GET /health` → HTTP 200 `{"status":"ok"}`
- [ ] `POST /v1/chat/completions` returns a coherent answer
- [ ] Port `8080/tcp` open in firewalld
- [ ] Re-running `bootstrap.sh` is a no-op (idempotency: nothing `changed` on second run except the health check)

## Verified result (2026-09-03, Rocky Linux 9 VM, Qwen3-8B-Q4_K_M)

- Playbook recap: `ok=17 changed=10 failed=0`
- `GET /health` → `{"status":"ok"}`
- `POST /v1/chat/completions` → real completion from Qwen3-8B
  (~10.9 tok/s on 8 vCPUs, CPU backend)

Bugs found & fixed by this verification:

1. `-nographic` conflicts with `-daemonize` in QEMU → `-display none`
2. pip-installed ansible not on root's `PATH` in `bootstrap.sh`
3. undefined-variable crash in `roles/build` when the build stamp is missing
4. git "dubious ownership" on the `llamacpp`-owned source tree → added
   `safe.directory` config in the build role
5. missing `libcurl-devel` (llama.cpp server needs CURL)

## Cleanup

```bash
# kill the VM (the automated script does this itself):
kill $(cat ~/.local/share/ai-server-qemu/rocky/vm.pid)
# reclaim disk:
rm -rf ~/.local/share/ai-server-qemu
```
