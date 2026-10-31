# Lightweight model benchmark on the GMKtec EVO-X2

Research date: 2026-10-30.

This report records a controlled comparison of three small Qwen2.5-Coder GGUF
models downloaded from Hugging Face, deployed on the GMKtec EVO-X2, and tested
one at a time through the local llama.cpp HTTP server.

## Executive result

**Qwen2.5-Coder-1.5B Q4_K_M is the throughput winner.** It reached a mean
135.80 generated tok/s on a short coding prompt and 119.84 generated tok/s
with an 8,114-token prompt. The 3B model reached 79.46 and 69.86 tok/s;
the 7B model reached 42.91 and 35.82 tok/s.

The repository profile now selects the 1.5B model with a 32,768-token context.
All three downloaded files remain installed on the mini PC. This is a
throughput selection, not a claim that 1.5B has the best coding quality. The
3B or 7B model may be preferable when answer quality matters more than speed.

## Models and integrity

| Model | File size |
| --- | ---: |
| Qwen2.5-Coder-1.5B Q4_K_M | 1,111,370,240 B |
| Qwen2.5-Coder-3B Q4_K_M | 2,104,932,800 B |
| Qwen2.5-Coder-7B Q4_K_M | 4,683,073,536 B |
Full SHA-256 values:

- **1.5B:** `cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046`
- **3B:** `724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7`
- **7B:** `509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c`

The full hashes were computed on the mini PC and match the Hugging Face LFS
`oid` values for the corresponding files. Hugging Face also exposes a separate
Xet hash; it is not the file SHA-256 and must not be compared as if it were.

Sources: [1.5B metadata][hf-15], [3B metadata][hf-3], [7B metadata][hf-7].

## Test configuration

The same llama.cpp HIP server binary and flags were used for every model:

- ROCm device `ROCm0`, all layers offloaded with `-ngl 99`;
- one request slot with `--parallel 1`;
- `--ctx-size 32768`, 16 CPU threads, flash attention enabled;
- q8_0 K/V cache, `--reasoning off`, temperature 0.2 at server level;
- one short coding prompt and one long generated prompt;
- three runs per prompt size and model;
- 128 maximum generated tokens for the long case;
- prompt caching disabled with `cache_prompt: false`;
- a unique run marker appended to every request to prevent cache reuse.

The long prompt was 34,176 characters and measured 8,114 input tokens. The
harness label said `long4k` during execution, but the measured prompt was about
8K tokens; this report uses the measured token count.

The reported decode rate is llama.cpp's `predicted_per_second`: generated
tokens divided by decode time. It excludes client-side work and should not be
mistaken for end-to-end agent throughput.

## Results

| Model | Short decode tok/s | Long decode tok/s | Short prompt tok/s | Long prompt tok/s |
| --- | ---: | ---: | ---: | ---: |
| 1.5B | 135.67--135.99 (135.80 mean) | 119.77--119.91 (119.84 mean) | 2,949--3,315 | 5,547--5,551 |
| 3B | 79.00--79.95 (79.46 mean) | 67.96--70.81 (69.86 mean) | 1,337--1,949 | 2,890--2,929 |
| 7B | 42.83--42.98 (42.91 mean) | 34.76--37.77 (35.82 mean) | 874--1,201 | 1,523--1,532 |

Each model processed 63 input tokens in the short case and 8,114 input tokens
in the long case on every run. The long case always generated 128 tokens and
stopped on the length limit. The short case generated 30 tokens and stopped
normally.

## Thermal observations

| Model | Peak GPU edge | Peak ACPI | Result |
| --- | ---: | ---: | --- |
| 1.5B | 75 C | 73 C | Completed |
| 3B | 79 C | 80 C | Completed |
| 7B | 90 C | 89 C | Completed |

The 7B run was stopped after its measurements and the production service was
allowed to cool. The restored service was healthy with zero systemd restarts;
verification measured 42 C GPU edge and 45 C ACPI. No additional inference was
run after the 7B thermal peak.

## Final deployment state

The selected profile changes are in `profiles/gmktec-evo-x2.yml`:

- model URL/file: Qwen2.5-Coder-1.5B Q4_K_M;
- server context: 32,768 tokens;
- client model id: `qwen25-coder-1.5b`.

The mini PC is running that model through systemd. Final verification showed:

- `/health`: `{"status":"ok"}`;
- active command uses the 1.5B file and `--ctx-size 32768`;
- systemd state `active`, `NRestarts=0`;
- `/v1/models` reports the selected 1.5B GGUF;
- direct sentinel request returned exactly `MODEL_OK`;
- Pi and OMP registries contain `qwen25-coder-1.5b` with a 32,768 context;
- all three candidate files remain installed with 8.8 GiB free.

## Interpretation

The 1.5B model is the correct choice when the objective is maximum raw decode
throughput on this setup. It is approximately 1.71x faster than the 3B model
on the short prompt and approximately 3.17x faster than the 7B model.

This does not validate a generic claim that every model or real coding-agent
session will reach 70 tok/s. These measurements show why the claim depends on
model size, prompt length, cache state, timing boundary, and thermal behavior:
the 3B model reaches about 70 tok/s only in the long-prompt case, while the 7B
model is below 43 tok/s even on the short case. Agent sessions also add client
work, transport, tool calls, and potentially reasoning tokens.

[ hf-15 ]: https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/tree/main
[ hf-3 ]: https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/tree/main
[ hf-7 ]: https://huggingface.co/api/models/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/tree/main
