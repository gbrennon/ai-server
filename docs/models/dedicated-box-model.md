# Dedicated box model change

The GMKtec EVO X2 is a dedicated box serving a single model behind the unchanged
provider name `gbrennon-ai-server`. The served GGUF changed; this file records
the model lineage and the structural difference between the model that was
removed and the model now in service.

## Lineage

| Generation | Model name | GGUF file | Status |
|---|---|---|---|
| 1 | `Qwen3-30B-A3B-Instruct-2507` | `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf` | retired |
| 2 | `Qwen3.8-27B GSQ-RCO` | `Qwen3.8-27B-GSQ-RCO-IQ3_XXS.gguf` | retired |
| 3 | `Qwen3-Coder-30B-A3B-Instruct` | `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` | in service |

The provider name exposed to clients stays `gbrennon-ai-server`; only the model
id and context the auto-register publishes changed.

## Why generation 2 was replaced

Generation 2 (`Qwen3.8-27B-GSQ-RCO-IQ3_XXS`, a dense 27B at 3-bit) could emit
tool calls, but at 3-bit it mangled structured tool arguments: it serialized
list and object arguments as malformed text, which broke agentic coding loops
(selective `git add` of one path, commit with `-m`, shell commands with an args
array). It also forced `--reasoning off` to stop multi-thousand-token rambling
with no tool call, and still only reached ~13.3 tok/s generation.

Generation 3 (`Qwen3-Coder-30B-A3B-Instruct` at Q4_K_M) is a coding-tuned
sparse MoE that activates ~3.3B of 30.5B parameters per token. It restores
clean structured tool-argument serialization and runs far faster per token.

## Structural comparison (retired gen 2 vs current gen 3)

Values read directly from each GGUF's metadata header and the llama.cpp load.

| Property | Gen 2 (27B IQ3) | Gen 3 (Coder 30B-A3B) |
|---|---|---|
| Architecture | `qwen35` (dense) | `qwen3moe` (Mixture of Experts) |
| Total parameters | ~27B | ~30.53B |
| Active parameters per token | ~27B (all) | ~3.3B (`30B-A3B`) |
| Experts (count / used) | none (dense) | 128 / 8 |
| Transformer blocks | 64 | 48 |
| Embedding length | 5120 | 2048 |
| Dense feed-forward length | 17408 | 6144 |
| Expert feed-forward length | not applicable | 768 |
| Attention heads (Q / KV) | 24 / 4 (GQA) | 32 / 4 (GQA) |
| Head dimension (key / value) | 256 / 256 | 128 / 128 |
| Native context length | 262144 | 262144 |
| RoPE frequency base | 10000000 | 10000000 |
| Quantization | `IQ3_XXS` (3-bit) | `Q4_K_M` (4-bit, 4.86 BPW) |
| File size on disk | ~9.5 GB | ~17.3 GB |
| Specialization | general instruct | coding/agentic instruct |

## What the difference means

- Compute shape: gen 2 is dense, so all ~27B parameters run on every token;
  gen 3 is a sparse MoE that routes each token to 8 of 128 experts, so only
  ~3.3B parameters run per token. That makes gen 3 much faster to decode
  despite holding more total parameters.
- Precision: gen 3 is 4-bit (`Q4_K_M`, 4.86 BPW) instead of 3-bit. The extra
  precision is what restores reliable structured tool-argument serialization;
  3-bit was the root cause of the mangled JSON arguments in gen 2.
- Footprint: gen 3 is larger on disk (~17.3 GB vs ~9.5 GB) but still fits the
  ~96 GB iGPU carve with large KV headroom at the shared 262144 native context.
- Specialization: gen 3 is coding/agentic-tuned, so it prefers calling tools
  over prose and does not need the `--reasoning off` workaround gen 2 required.

See [verification](verification.md) for measured tool-call and throughput
results, and [the switch report](coder-switch-report.md) for the full decision
record.
