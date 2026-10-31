# Qwen2.5-Coder-32B Token Rate Benchmark

**Model:** Qwen2.5-Coder-32B-Instruct Q4_K_M  
**Context:** 131,072 tokens native (n_ctx_train = 131072)  
**Device:** Radeon 8060S (gfx1151) on GMKtec Evo X2  
**Profile:** profiles/gmktec-evo-x2.yml (--parallel 1, --ctx-size 131072, --ngl 999, etc.)

## Test Setup

- **Endpoint:** http://192.168.0.2:8080/v1/chat/completions
- **Model ID:** /var/lib/llama.cpp/models/qwen2.5-coder-32b-instruct-q4_k_m.gguf
- **Prompt:** Write a Rust function add(a: i32, b: i32) -> i32
- **max_tokens:** 96
- **temperature:** 0
- **timings_per_token:** true

## Results

### Token Usage
- **prompt_tokens:** 50
- **completion_tokens:** 96
- **total_tokens:** 146
- **cached_tokens:** 49

### Timings
- **Prompt processing:** 96.134 ms → 10.40 tokens/s
- **Generation (predicted):** 9,105.412 ms → 10.43 tokens/s
- **Predicted per token:** 95.85 ms

### Hardware Telemetry
- **GPU Temperature:** 42.0°C (Sensor edge)
- **GPU Power:** 12.036 W
- **GPU Utilization:** 0% (idle after request)

## Observations

- Token generation rate is ~10.4 tokens/s for a 32B dense model on Strix Halo iGPU.
- Power consumption remains low idle; immediate post-request power ~12W.
- The model loads correctly with 131K context confirmed via /v1/models metadata.

## Next Steps

- Increase prompt complexity to measure sustained decode speed and KV cache impact.
- Compare with prior Qwen3-Coder-30B-A3B baseline.
- Benchmark with power logging during active generation.
