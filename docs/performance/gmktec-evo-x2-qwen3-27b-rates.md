# GMKtec EVO X2 Qwen3.8-27B inference rates

This report records measured inference rates for the live GMKtec EVO X2 deployment.

## Deployment

| Setting | Measured value |
|---|---|
| Hardware | AMD Ryzen AI Max+ 395 / Radeon 8060S |
| Backend | ROCm/HIP using `ROCm0` |
| Model | `Qwen3.8-27B-UD-Q4_K_M.gguf` |
| Quantization | `Q4_K_M` model weights, `q8_0` K/V cache |
| Context window | `262144` tokens |
| Parallel slots | `1` |
| Reasoning | Disabled |
| Client max output | `8192` tokens |
| API endpoint | `https://api.ai-gbrennon.home.arpa/v1` |

The model's GGUF metadata reports `n_ctx_train: 262144`. The running
llama.cpp server reports `n_ctx: 262144` and one active slot. Single-slot mode
is required to retain the full 256K context on this hardware with this model
and KV-cache configuration.

## Measured rates

The request was sent through the internal HTTPS gateway using the OpenAI
chat-completions endpoint. The prompt requested an exactly 32-word explanation
and generation was capped at 48 tokens.

| Metric | Result |
|---|---:|
| Prompt tokens | 41 |
| Completion tokens | 42 |
| Prompt processing | 122.99 tokens/sec |
| Token generation | 11.61 tokens/sec |
| End-to-end elapsed time | 11.61 seconds |

The response contained normal assistant content with no separate reasoning
channel.

## Agent verification

Both configured client agents completed requests through the registered
provider and returned the expected sentinel output:

```text
Pi: PI_FINAL_OK
OMP: OMP_FINAL_OK
```

Pi and OMP are registered with the detected model metadata:

```text
Model:       Qwen3.8-27B-UD-Q4_K_M.gguf
Context:     262144
Max output:  8192
Reasoning:   false
```

## Reproduction

Deploy the profile and synchronize client registration:

```bash
make deploy-gmktec HOST=192.168.0.2 USER=gbrennon-local-ai
make register-gmktec-model
```

Use either client with the registered model:

```bash
pi --provider gbrennon-ai-server --model Qwen3.8-27B-UD-Q4_K_M.gguf
omp --model gbrennon-ai-server/Qwen3.8-27B-UD-Q4_K_M.gguf
```

The 256K context and 8K output limit are intentional. The context window
controls how much conversation and source material the agent can retain; the
smaller output limit prevents runaway completions from exhausting the context
or causing client-side truncation.

## Sequential agent task benchmark

Pi and OMP were each delegated the same three tasks in sequence. The tasks
were run in this order: easy, medium, and hard. Each task used the registered
Qwen3.8-27B model with thinking disabled, no tools, and no session persistence.
Elapsed times are supervised process wall-clock times.

| Task | Pi time | OMP time | Result |
|---|---:|---:|---|
| Easy shell-command explanation | 30.8 s | 83.0 s | Both completed correctly |
| Medium typed Python function | 43.1 s | 147.0 s | Both completed correctly |
| Hard registry design plan | 75.0 s | 210.0 s | Both completed correctly |
| Total | 148.9 s | 440.0 s | Both completed all three tasks |

The direct API measurement recorded generation at `11.61 tokens/sec` and
prompt processing at `122.99 tokens/sec`. The agent task wall-clock times
include client startup, prompt construction, model generation, and client
shutdown; they are therefore not equivalent to raw decode time.

Pi completed the benchmark in 2.95 minutes. OMP completed it in 7.33 minutes.
OMP took longer because its runs performed additional startup and session
initialization work, even with prewalk, tools, skills, rules, extensions, and
session persistence disabled.

The benchmark verifies that both agents can complete progressively harder
delegated tasks against the full 256K-context deployment. It does not measure
tool-call latency because tools were intentionally disabled to isolate model
and client completion behavior.
