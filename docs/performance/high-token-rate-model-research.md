# High-token-rate model research

Research date: 2026-10-30. Target hardware is the GMKtec EVO-X2 /
Ryzen AI Max+ 395 / Radeon 8060S (`gfx1151`) with 128 GB unified memory.
Rates below are decode rates unless stated otherwise; they are not
interchangeable with prompt throughput or client end-to-end rates.

## Local evidence

The production server uses `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` on
ROCm/HIP with four 65,536-token slots and a 262,144-token total context.
The measured short direct decode was about 70 tok/s; long agent requests were
much lower because prompt processing and long-context attention dominate. A
prior controlled candidate (`--parallel 1`, `--ctx-size 65536`) measured
70.177 tok/s short versus 70.054 baseline and 34.062 tok/s long versus
34.079 baseline, so it was rejected.

The remote model directory already contains Qwen3.8-27B-UD-Q4_K_M,
Qwen3.8-9B-Q4_K_M, Qwen3-14B-Q4_K_M, and
Qwen3.8-27B-GSQ-RCO-IQ3_XXS. The root filesystem had about 17 GB free
during the check; do not download large Strata packs until storage is
expanded or a model is removed.


## Qwen3 30B-A3B Q4_K_M: ROCm measurement

Primary published benchmark:
<https://github.com/visorcraft/strix-halo-llm-perf/blob/main/BENCHMARKS.md>

On the same EVO-X2 / Radeon 8060S class hardware, the published
Qwen3 30B-A3B MoE Q4_K_M result used Vulkan/RADV and measured:

- 79.89 tok/s generation at 85 W;
- 86.07 tok/s generation at 120 W;
- 975.70-1,141.78 tok/s prompt processing.

The command was `llama-bench -m <model> -ngl 99 -p 512 -n 128`. This is
synthetic `tg128` decode, not long-context agent throughput. The model has
30B total parameters but only about 3B active per token, which explains its
strong raw rate.

The official Q4_K_M file was downloaded to the target and verified against
SHA-256
`0d003f6662faee786ed5da3e31b29c978de5ae5d275c8794c606a7f3c01aa8f5`.
It was benchmarked on the existing ROCm build without replacing production.
With `llama-bench` build `3c809f4 (1)`, `-lm dio`, `-fa on`, `-ngl 99`,
`-p 512`, `-n 128`, `-r 3`, `-b 2048`, and `-ub 512`, it measured:

| Model | pp512 | tg128 |
| --- | ---: | ---: |
| Qwen3 30B-A3B Q4_K_M | **1,915.60 ± 33.12** | **72.53 ± 7.27** |

A separate non-isolated run was also made against the production
`Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` path and printed 77.52 ± 0.01
tok/s for `tg128`. The production model remained resident during both runs,
so that figure is not a repository-grade controlled baseline; retain the
earlier approximately 70 tok/s measurement as the comparable current-model
reference. The candidate did not demonstrate an improvement over the
existing model, so it is not a justified production swap for token rate
alone.

## Exact-hardware ROCm evidence from another EVO-X2 repository

<https://github.com/pablo-ross/strix-halo-gmktec-evo-x2>

That repository reports about 71 tok/s for
`Qwen3-Coder-30B-A3B-Instruct-Q4_K_M` with ROCm, full offload, `--no-mmap`,
flash attention, 8K context, and two parallel slots. Its later Qwen3.8-27B
evaluation reports only 10.88 tok/s raw and 14.27 tok/s with MTP on ROCm,
and rejects the model swap because the dense model moves substantially more
data per token. These are external historical measurements, but they support
the local conclusion: the existing coder MoE already has the desired raw
decode profile, while long-agent latency is a separate prompt/context issue.

## Qwen3.8-Flash-Next, MTP-capable

Primary benchmark:
<https://github.com/ggml-org/llama.cpp/discussions/28512>

On a Radeon 8060S with Vulkan/RADV, a real-conversation replay reported:

- no speculation: about 27 tok/s;
- tuned MTP stack: 30.1-58.1 tok/s depending on workload and context;
- file rewrite at 8K: 55.4 tok/s, or 63.2 with `n-max 6`;
- new code at 32K: 37.8 tok/s;
- file rewrite at 32K: 48.5 tok/s, or 55.2 with `n-max 6`;
- real-agent median: 33 tok/s, up from 25 tok/s;
- fresh 18K prompt TTFT: 67 s to 44 s.

The report used the Qwen3.8-Flash-Next UD-IQ4_XS pack, a matching Q8 MTP
draft head, Vulkan/RADV, and a tuned `drluoto/llama.cpp` branch. It is not a
drop-in replacement for the current Qwen3-Coder GGUF. The report warns that
`n-max 6` is workload-sensitive and can hurt prose; default draft length was
3.

Resources:

- <https://github.com/drluoto/llama.cpp/tree/strix-halo-vulkan>
- <https://huggingface.co/drluoto/Qwen3.8-Flash-Next-MTP-GGUF>
- <https://github.com/ggml-org/llama.cpp/discussions/27950>

