# GMKtec EVO-X2 performance comparison

Research date: 2026-10-30.

This report consolidates the measured model and runtime comparisons for the
GMKtec EVO-X2 / Ryzen AI Max+ 395 / Radeon 8060S (`gfx1151`). Rates are raw
llama.cpp decode rates unless explicitly labelled otherwise. They are not
interchangeable with client wall-clock time or complete coding-agent throughput.

## Hardware and common runtime

- ROCm/HIP on `ROCm0` with all model layers offloaded;
- Flash Attention enabled;
- q8_0 K/V cache, 16 CPU threads, layer split mode;
- reasoning disabled;
- one active request during the lightweight model comparison.

## Executive comparison

| Test | Context | Short decode | Long decode | Result |
| --- | ---: | ---: | ---: | --- |
| Qwen3-Coder 30B, 4 slots | 262,144 | 70.054 tok/s | 34.079 tok/s | Baseline |
| Qwen3-Coder 30B, 1 slot | 65,536 | 70.177 tok/s | 34.062 tok/s | No improvement |
| Qwen2.5-Coder 1.5B | 32,768 | 135.80 tok/s | 119.84 tok/s | Fastest |
| Qwen2.5-Coder 3B | 32,768 | 79.46 tok/s | 69.86 tok/s | Middle |
| Qwen2.5-Coder 7B | 32,768 | 42.91 tok/s | 35.82 tok/s | Slowest |

The Qwen3 comparison and Qwen2.5 comparison are different experiments. The
Qwen3 test compares slot/context configurations for one model. The Qwen2.5
test compares model sizes under a fixed 32K, one-slot configuration.

## Qwen3-Coder 30B runtime comparison

The original runtime used four 65,536-token slots and a 262,144-token total
context. The candidate used one slot and a 65,536-token total context.

| Configuration | Short decode | Long decode | Decision |
| --- | ---: | ---: | --- |
| 4 slots, 262,144 context | 70.054 tok/s | 34.079 tok/s | Retained as reference |
| 1 slot, 65,536 context | 70.177 tok/s | 34.062 tok/s | Rejected |

The short difference was approximately +0.18%; the long difference was
approximately -0.05%. Neither exceeds normal measurement noise. Reducing the
context and slot count did not improve Qwen3-Coder throughput.

The long workload is the practical signal for agent use: it is approximately
half the short decode rate because prompt processing and KV attention dominate
as context grows.

## Lightweight model comparison

Each Qwen2.5-Coder model was started separately with one slot and 32,768
context. Each received three short requests and three fresh long requests.
Prompt caching was disabled with `cache_prompt: false`, and a unique marker
was added to each run.

The short prompt contained 63 input tokens and generated 30 tokens. The long
prompt contained 8,114 input tokens and generated 128 tokens. The benchmark
harness originally called the long case `long4k`, but the measured input was
about 8K tokens; this report uses the measured size.

| Model | Short range | Short mean | Long range | Long mean |
| --- | ---: | ---: | ---: | ---: |
| Qwen2.5-Coder 1.5B Q4_K_M | 135.67--135.99 | 135.80 | 119.77--119.91 | 119.84 |
| Qwen2.5-Coder 3B Q4_K_M | 79.00--79.95 | 79.46 | 67.96--70.81 | 69.86 |
| Qwen2.5-Coder 7B Q4_K_M | 42.83--42.98 | 42.91 | 34.76--37.77 | 35.82 |

## Thermal comparison

| Model | Peak GPU edge | Peak ACPI |
| --- | ---: | ---: |
| Qwen2.5-Coder 1.5B | 75 C | 73 C |
| Qwen2.5-Coder 3B | 79 C | 80 C |
| Qwen2.5-Coder 7B | 90 C | 89 C |

The 7B model was stopped after its measurements. The production service was
restored and later verified healthy with zero restarts. The selected 1.5B
service was idle at approximately 36--42 C GPU edge and 12 W package power in
final checks.

## Selected deployment

The active profile now selects Qwen2.5-Coder 1.5B Q4_K_M with a 32,768-token
context. The three lightweight GGUF files remain installed on the mini PC.
Pi and OMP are registered with model id `qwen25-coder-1.5b`.

The 1.5B choice means **maximum measured throughput**, not maximum coding
quality. The 3B or 7B model may produce better answers for some tasks, but no
quality or task-success comparison was performed here.

## What the results mean

1. The hardware can credibly exceed 70 generated tok/s with a small model.
2. Qwen3-Coder 30B reaches about 70 tok/s only under short raw decode timing.
3. Long prompts reduce throughput substantially, even when the model is fast.
4. Lowering Qwen3 context and slots did not improve the measured rates.
5. Smaller Qwen2.5-Coder models are much faster, but speed alone does not
   establish better coding quality.
6. A public “70 tok/s” claim is meaningful only when model, prompt length,
   cache state, output cap, timing boundary, and thermal conditions are stated.

## Related reports

- [Qwen3 context comparison][qwen3]
- [Lightweight model benchmark][lightweight]
- [70 tok/s claim investigation][claims]
- [High-token-rate research][research]

[qwen3]: qwen3-coder-30b-context-comparison.md
[lightweight]: lightweight-model-benchmark.md
[claims]: benchmark-claim-investigation.md
[research]: high-token-rate-model-research.md
