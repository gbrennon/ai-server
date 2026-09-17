# GMKtec EVO X2 Infrastructure Verification and Benchmarking

This runbook verifies that the EVO X2 exposes the expected Ryzen AI Max+ 395,
128 GB unified memory, and Radeon 8060S GPU before measuring llama.cpp.
Commands are run remotely over SSH from the workstation.

Set the connection variables once in the workstation shell:

```bash
export EVO_USER=gbrennon-local-ai
export EVO_IP=192.168.0.2
export MODEL=/var/lib/llama.cpp/models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf
```

## 1. Verify SSH and operating system

```bash
ssh "$EVO_USER@$EVO_IP" 'hostnamectl; cat /etc/os-release; uname -r'
ssh "$EVO_USER@$EVO_IP" 'systemctl is-enabled sshd; systemctl is-active sshd'
```

The system should report Rocky Linux 10.2 and an active SSH server.

## 2. Verify CPU and memory

```bash
ssh "$EVO_USER@$EVO_IP" 'lscpu | grep -E "Architecture|Model name|CPU\(s\)|Core\(s\) per socket|Thread\(s\) per core|NUMA node\(s\)"'
ssh "$EVO_USER@$EVO_IP" 'free -h; nproc'
```

Expected CPU characteristics:

- AMD Ryzen AI Max+ 395 with Radeon 8060S
- 16 physical cores
- 32 logical CPUs
- One NUMA node
- Approximately 128 GB total memory

If BIOS reserves a large UMA Frame Buffer for the iGPU, Linux may report only
about 30–32 GiB available to the OS. That is expected for a 96 GiB UMA
reservation; verify the complete hardware allocation in BIOS as well as with
`free -h`.

`lscpu` identifies the processor but does not prove that the Radeon GPU is
usable by Vulkan.

## 3. Verify the GPU and kernel driver

```bash
ssh "$EVO_USER@$EVO_IP" 'sudo lspci -nnk | grep -A4 -Ei "vga|display|3d"'
ssh "$EVO_USER@$EVO_IP" 'sudo ls -l /dev/dri; sudo dmesg | grep -i amdgpu | tail -30'
```

Look for the AMD graphics device, the `amdgpu` kernel driver, and a render node
such as `/dev/dri/renderD128`. If `lspci` is missing, install `pciutils`. If
`dmesg` is denied, run it through `sudo`.

For Strix Halo, missing firmware messages such as
`psp_14_0_1_toc.bin`, `gc_11_5_1_pfp.bin`, or `dcn_3_5_1_dmcub.bin` mean the
AMD firmware package is missing from the boot initramfs. Install
`amd-gpu-firmware`, rebuild the initramfs, and reboot before continuing:

```bash
ssh -t "$EVO_USER@$EVO_IP" \
  'sudo dnf install -y amd-gpu-firmware pciutils && \
   sudo dracut -f /boot/initramfs-$(uname -r).img $(uname -r) && \
   sudo reboot'
```

## 4. Verify Vulkan is hardware accelerated

Install the diagnostic tools if necessary:

```bash
ssh -t "$EVO_USER@$EVO_IP" \
  'sudo dnf install -y vulkan-tools amd-gpu-firmware pciutils'
```

Check the Vulkan device:

```bash
ssh "$EVO_USER@$EVO_IP" \
  'sudo vulkaninfo --summary 2>/dev/null | grep -Ei "device|driver|gpu|radeon|llvmpipe"'
```

A correct result identifies an AMD Radeon device and its hardware driver.
It may also list `llvmpipe` as a fallback device; that is harmless as long as
llama.cpp selects the Radeon/RADV device. This is a failure if it is the only
available device, or if llama.cpp selects it:

```text
llvmpipe (LLVM ...)
Warning: Device type is CPU
```

`llvmpipe` is software Vulkan running on the CPU. It can still cause llama.cpp
to print `offloaded 49/49 layers to GPU`, but it is not Radeon acceleration.

## 5. Verify service-user permissions

The llama.cpp service runs as `llamacpp`. Check its device groups and access:

```bash
ssh "$EVO_USER@$EVO_IP" 'id llamacpp; getent group render; getent group video'
ssh "$EVO_USER@$EVO_IP" \
  'sudo ls -l /dev/dri; sudo -u llamacpp test -r /dev/dri/renderD128 && echo render-node-readable || echo render-node-not-readable'
```

If the render node exists but is not readable, add the service user to the
usual graphics groups and restart the service:

```bash
ssh -t "$EVO_USER@$EVO_IP" \
  'sudo usermod -aG render,video llamacpp && sudo systemctl restart llama-server'
```

Re-check `vulkaninfo` and the llama.cpp log after restarting. Group changes
only affect newly started processes.

## 6. Verify llama-server and model loading

