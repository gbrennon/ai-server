# Qwen3-Coder 30B context and slot comparison

Research date: 2026-10-30.

This report records the controlled comparison between the original Qwen3-Coder
30B-A3B runtime and the one-slot, bounded-context candidate. It is separate
from the lightweight Qwen2.5-Coder model sweep in
`lightweight-model-benchmark.md`.

## Hardware and model

- GMKtec EVO-X2, Ryzen AI Max+ 395, Radeon 8060S (`gfx1151`);
- ROCm/HIP on `ROCm0`, full layer offload, Flash Attention;
- Qwen3-Coder-30B-A3B-Instruct Q4_K_M;
- q8_0 K/V cache, 16 CPU threads, reasoning disabled;
- `--split-mode layer`, identical model/backend flags for both cases.

The existing runtime used four 65,536-token slots and a 262,144-token total
context. The candidate used one slot and a 65,536-token total context. The
candidate intentionally traded retained context and concurrency for single-agent
bounded memory behavior.

## Controlled rate comparison

| Configuration | Short decode | Long decode | Decision |
| --- | ---: | ---: | --- |
| 4 slots, 262,144 context | 70.054 tok/s | 34.079 tok/s | Baseline |
| 1 slot, 65,536 context | 70.177 tok/s | 34.062 tok/s | Rejected |

The short difference is approximately +0.18%; the long difference is
approximately -0.05%. Both are within ordinary run-to-run noise. The candidate
did not improve either measured rate, so it was not accepted as a Qwen3-Coder
performance optimization.

The long workload is the relevant signal for agent use. Its much lower rate
compared with the short result demonstrates that long prompt processing and KV
attention dominate the practical workload; the short `tg128` number does not
represent complete coding-agent throughput.

## Interpretation

The hardware already reaches the public approximately 70 tok/s class for this
MoE model under short decode conditions. Reducing slots and total context did
not unlock a hidden higher rate. The remaining optimization target is long
context and end-to-end agent latency, not the short raw decode ceiling.

No quality comparison was performed in this experiment. The candidate was
rejected only because it failed to improve measured throughput and would reduce
context retention.

## Related verification evidence

The repository records the following supporting checks:

- the direct API path measured approximately 70 tok/s for short Qwen3-Coder
  decode;
- long agent requests were materially slower because of prompt/context work;
- the gateway uses `flush_interval -1`, so intentional SSE buffering was not
  identified as the cause;
- the Qwen3.8 gateway measurement in the separate rates report returned
  11.61 tok/s for a long-context request, confirming that raw decode and
  end-to-end agent rates are different metrics;
- Pi and OMP sentinel requests were previously verified against the registered
  model, but their wall-clock rates must not be presented as raw decode rates.

## Build and configuration caveat

The source checkout and live llama.cpp binary had different recorded commit
identifiers during the broader investigation. The repository build-role
hardening and test changes are tracked separately in the working tree. This
comparison therefore treats the running binary as the measured subject and
attributes no causal performance improvement to a rebuild.

## Sources

- [Local high-token-rate research][local-research]
- [Benchmark claim investigation][claim-report]
- [Qwen3 rate report][rates-report]
- [llama.cpp repository][llama]

[local-research]: docs/performance/high-token-rate-model-research.md
[claim-report]: docs/performance/benchmark-claim-investigation.md
[rates-report]: docs/performance/gmktec-evo-x2-qwen3-27b-rates.md
[llama]: https://github.com/ggml-org/llama.cpp
