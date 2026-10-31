# Article model benchmark on the GMKtec EVO-X2

Research date: 2026-10-30.

This report records controlled benchmarks of models mentioned in (or from the
family mentioned in) the Compute Market Ryzen AI Halo review, run one at a time
through the local llama.cpp HTTP server on the GMKtec EVO-X2 mini PC.

## Source context

Source article: [AMD Ryzen AI Halo Review — $3,999 128GB Local-LLM Box,
Benchmarked (2026)](https://www.compute-market.com/blog/amd-ryzen-ai-halo-review-2026)

The article reports directional token rates for Strix Halo / Ryzen AI Max+ 395
with 128 GB unified memory:

| Model class | Example | Reported generation speed |
| --- | --- | --- |
| Small dense under 10B | Llama 4 Scout 8B, Qwen3 7B Q4 | ~40–80 tok/s |
| Mid-size MoE | Gemma 3 27B | ~25–45 tok/s |
| Coder MoE | Qwen3-Coder-class Q4 | ~100 tok/s reported |
| Dense 70B | Qwen3 72B, DeepSeek-R1 70B Q4 | ~4–9 tok/s |

The article itself states these figures are vendor/community-reported,
directional, and vary with quantization, context length, and backend. It does
not provide a reproducible `llama-server` command line, context size, batch
size, or output cap.

## Models downloaded and tested

| Model | Size | Source |
| --- | ---: | --- |
| Qwen3-8B Q4_K_M | 5,027,783,488 B | Hugging Face |
| Qwen3-Coder-30B-A3B-Instruct Q4_K_M | 18,556,685,824 B | Local disk (`/home/.../models/`) |
SHA-256 Qwen3-8B Q4_K_M: `d98cdcbd03e17ce47681435b5150e34c1417f50b5c0019dd560e4882c5745785`
SHA-256 Qwen3-Coder-30B-A3B-Instruct Q4_K_M: already installed on disk
Qwen3-7B Q4 does not exist as an official Hugging Face release under
`Qwen/Qwen3-7B-GGUF`; Qwen3-8B Q4_K_M is the closest article-mentioned small
dense model available. gpt-oss-GGUF repository metadata was inaccessible (401)
and was not pursued.

No additional large models were downloaded. Qwen3-Coder-30B was already present
on the mini PC (`/home/gbrennon-local-ai/models/`, 904 GiB free on `/home`), so
no transfer was needed.

## Benchmark configuration

Same settings for every model tested:

- ROCm device `ROCm0`, all layers offloaded (`-ngl 999`);
- one request slot (`--parallel 1`);
- `--ctx-size 32768` for Qwen3-8B, `--ctx-size 131072` for Qwen3-Coder-30B;
- 16 CPU threads, Flash Attention on;
- q8_0 K/V cache, `--reasoning off`, temperature 0.2 at server level;
- three short coding prompts and three fresh long prompts per model;
- prompt caching disabled (`cache_prompt: false`);
- unique run marker appended to every request to prevent KV-cache reuse;
- 128 maximum generated tokens for the long case.

The short prompt measured **42 input tokens** and generated **30 tokens**.
The long prompt measured **8,089 input tokens** and generated **128 tokens**
(stopped by length limit).

## Qwen3-8B Q4_K_M results (ctx 32768)

| Case | Decode tok/s (range) | Decode tok/s (mean) | End-to-end tok/s (mean) |
| --- | ---: | ---: | ---: |
| Short (42 in / 30 out) | 39.41–39.47 | 39.44 | 35.89 |
| Long (8,089 in / 128 out) | 31.53–33.01 | 32.51 | 11.64 |

Prompt processing: approximately 884.75 tok/s short / 1,148.09 tok/s long.

## Qwen3-Coder-30B-A3B-Instruct Q4_K_M results (ctx 131072)

| Case | Decode tok/s (range) | Decode tok/s (mean) | End-to-end tok/s (mean) |
| --- | ---: | ---: | ---: |
| Short (42 in / 30 out) | 68.38–69.01 | 68.80 | 56.45 |
| Long (8,089 in / 128 out) | 47.65–50.14 | 48.80 | 16.38 |

Prompt processing: approximately 421.73 tok/s short / 1,555.42 tok/s long.

## Power and thermal observations

Qwen3-Coder-30B run (samples: 21):

| Metric | Value |
| --- | --- |
| Minimum GPU package power | 13.08 W |
| Mean GPU package power | 116.57 W |
| Maximum GPU package power | 139.02 W |
| Peak GPU edge temperature | 81°C |
| Peak ACPI temperature | 84°C |

Qwen3-8B run (samples: 30):

| Metric | Value |
| --- | --- |
| Minimum GPU package power | 12.09 W |
| Mean GPU package power | 116.69 W |
| Maximum GPU package power | 140.0 W |
| Peak GPU edge temperature | 85°C |
| Peak ACPI temperature | 89°C |

Both candidate runs ran hotter than Qwen2.5-Coder 1.5B idle (~13 W, ~41°C)
and approached the Qwen2.5-Coder 7B thermal levels (90°C edge / 89°C ACPI).
Qwen3-Coder-30B ran slightly cooler than Qwen3-8B (81/84°C vs 85/89°C)
while delivering substantially more throughput at 4× the context.

## Comparison summary

| Model | Context | Short decode | Long decode |
| --- | ---: | ---: | ---: |
| Qwen2.5-Coder 1.5B Q4_K_M | 32 K | 132–136 tok/s | 119–120 tok/s |
| Qwen2.5-Coder 3B Q4_K_M | 32 K | 79–80 tok/s | 68–71 tok/s |
| Qwen2.5-Coder 7B Q4_K_M | 32 K | 42–43 tok/s | 35–38 tok/s |
| Qwen3-8B Q4_K_M | 32 K | 39.44 tok/s | 32.51 tok/s |
| Qwen3-Coder-30B-A3B Q4_K_M | 131 K | 68.80 tok/s | 48.80 tok/s |

Qwen3-Coder-30B delivers ~1.7× the short-context decode rate and ~1.5× the
long-context decode rate of Qwen3-8B, at 4× the context window, with slightly
better thermals. It is the throughput winner among article-family models tested
while keeping a 131 K context budget.

## Production deployment state

**Qwen3-Coder-30B-A3B-Instruct Q4_K_M is now the active production model** on the
GMKtec EVO-X2, managed by systemd `llama-server.service` with:
- `--ctx-size 131072` (131K context window);
- `--parallel 1` (single slot);
- `-ngl 999` (ROCm0 full GPU offload);
- Flash Attention on, q8_0 KV cache, reasoning off.

Canonical deployment was verified via `make deploy-gmktec` and client sync
(`make register-gmktec-model`). Live verification confirmed `MainPID=257867`
(at deployment time), `NRestarts=0`, SubState `running`, `/health` ok, `/slots`
reporting 1 slot at `n_ctx=131072`, and registered in Pi and OMP configs as
`qwen3-coder-30b`.

## Notes

- Power figures are sampled instantaneous GPU package power
  (`rocm-smi --showpower`), not whole-system energy or wall power.
- The 139 W / 84°C peak means Qwen3-Coder-30B should not be left serving
  unattended without thermal monitoring.
- The 1.7× short / 1.5× long speedup comparisons are directional: the 8B test
  evaluated 46 prompt / 26 generated tokens short and 8,093 / 128 long tokens,
  whereas the 30B test evaluated 42 / 30 short and 8,089 / 128 long tokens.
- The long benchmark tested an ~8K prompt (~8,089 tokens); it does not
  constitute a saturated 24K or 131K context window stress test.
- Article rates (~40–80 tok/s for small dense, ~100 tok/s for coder-class) are
  directional and from different backends/contexts; they are not directly
  comparable to these single-slot ROCm measurements.
- Qwen3-Coder-30B n_ctx_train is 262144; the service runs at 131072 ctx-size,
  half the model's trained maximum, leaving headroom for future context growth.
