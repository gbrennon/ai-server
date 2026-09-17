# Performance Tuning — Strix Halo (Ryzen AI Max+ 395 / Radeon 8060S)

This documents the tuning applied to the EVO X2 deployment and, crucially,
*why*. It is the result of an end-to-end investigation on the live box.

## TL;DR

| Change | Where (Ansible) | Effect |
|---|---|---|
| Track a recent llama.cpp build | `llamacpp_version: master` (`group_vars/all.yml`) | **~16.8x** faster prompt processing for MoE models |
| `--flash-attn on` (was bare `--flash-attn`) | `profiles/gmktec-evo-x2.yml` | Required by recent builds (bare flag now errors) |
| `--ctx-size 262144` (was 32768) | `profiles/gmktec-evo-x2.yml` | Full native 256K context (uses ~24 GB KV at fp16) |
| Vulkan build deps | `roles/build/defaults/main.yml` | `spirv-headers-devel` + `glslang` (configure fails without them) |
| SELinux relabel of install dir | `roles/build/tasks/main.yml` | Prevents `status=203/EXEC` under enforcing SELinux |
| GPU performance mode | `roles/performance/` + `gpu_performance_mode: true` | Pins iGPU to max clock at boot (lower request latency) |

## The real bottleneck: llama.cpp build recency, not hardware

Symptom: long-context requests felt slow. Measured on the live server:

```text
prompt processing (prefill): ~74 t/s
token generation:           ~66 t/s
```

Prefill being roughly **equal** to generation is the tell-tale sign of a
broken batched-matmul path. Healthy hardware does prefill **5–15x faster**
than generation because prefill is compute-bound and parallelizable.

Root cause: the deployment pinned llama.cpp **`b5446` (May 2025)**, whose
**Vulkan MoE prompt-processing was broken**. Rebuilding from current `master`
fixed it outright:

```text
pp512  75  -> 1256 t/s   (16.8x)
pp2048 74  -> 1185 t/s   (15.9x)
tg128  66  ->   89 t/s   (1.34x)
```

Verified good commit: `05f2dcf` (2026-09-17).

## What is NOT the bottleneck: power / "performance mode"

A sustained-prefill measurement showed the iGPU already runs flat-out:

```text
GPU busy:  100%
GPU clock: ~2899 MHz  (max DPM state)
GPU power: ~45 W      (of a 120 W budget)
```

At max clock and 100% busy while using only ~45 W, the GPU is **compute-kernel
bound**, not power/clock bound. Therefore:

- `ryzenadj` / raising TDP does **not** help throughput here (the chip won't
  draw more power because the kernels can't keep the ALUs fed).
- This mini PC's firmware exposes **no** ACPI `platform_profile` (loading
  `amd_pmf` yields nothing), so that "performance mode" mechanism is a dead end.

The one useful knob is `power_dpm_force_performance_level=high`, which pins the
iGPU to top clock so it doesn't idle at ~600 MHz between requests. That only
improves **latency ramp** for bursty serving, not peak throughput. It is
installed by the `performance` role when `gpu_performance_mode: true`.

## KV cache memory at 256K context

At fp16, KV cache for Qwen3-30B-A3B is ~96 KB/token → ~24 GB at 262144 tokens.
With the 96 GB UMA carve-out and the ~18 GB model, ~55 GB VRAM remains free.
To reduce KV memory (e.g. for larger/heavier models), add quantized KV cache:

```yaml
llamacpp_extra_args: "-ngl 99 --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0"
```

## Gotchas encountered (baked into the roles)

1. **Vulkan build deps** — recent llama.cpp `CMakeLists` does
   `find_package(SPIRV-Headers)` and wants a glslang validator. On Rocky 10:
   `dnf install spirv-headers-devel glslang`.
2. **`--flash-attn` now takes a value** (`on|off|auto`); the bare flag makes
   `llama-server` print usage and exit (systemd shows it restart-looping).
3. **SELinux** — a build tree copied from `$HOME` carries `home_t` and yields
   `Permission denied` (`status=203/EXEC`) when systemd tries to exec it.
   Building in place under `/opt` is fine; `restorecon -RF` makes it robust.

## Optional next step: ROCm/hipBLASLt backend

Vulkan MoE prefill is now healthy (~1250 t/s). A ROCm/HIP build
(`-DGGML_HIP=ON` + hipBLASLt, ROCm ≥ 6.4 for gfx1151) can push prefill even
higher, at the cost of a heavier toolchain install. Not currently wired into
the playbook.
