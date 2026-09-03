# Deploying to the mini PC — delivery-day runbook

This is the runbook for the day the mini PC arrives. Everything except the
OS install is automated by this repo.

---

## 0. Before delivery day (do it now)

- [ ] Pick the model the hardware can handle and set it in
      **`group_vars/all.yml`** (`llamacpp_model_url` / `llamacpp_model_file`).
      Rule of thumb for Q4_K_M GGUF: ~0.6 GB per billion parameters, plus
      ~1.5 GB for context.
      - 8 GB RAM mini PC  → 3B–4B model (e.g. Llama-3.2-3B, default)
      - 16 GB RAM mini PC → Qwen3-8B (already verified in QEMU), or 8B Llama
- [ ] If the mini PC has an **AMD/Intel GPU**: set `llamacpp_backend: vulkan`
      and add `-ngl 99` to `llamacpp_extra_args` (offloads all layers to GPU).
      For **NVIDIA**: install driver + CUDA toolkit first, then
      `llamacpp_backend: cuda`.
- [ ] Optionally verify your changes in QEMU: `./scripts/qemu-verify.sh rocky`

---

## 1. Install the OS (only manual step)

Flash **Fedora Server** or **Rocky Linux** (9/10) to a USB stick and install.
During install:

- create your user with admin (sudo) rights
- enable the SSH server if the installer offers it
- everything else can stay default

## 2. Get the repo onto the mini PC

**Option A — run everything on the mini PC:**

```bash
sudo dnf install -y git
git clone <your-repo-url>
cd ai-server
sudo ./bootstrap.sh
```

**Option B — deploy remotely from your current PC** (mini PC only needs SSH):

```bash
# 1) put the mini PC's IP or hostname in inventory.ini, e.g.:
#    mini-pc ansible_host=192.168.1.50 ansible_user=<your-user>
# 2) run:
ansible-galaxy collection install -r requirements.yml
ansible-playbook site.yml --limit mini-pc --ask-become-pass
```

## 3. What `bootstrap.sh` does automatically

1. installs Ansible + required collections
2. installs build tools, `libcurl-devel`, firewalld, etc.
3. creates the dedicated `llamacpp` system user
4. clones llama.cpp at the pinned version and **compiles it optimized for
   that machine's CPU** (or Vulkan/CUDA if configured)
5. opens port `8080` in firewalld
6. downloads the model (resumable; skipped if the file already exists)
7. installs and starts the hardened `llama-server` systemd service
8. waits until `GET /health` returns 200 and prints the final URLs

It is **idempotent**: change anything in `group_vars/all.yml` and re-run
`sudo ./bootstrap.sh` — only real changes trigger rebuilds/restarts.

## 4. Verify it works

```bash
curl http://localhost:8080/health
# → {"status":"ok",...}

curl http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'
```

From another device on the LAN: open `http://<mini-pc-ip>:8080/` (web UI) or
point any OpenAI-compatible client at
`http://<mini-pc-ip>:8080/v1/chat/completions`.

## 5. Day-2 operations

```bash
systemctl status llama-server
journalctl -u llama-server -f          # or tail -f /var/log/llama.cpp/llama-server.log
systemctl restart llama-server
sudo ./bootstrap.sh                    # apply config changes
```

## 6. Troubleshooting

| Symptom | Check |
|---|---|
| service won't start | `journalctl -u llama-server -e` (often out-of-memory → smaller model or `manage_swap: true`) |
| unreachable from LAN | `sudo firewall-cmd --list-ports` shows `8080/tcp`? |
| re-run fails at git | pull latest repo; the playbook handles `safe.directory` itself |
| wants GPU offload | confirm `llamacpp_backend` and `-ngl 99`; see `docs/qemu-verification.md` for tested config |
