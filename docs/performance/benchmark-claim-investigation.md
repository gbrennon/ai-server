# Investigating 70 tok/s benchmark claims

Research date: 2026-10-30.

This note checks public claims of approximately 70 generated tokens per second,
especially claims involving Strix Halo, the GMKtec EVO-X2, Strata, and an
"8 GB GPU".

## Executive verdict

**A 70 tok/s result is real under a narrow benchmark definition.** Public
results on a GMKtec EVO-X2 / Ryzen AI Max+ 395 / Radeon 8060S report about
70 tok/s for Qwen3-Coder-30B-A3B Q4_K_M with full offload and very short
prompts. That agrees with this repository's local short decode measurement.

That does **not** establish 70 tok/s for a real coding-agent session. Long
prompts, KV-cache attention, prompt processing, sampling, transport, client
work, reasoning tokens, and cache state all change the result. The local
long-context measurements are materially lower, as expected.

The claim "an 8 GB GPU gets 70 tok/s" is **unverified and probably misleading
without more details**. The closest Strata report using two 8 GB Quadro RTX
4000 cards measured about 18--23 generated tok/s. The Strata report near
70 tok/s used two 24 GB Titan RTX cards. A single 8 GB card could reach 70
with a smaller model, another quantization, speculative decoding, or a
different metric, but the reviewed evidence does not prove that claim.

## Metric definitions

The phrase "70 tok/s" is ambiguous unless the timing boundary is stated:

- **Decode rate:** generated tokens divided by decode time. This is normally
  `tg128` or `predicted_per_second`.
- **Prompt rate:** input tokens processed during prefill. It can be hundreds
  or thousands of tok/s and is not a generation rate.
- **End-to-end rate:** output tokens divided by total request time, including
  prompt processing, queueing, sampling, network, and client work.
- **Concurrent aggregate:** output from several requests divided by round wall
  time. It is not the single-request rate.

`llama-bench` reports repeated average `pp` (prompt processing) and `tg` (text
generation) rates. Its documentation states that tokenization and sampling
are excluded. A `tg128` result is therefore a valid raw engine measurement,
but not a complete application measurement.

