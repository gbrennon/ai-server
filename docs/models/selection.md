# Model selection

Choose a GGUF whose weights, KV cache, Vulkan workspace, and service overhead fit
the target. A model that fits as a file can still fail at startup with a large
context. See [context windows](context.md) and [model switching](switching.md).

Use a direct Hugging Face `resolve` URL:

```yaml
llamacpp_model_url: https://huggingface.co/<owner>/<repo>/resolve/main/<file>.gguf
llamacpp_model_file: <file>.gguf
```

## GMKtec EVO X2 candidates

The EVO X2 has approximately 96 GB of UMA/iGPU memory. MoE models are usually
preferable because they activate fewer parameters per token, but all quantized
weights still need storage.

| Model | Approx. quantized size | Fit | Notes |
|---|---:|---|---|
| Qwen3-30B-A3B Q4_K_M | ~18.6 GB | ✅ | Current fast MoE baseline |
| Qwen3.8-27B Q4 GGUF | ~17–20 GB | ✅ | Dense multimodal; 262k native context, YaRN toward 1M. [GGUF](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF) |
| Qwen3-Coder-30B-A3B Q4_K_M | ~18.6 GB | ✅ | Coding-focused MoE |
| Llama 3.3 70B Q4_K_M | ~42 GB | ✅ | Dense and slower |
| gpt-oss-120b MXFP4 | ~63 GB | ⚠️ | Large MoE; less room for large KV cache |
| GLM-4.5-Air Q4 | Verify exact file | ⚠️ | Check the exact Air quantization |
| DeepSeek-V4-Flash | ~90–150+ GB | ❌/experimental | 284B total, 13B active; 1M context; experimental llama.cpp support |
| DeepSeek-V4-Pro | Far above 128 GB | ❌ | 1.6T total parameters; server-class hardware |

For a 1M-context experiment, start with Qwen3.8-27B at its native context.
It leaves more memory for KV cache than the larger candidates.

## General rule

For Q4_K_M, use roughly 0.6 GB per billion parameters as a first estimate,
then reserve additional memory for the context and runtime. Always check the
exact GGUF file size and start with a conservative context.
