# Documentation

Focused guides for deploying and operating the llama.cpp server.

## Start here

- [Deployment overview](deployment/overview.md) — install and first deployment
- [GMKtec EVO X2 hardware](hardware/gmktec-evo-x2.md) — Strix Halo setup
- [Model selection](models/selection.md) — choose a GGUF for the hardware
- [Model switching](models/switching.md) — change the running model
- [Context windows](models/context.md) — native context, KV cache, and 1M experiments

## Operations and verification

- [Operations](deployment/operations.md) — health checks, service control, troubleshooting
- [GPU offload](hardware/gpu-offload.md) — verify Vulkan acceleration
- [Strix Halo performance](performance/strix-halo.md) — tuning and benchmarks
- [EVO X2 verification](verification/evo-x2-benchmark.md) — hardware and inference benchmark
- [QEMU verification](verification/qemu.md) — test the automation without hardware
- [Rocky PXE installation](installation/rocky-pxe.md) — network installation

The repository configuration remains in [`group_vars/all.yml`](../group_vars/all.yml)
and [`profiles/`](../profiles/).