Source: [llama.cpp llama-bench](https://github.com/ggml-org/llama.cpp)

## Evidence summary

| Evidence | Reported decode result | Verdict |
| --- | --- | --- |
| EVO-X2, Qwen3-Coder, ROCm, short HTTP prompts | 68.09--71.00 tok/s | Credible narrow result |
| EVO-X2, Qwen3 30B-A3B, Vulkan, `tg128` | 79.89--86.07 tok/s | Credible raw result |
| Strata Linux Strix Halo table | 42.8--59.7 tok/s | Model/configuration dependent |
| Strata, two Titan RTX 24 GB cards | 70.9--77.3 tok/s | Credible two-GPU result |
| Strata, two Quadro RTX 4000 8 GB cards | 18.1--23.2 tok/s | Counters generic 8 GB claim |
| Local Qwen3-Coder short request | About 70 tok/s | Matches public exact-hardware evidence |
| Local long agent requests | About 11--34 tok/s | Expected workload effect |

## Exact EVO-X2 Qwen3-Coder result

The directly comparable source is the
`QWEN3-CODER-30B_BENCHMARK.md` report.
Source: [pablo-ross EVO-X2 repository](https://github.com/pablo-ross/strix-halo-gmktec-evo-x2)
It documents:

- Ryzen AI Max+ 395 with Radeon 8060S (`gfx1151`) and 124 GiB RAM;
- Qwen3-Coder-30B-A3B-Instruct-Q4_K_M, about 17.3 GiB;
- ROCm/HIP with rocWMMA, all layers offloaded, and `--no-mmap`;
- 8,192-token server context and two parallel slots;
- three non-warmup HTTP completions per prompt size;
- a 128-token output cap; and
- prompts of approximately 9, 51, and 88 tokens.

The reported generation rates are 70.25, 71.00, and 68.09 tok/s. This is
credible evidence for **short raw decode on the same hardware class and model
family**. It does not exercise a realistic agent history.

The same report gives prompt rates of only 4.94, 28.29, and 46.81 tok/s.
That is direct evidence that prompt and decode rates must remain separate.

## Exact-EVO-X2 Qwen3 llama-bench result

The [visorcraft Strix Halo repository](https://github.com/visorcraft/strix-halo-llm-perf)
reports Qwen3 30B-A3B Q4_K_M on the same EVO-X2 / Ryzen AI Max+ 395 /
Radeon 8060S class hardware. It uses Vulkan RADV and:

```text
llama-bench -m <model> -ngl 99 -p 512 -n 128
```

The results are:

| Power | Prompt rate | Generation rate |
| ---: | ---: | ---: |
| 85 W | 975.70 tok/s | 79.89 tok/s |
| 120 W | 1,141.78 tok/s | 86.07 tok/s |

The same table reports dense Qwen2.5 32B at 11.25 tok/s and Llama 3.1 70B
at about 5.10 tok/s. The high Qwen3 number is consistent with its MoE design:
Qwen3 30B-A3B has about 3B active parameters per token, not 30B dense
parameters.

## What the Strata reports actually say

The [Strata repository](https://github.com/Niko1221/Strata) documents a
benchmark guide, a draft standard protocol, and per-machine result folders.
Its protocol separates prompt throughput, decode throughput, TTFT, and total
latency. It records hardware, software, model, settings, actual token counts,
repetitions, cache state, and per-request data.

The result often summarized as "about 70 tok/s" is the
`2026-10-08-community-2x-titan-rtx-0.1.40.3` report. It uses two Titan RTX
24 GB cards, Flash-Next IQ3_S, and 262K context. Decode is 70.9, 77.3, and
71.1 tok/s at 4K, 32K, and 128K prompts. NVLink was present but unused. This
cannot be transferred to one 8 GB card.

The relevant 8 GB comparison is the
`2026-10-07-community-2x-rtx-4000` report. It uses two Quadro RTX 4000 8 GB
cards, a 125B MoE model, IQ2_XS quantization, RAM-tiered expert caching, and
131K context. It reports 18.1--23.2 generated tok/s on 500--1,100 output-token
requests. Its 126.3--249.2 tok/s figures are prompt processing on roughly
73K--75K-token prompts, not decode.

The official `docs/STRIX_HALO.md` table reports roughly 42.8--59.7 generated
tok/s for Qwen3.8 Flash-Next variants. Its 1,169--1,320 tok/s figures are
prompt rates. The official EVO-X2 result folder
`2026-10-09-community-gfx1151-ud-iq4xs-0.1.41` reports 42.1--47.5 decode
tok/s at 128K prompts and includes hashes, build data, scripts, and
limitations.

The [Strata repository](https://github.com/Niko1221/Strata) contains the
benchmark guide (`docs/COMMUNITY_BENCHMARKS.md`) and protocol
(`docs/BENCHMARK_PROTOCOL.md`). These are useful references for future
claims. Older community reports predate the standard protocol and should not
be treated as equally controlled.

## Why honest benchmarks can differ by 2x

1. **Different models.** Qwen3 30B-A3B is an MoE with roughly 3B active
   parameters. Dense Qwen2.5 32B, Qwen3.8 27B, and larger MoE models move
   more data per generated token.
2. **Different quantizations.** Q4_K_M, IQ3, IQ4, Q6, and custom UD packs have
   different memory traffic, kernels, quality, and cache behavior.
3. **Different backends and builds.** ROCm/HIP and Vulkan/RADV can trade places
   for prompt versus decode speed. ROCm version, hipBLASLt, rocWMMA, commit,
   compiler, and architecture target all matter.
4. **Different context depth.** A 262K context limit does not mean a request
   has read 262K tokens. Generation after a short prompt is easier than after
   a large KV cache has been populated.
5. **Speculative decoding.** MTP or another draft model can increase accepted
   output rate. The draft model, window, acceptance, and token accounting must
   be reported.
6. **Different timing boundaries.** `llama-bench` excludes tokenization and
   sampling. HTTP timings may include server overhead; client measurements
   also include queueing, streaming, network, and application work.
7. **Cache state.** Fresh process, warmed engine, reused prefix, warmed expert
   cache, and long multi-turn runs are different tests.
8. **Output behavior.** A short cap, early EOS, thinking disabled, or forced
   repetitive output may not represent a coding response.
9. **Concurrency.** A sum of several requests is not the rate of one request.
   Slot count and queueing must be reported separately.

## Claim grading

| Claim | Assessment |
| --- | --- |
| EVO-X2 short decode | **Supported** |
| EVO-X2 long agent at 70 | **Not supported** |
| Generic 8 GB GPU at 70 | **Unverified** |
| Strata at 70 | **Incomplete claim** |
| 70 tok/s proves agent speed | **False inference** |

Calling an under-documented result a deliberate lie would go beyond the
evidence. The defensible label is **unverified** until the missing controls are
provided.

## Minimum evidence for a new claim

Ask for these fields before comparing the number:

1. Exact GPU model, GPU count, memory, CPU, system RAM, and power limit.
2. Exact model repository, revision, GGUF filename, architecture, and quant.
3. Backend, driver/runtime, engine commit, compiler, build options, and target.
4. Full launch command, including offload, context, slots, batch sizes, KV,
   flash attention, MTP/speculation, and reasoning settings.
5. Prompt tokens, generated tokens, context depth, cache state, and output cap.
6. Whether the rate is prompt, decode, end-to-end, or concurrent aggregate.
7. At least three runs, warm-up policy, range or standard deviation, and failed
   or truncated requests.
8. A correctness check against degenerate or invalid output.

A credible short benchmark should add a fixed 4K or 16K prompt and output cap.
A credible agent claim should add a repeatable multi-turn workload and report
TTFT, prompt processing, decode, cache reuse, total latency, and quality
separately.

## Comparison with this repository

The repository's [local performance research](high-token-rate-model-research.md)
records about 70 tok/s for a short direct Qwen3-Coder-30B-A3B decode and much
lower rates for long agent requests. A controlled `--parallel 1`,
`--ctx-size 65536` candidate measured approximately 70.18 tok/s short versus
70.05 tok/s for the existing configuration. Its long rate was 34.06 versus
34.08 tok/s. It was rejected as a performance improvement because neither
short nor long throughput improved.

Therefore the public short benchmark is not exposing a hidden missing 70 tok/s
capability in this setup. The local system already reaches that class of raw
rate for the matching MoE model. The remaining optimization question is
long-context agent latency, not whether the hardware can print a short `tg128`
number near 70.

## Sources

- [llama.cpp repository](https://github.com/ggml-org/llama.cpp)
- [pablo-ross EVO-X2 repository](https://github.com/pablo-ross/strix-halo-gmktec-evo-x2)
- [visorcraft Strix Halo benchmarks](https://github.com/visorcraft/strix-halo-llm-perf)
- [Strata repository](https://github.com/Niko1221/Strata)
- [Local performance research](high-token-rate-model-research.md)
