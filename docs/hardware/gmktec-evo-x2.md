# GMKtec EVO X2 — Strix Halo setup

Hardware reference:

- AMD Ryzen AI Max+ 395 "Strix Halo", 16 Zen 5 cores
- Radeon 8060S RDNA 3.5 integrated GPU
- 128 GB unified LPDDR5X-8000 memory
- Up to approximately 96 GB available as UMA/iGPU memory

The profile uses Vulkan and full layer offload. See:

- [`profiles/gmktec-evo-x2.yml`](../../profiles/gmktec-evo-x2.yml)
- [GPU offload verification](gpu-offload.md)
- [Model selection](../models/selection.md)
- [Model switching](../models/switching.md)

## BIOS

Set **UMA Frame Buffer Size** to the maximum, normally 96 GB. This gives the
iGPU a large memory pool for Vulkan. Without it, inference may fall back to
slower system-RAM behavior.

Ensure the iGPU is enabled and the OS has network and SSH enabled.

## Operating system

Fedora Server or Rocky Linux 9/10 with a recent kernel is recommended. Install
the OS, create a sudo user, and enable SSH.

## Deploy

From the workstation:

```bash
./scripts/deploy-remote.sh \
  192.168.0.2 \
  gbrennon-local-ai \
  profiles/gmktec-evo-x2.yml
```

The profile configures Vulkan, `-ngl 99`, 16 threads, dynamic native model
context sizing, and the configured GGUF model.

For the complete installation flow, see
[deployment overview](../deployment/overview.md). For hardware validation, see
[the EVO X2 benchmark guide](../verification/evo-x2-benchmark.md).