```bash
ssh "$EVO_USER@$EVO_IP" 'systemctl is-enabled llama-server; systemctl is-active llama-server'
curl -fsS "http://$EVO_IP:8080/health"
ssh "$EVO_USER@$EVO_IP" \
  'grep -iE "ggml_vulkan:|using device|offloaded.*layers|model loaded|llvmpipe" /var/log/llama.cpp/llama-server.log | tail -30'
```

Good evidence contains both:

```text
AMD Radeon ...
offloaded 49/49 layers to GPU
model loaded
```

Do not treat this combination as successful hardware acceleration:

```text
llvmpipe ...
offloaded 49/49 layers to GPU
```

## 7. Benchmark safely through the running API

This method does not load a second model. It measures the production server
through SSH, while the request executes on the EVO X2:

```bash
ssh "$EVO_USER@$EVO_IP" 'curl -fsS http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '\''{"model":"llama","messages":[{"role":"user","content":"Explain briefly why GPU acceleration improves LLM inference."}],"temperature":0,"max_tokens":256}' \
  | tee /tmp/evo-x2-benchmark.json
```

Inspect the timing fields:

```bash
jq '{usage, timings}' /tmp/evo-x2-benchmark.json
```

Important fields:

- `prompt_per_second`: prompt processing speed
- `predicted_per_second`: generated-token speed
- `predicted_n`: number of generated tokens

Run three times and compare the second and third runs:

```bash
for run in 1 2 3; do
  echo "--- run $run ---"
  ssh "$EVO_USER@$EVO_IP" 'curl -fsS http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '\''{"model":"llama","messages":[{"role":"user","content":"Count from 1 to 100 and explain the result."}],"temperature":0,"max_tokens":256}' \
    | jq '{completion_tokens: .usage.completion_tokens, timings: .timings}'
done
```

## 8. Run llama-bench directly

Confirm the CLI is installed:

```bash
ssh "$EVO_USER@$EVO_IP" 'command -v llama-bench; llama-bench --help | head -20'
```

Direct benchmarking loads another model context, so stop the production
service first:

```bash
ssh -t "$EVO_USER@$EVO_IP" '
set -e
sudo systemctl stop llama-server
trap '\''sudo systemctl start llama-server'\'' EXIT

# Run as the same account as the systemd service so GPU permissions match.
sudo -u llamacpp /usr/local/bin/llama-bench \
  --model /var/lib/llama.cpp/models/Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf \
  --n-gpu-layers 99 \
  --n-prompt 512 \
  --n-gen 128 \
  --repetitions 3 \
  --output md
'
```

Options:

- `--n-gpu-layers 99`: offload all possible layers
- `--n-prompt 512`: process a 512-token prompt
- `--n-gen 128`: generate 128 tokens
- `--repetitions 3`: repeat each test three times
- `--output md`: print the benchmark table as Markdown

The long option names match the current `llama-bench --help` output. Do not
run this benchmark until Vulkan identifies the Radeon device; otherwise the
results measure `llvmpipe` CPU rendering. The `EXIT` trap starts
`llama-server` again even if `llama-bench` fails.

Use the reported generation tokens/second to compare models or driver
changes. The service restarts automatically when the benchmark exits.

### Reference results (Qwen3-30B-A3B-Instruct-2507 Q4_K_M, Radeon 8060S / RADV)

The llama.cpp build version dominates prompt-processing (prefill) speed:

```text
# llama.cpp b5446 (May 2025) — BROKEN MoE Vulkan prefill:
pp512:   ~75 t/s
tg128:   ~66 t/s          # prefill == generation is the bug signature

# llama.cpp master (commit 05f2dcf, 2026-09-17) — FIXED:
pp512:  ~1256 t/s         # ~16.8x faster prefill
pp2048: ~1185 t/s
tg128:    ~89 t/s
```

If you see prefill (`prompt_per_second`) roughly equal to generation
(`predicted_per_second`), you are on a stale build — rebuild from a recent
`llamacpp_version` (see group_vars/all.yml). The GPU is NOT the bottleneck:
under load it already boosts to ~2900 MHz at 100% busy while only drawing
~45 W of its 120 W budget, so raising TDP / "performance mode" does not help
throughput (it only reduces idle-to-load ramp latency). See
[../performance/strix-halo.md](../performance/strix-halo.md).

## 9. Record a benchmark result

Record these values together; a tokens/second number without hardware context
is difficult to compare:

- Rocky Linux and kernel version
- llama.cpp version
- Model filename and quantization
- Vulkan device name and driver
- Total memory and context size
- GPU layer count
- Prompt tokens/second
- Generation tokens/second
- Number of benchmark repetitions

## 10. Final health check

```bash
ssh "$EVO_USER@$EVO_IP" 'systemctl is-enabled llama-server; systemctl is-active llama-server'
curl -fsS "http://$EVO_IP:8080/health"
```

Expected output is:

```text
enabled
active
{"status":"ok"}
```
