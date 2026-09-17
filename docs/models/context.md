# Context windows

There are two separate context limits:

1. **llama.cpp context** — the model/KV-cache capacity configured at server startup.
2. **OMP context** — the agent transcript, managed by OMP compaction.

## Native model context

The EVO X2 profile uses:

```yaml
llamacpp_ctx_size: 0
```

In the installed llama.cpp build, `--ctx-size 0` loads the context size from
the selected GGUF metadata. Switching between models with different native
limits therefore does not require changing the profile's context value.

This does not extend a model beyond its trained context. Check the active
value with:

```bash
curl -s http://192.168.0.2:8080/props | python3 -m json.tool
```

## 1M experiments

A model must be trained for, or explicitly extended to, a 1M context. For
Qwen3.8-27B, start at its native 262k context, then test the model-specific
YaRN configuration. This requires replacing `llamacpp_ctx_size: 0` with an
explicit value and adding the required RoPE/YaRN arguments.

A larger context increases KV-cache memory linearly. Quantized KV cache may be
necessary:

```yaml
llamacpp_extra_args: >-
  -ngl 99
  --flash-attn on
  --cache-type-k q8_0
  --cache-type-v q8_0
```

Do not copy YaRN parameters between architectures without checking the model
metadata and llama.cpp support. If the service fails to start, lower the
explicit context or select a smaller model.

## OMP metadata

After changing the model or restarting llama.cpp:

```bash
omp models refresh
omp models llama.cpp
```

OMP's compaction manages the agent transcript; it cannot make the llama.cpp
model or KV cache larger. See OMP's [compaction documentation](https://github.com/can1357/oh-my-pi/blob/main/docs/compaction.md).