## Qwen3.6-35B-A3B

Primary Strata benchmark:
<https://github.com/Niko1221/Strata/issues/3398>

On a 128 GB Strix Halo system, Strata 0.1.45 measured the UD-Q6_K_XL model
at:

- chat decode: 50.5 tok/s;
- agent decode: 38.0-38.1 tok/s;
- 4K/16K/32K prompt processing: about 579/483/373 tok/s;
- 32K agent TTFT: about 85 s.

The report tested Windows/HIP, `--max-context 262144`, int8 KV, and Strata's
native path. MTP changes were within noise for this particular qwen3.6 run,
so the 50.5 tok/s figure should not be attributed to MTP. Strata's official
model page lists Qwen3.6 MTP GGUFs and 22.9 GB UD-Q4_K_XL, 32.6 GB
UD-Q6_K_XL, and 37.8 GB Q8_0 sizes:
<https://github.com/Niko1221/Strata/blob/main/docs/MODELS.md>.

This is a strong published decode candidate, but its agent cache behavior was
poor in the same report: 0% cache reuse and roughly 30K tokens reread per
session. That matters for Pi/OMP workloads.

## Qwen3.8-27B with native MTP

Primary benchmark:
<https://github.com/yandaq/qwen3.8-27b-strix-halo/blob/main/benchmark.md>

On the same EVO-X2 class hardware with Vulkan/RADV and a built-in MTP head,
Qwen3.8-27B Q4_K_M averaged 26.47 tok/s over prose/code/JSON;
UD-Q4_K_XL averaged 26.26 tok/s. Code was the fastest case at about
29.5 tok/s. The benchmark used 262K context, thinking off,
`--spec-draft-n-max 4`, and proper chat completions. It explicitly rejects
fake higher rates from degenerate output.

This is a useful locally relevant model because the host already has Qwen3.8
27B files, but its published rate is lower than the current short
Qwen3-Coder rate. It may be useful for quality/context, not maximum raw
decode.

## Smaller Qwen3-14B or Qwen3.8-9B

The host already has Qwen3-14B-Q4_K_M and Qwen3.8-9B-Q4_K_M. A smaller model
is not automatically faster on this APU: the verified benchmark above shows
Qwen3 30B-A3B MoE at 79.89 tok/s, while Qwen2.5-Coder 7B Q6_K measured only
35.65 tok/s in the same benchmark. Treat the smaller models as quality or
memory alternatives, not as proven faster choices.

Qwen3-14B does not contain a native MTP head; ordinary llama.cpp speculative
decoding can pair it with a Qwen3-0.6B draft model. No directly comparable
Strix-Halo rate for that setup was found.

## Strata resources

- Install: <https://github.com/Niko1221/Strata/blob/main/docs/INSTALL.md>
- Strix Halo guide: <https://github.com/Niko1221/Strata/blob/main/docs/STRIX_HALO.md>
- Model selection: <https://github.com/Niko1221/Strata/blob/main/docs/MODELS.md>
- Benchmark protocol:
  <https://github.com/Niko1221/Strata/blob/main/docs/COMMUNITY_BENCHMARKS.md>

Strata's model families are Qwen3.8-Flash-Next, Qwen3.6-35B-A3B, and related
packs; it is not a transparent backend swap for the existing
Qwen3-Coder-30B service. Its published 70.9-77.3 tok/s community result was
on 2x Titan RTX 24 GB, while the 2x Quadro RTX 4000 8 GB report was 18-23
tok/s. A friend's claimed 70 tok/s on 8 GB remains unverified without exact
model, quant, backend, context, MTP, and decode-vs-prefill methodology.

## Recommended ranking for this host

1. **Best verified ROCm choice for the current objective:** the existing
   Qwen3-Coder-30B-A3B-Instruct Q4_K_M. The local prior measurement and the
   exact-hardware external benchmark both put short decode around 70-71
   tok/s, with the coding checkpoint already loaded and validated in the
   production path.
2. **Downloaded ROCm candidate:** Qwen3 30B-A3B Q4_K_M. Its local `tg128`
   result was 72.53 ± 7.27 tok/s, but it did not demonstrate a reliable gain
   over the current model and has not been tested for coding/tool quality.
3. **Highest published synthetic rate, different backend:** Qwen3 30B-A3B
   Q4_K_M on Vulkan/RADV at 79.89-86.07 tok/s on EVO-X2. This is not a
   decision criterion while the deployment remains on ROCm.
4. **Best published coding/agent candidates:** Qwen3.8-Flash-Next with MTP
   or Qwen3.6-35B-A3B, but their reported real-agent rates and cache behavior
   do not justify replacing the current coding model for speed alone.

The Qwen3 30B-A3B file is downloaded and hash-verified, but it was not
deployed and no production configuration was changed. The next useful
optimization is an isolated, apples-to-apples agent workload measurement
against the current service, focusing on context size, prompt processing,
and cache reuse rather than another unvalidated model swap.
