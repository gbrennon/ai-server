# Downloaded model verification

Measured results for the GGUF files already downloaded on the GMKtec host
(`~/.cache/localnar/models`). This complements the estimates in
[model selection](selection.md) with real load and inference data.

## Target hardware (measured)

- APU: AMD Ryzen AI MAX+ 395 (Strix Halo), Radeon 8060S iGPU (`gfx1151`).
- Memory: ~96 GiB carved to VRAM/UMA, ~30 GiB system RAM, ~128 GiB unified total.
- Stack: ROCm 7.14, llama.cpp HIP build `b1-f072b10`.
- Idle GPU baseline: ~14 W, 41 C, VRAM 23% held by the production server.

## Results

| Model (GGUF) | Size | Fit | Verified |
|---|---:|---|---|
| `unsloth/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M` | 17.3 GB | Yes | In service; tool calls verified |
| `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-IQ3_XXS` | 9.5 GB | Yes | Retired; mangled tool args at 3-bit |
| `pfeifferj/GLM-5.3-Flash-GSQ-RCO-3.0bit` | 110 GB | No | Skipped, see below |
| `huihui-ai/DeepSeek-V4-Flash-Q4-mxfp4` | 146 GB | No | Skipped, see below |

## Qwen3.8-27B-GSQ-RCO IQ3_XXS (fits, tested)

Dense 27B, quantized to IQ3_S (3.4375 bpw), launched with full GPU offload
(`-ngl 999`, `-c 4096`, `-n 128`, `-t 8`) on the iGPU.

### Performance

| Metric | Value |
|---|---:|
| Prompt processing (prefill) | 99.3 tok/s |
| Generation (decode) | 16.2 tok/s |
| Context used | 4096 tokens |
| Quantization | IQ3_S, 3.4375 bpw |
| Cold-start load (first run) | ~60-90 s (kernel JIT) |
| Warm load | fast (JIT cached) |

### Resource consumption (under load)

| Metric | Idle | Under load | Delta |
|---|---:|---:|---:|
| VRAM used (% of 96 GiB) | 23% | 34% | +11% (~10.5 GB) |
| GPU utilization | ~1% | 100% | pegged |
| Package power | ~14 W | ~70 W | +56 W |
| Edge temperature | 41 C | ~53 C (peak 58 C) | +12 C |
| SCLK | idle | 2900 MHz | boost |

### Notes

- Weights plus KV cache fit comfortably in the VRAM carve with large headroom
  (only ~34% of 96 GiB used), leaving room for bigger context or batching.
- Power (~70 W) stays well under any cap and temps peak ~58 C: thermally safe
  for sustained serving.
- 16.2 tok/s decode is usable for a 27B dense model on an iGPU; prefill is
  fast at ~99 tok/s.
- Cold first run stalls ~60-90 s on rocBLAS/Tensile kernel JIT for `gfx1151`.
  A warm, already-running server does not pay this cost.
- A second concurrent GPU process serializes on the single iGPU queue, so run
  benchmarks against an otherwise idle GPU.

## Qwen3-Coder-30B-A3B-Instruct Q4_K_M (in service, tested)

Sparse MoE, 128 experts, 8 used per token (`30B-A3B`), ~30.53B total / ~3.3B
active, `Q4_K_M` at 4.86 BPW (17.28 GiB), launched at the full 262144 native
context with `--jinja` so llama.cpp parses the model's native tool-call format.

### Performance (live `/v1/chat/completions` timings)

| Metric | Value |
|---|---:|
| Prompt processing (prefill) | ~995 tok/s |
| Generation (decode) | ~38.8 tok/s |
| Context served | 262144 tokens |
| Quantization | `Q4_K_M`, 4.86 BPW |

Decode is roughly 2.4x the retired 3-bit dense 27B (~13.3 tok/s) because only
~3.3B parameters run per token.

### Tool-calling (the reason for the switch)

- Direct tools request returned `finish_reason: tool_calls` with two parallel
  calls whose arguments were valid JSON: `write_file` with a properly escaped
  `content` string, and `run_shell` with `{"command":"cargo","args":["test"]}`
  -- the string array serialized as a real JSON array, the exact thing the
  3-bit IQ3 mangled.
- Agentic `omp` loop (write file, shell-verify, report) completed cleanly.
- Agentic `omp` git loop staged only the requested path, committed with `-m`,
  and left the other file modified and unstaged -- the selective `git add`
  plus `git commit` scenario that previously failed.
- No `--reasoning off` workaround is needed; the coder-instruct model calls
  tools directly instead of rambling.

### Storage note

The managed model dir (`/var/lib/llama.cpp/models`) is on the small 70 GB root
filesystem, so the 17.3 GB GGUF lives on the 1.8 TB `/home` volume and is
exposed to the service through a symlink in the managed dir, matching the
pre-existing pattern used for the `2507` model.

## GLM-5.3-Flash 3.0bit (110 GB, skipped)

- Exceeds the ~96 GiB VRAM carve, so full GPU offload is impossible.
- It could only run by spilling into the ~30 GiB system RAM via GTT, which
  causes heavy thrashing and is not a viable serving configuration here.

## DeepSeek-V4-Flash Q4 mxfp4 (146 GB, skipped)

- Exceeds the ~128 GiB total unified memory, so it cannot be fully resident at
  all on this host.
- Running it requires more RAM or multi-node hardware; out of scope for this box.
