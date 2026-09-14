# Deploying to the GMKtec Evo X2 (Ryzen AI Max+ 395)

Hardware reference for this guide:

- **CPU:** AMD Ryzen AI Max+ 395 "Strix Halo" — 16 Zen 5 cores
- **GPU:** AMD Radeon 8060S iGPU (RDNA 3.5) sharing the
- **Memory:** 128 GB unified LPDDR5X-8000 (up to ~96 GB usable as VRAM)

The automation uses the **Vulkan** backend with full GPU offload (`-ngl 99`),
which is the simplest and best-supported path for this iGPU — no ROCm setup
required. See `profiles/gmktec-evo-x2.yml` for the applied settings.

---

## 1. BIOS settings (do this first — critical for GPU performance)

Power on and press **Del/Esc** to enter the BIOS:

1. **UMA Frame Buffer Size** → set to the **maximum (96 GB)**.
   By default the iGPU only gets a few hundred MB of dedicated VRAM. With the
   maximum UMA, Vulkan sees a large dedicated pool and the model lives in
   fast on-package LPDDR5X. Without this, inference silently falls back to
   system-RAM behaviour and is much slower.
2. Enable the **AMD GPU / iGPU** (should be on by default).
3. Make sure the **SSH server** will be reachable: install the OS with network
   + SSH enabled.

> Fedora 41+ / Rocky 9+ kernels support Strix Halo out of the box. Use a
> recent image — anything from 2025 onward is fine.

## 2. Install the OS

Only manual step. Flash **Fedora Server** or **Rocky Linux** to a USB stick,
install, create your sudo user, enable SSH.

## 3. Deploy from your workstation (one command)

On your PC (where this repo lives, with `ansible` installed):

```bash
# one-time: key-based sudo on the mini PC
ssh-copy-id <user>@<mini-pc-ip>
ssh <user>@<mini-pc-ip> "echo '<user> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-<user>"

# deploy (builds llama.cpp with Vulkan, downloads ~18.6 GB model, starts service)
./scripts/deploy-remote.sh <mini-pc-ip> <user> profiles/gmktec-evo-x2.yml
```

The script:

1. checks SSH + sudo + dnf on the target,
2. runs the playbook from your workstation (the mini PC needs **no Ansible**,
   only `python3` which both distros ship),
3. applies the Evo X2 profile (Vulkan, `-ngl 99`, 32k context, 16 threads,
   Qwen3-30B-A3B-Instruct),
4. waits for `/health` and sends a test chat completion.

Before you power on the mini PC, you can dry-run this exact flow locally:

```bash
make qemu-verify-gmktec      # runs the EVO X2 profile in a QEMU VM
```

It can't exercise the GPU (QEMU has none) but proves the profile, playbook,
service, and API work end to end. See [docs/qemu-verification.md](qemu-verification.md).

First run takes ~15–30 min (compile + 18.6 GB model download). Subsequent
runs are incremental — edit the profile and re-run the same command.

## 4. Verify

```bash
curl http://<mini-pc-ip>:8080/health
# → {"status":"ok"}

# from the mini PC: confirm GPU offload actually engaged
ssh <user>@<mini-pc-ip> \
  'grep -iE "vulkan|offload|layers" /var/log/llama.cpp/llama-server.log | head'
# expect: "offloaded 48/48 layers to GPU"

# quick benchmark
curl http://<mini-pc-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Count to 10"}],"max_tokens":100}'
```

Check `timings` in the response: on the 8060S with Qwen3-30B-A3B Q4 you should
see roughly **20–40 tokens/s** (it's a MoE — only ~3B active params/token).

OpenAI-compatible endpoint for any client:
`http://<mini-pc-ip>:8080/v1/chat/completions` — Web UI at
`http://<mini-pc-ip>:8080/`.

## 5. Choosing bigger/smaller models (128 GB unified memory!)

Edit the two `llamacpp_model_url` / `llamacpp_model_file` lines in
`profiles/gmktec-evo-x2.yml`, then re-run `deploy-remote.sh`:

| Model | Size | Fits? | Notes |
|---|---|---|---|
| Qwen3-30B-A3B-Instruct Q4_K_M (default) | ~18.6 GB | ✅ | fast MoE, best all-rounder |
| Qwen3-Coder-30B-A3B Q4_K_M | ~18.6 GB | ✅ | coding variant |
| Llama-3.3-70B Q4_K_M | ~42 GB | ✅ | dense, slower (~5–8 tok/s) |
| gpt-oss-120b (MXFP4) | ~63 GB | ✅ | multi-part GGUF — download the 3 parts and `cat` them together on the mini PC |
| GLM-4.5-Air Q4 | ~192 GB | ❌ | use Q3 (~110 GB) only if you also shrink context |

Multi-part GGUF recipe (on the mini PC):

```bash
cat gpt-oss-120b-mxfp4-0000*-of-00003.gguf > /var/lib/llama.cpp/models/gpt-oss-120b-mxfp4.gguf
```

then point `llamacpp_model_file` at `gpt-oss-120b-mxfp4.gguf` and re-run the
deploy (download is skipped when the file exists).

## 6. Troubleshooting

| Symptom | Fix |
|---|---|
| `offloaded 0/48 layers` in log | BIOS UMA not set to 96 GB; Vulkan is falling back to system RAM |
| Vulkan init errors | `dnf install vulkan-tools && vulkaninfo --summary` — check the 8060S is listed |
| OOM at model load | lower `llamacpp_ctx_size`, or pick a smaller quant |
| Very slow generation | confirm `-ngl 99` in `llamacpp_extra_args` and that the log shows GPU offload |
| service restarts repeatedly | `journalctl -u llama-server -e`; likely model too big for the UMA pool |
