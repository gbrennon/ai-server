# AMD Halo playbook performance adjustment

Research date: 2026-10-30.

This note maps AMD's official Ryzen AI Halo playbooks and the Compute Market
Strix Halo review to the GMKtec EVO-X2 runtime, then records the setting that
was applied and measured.

## Hardware match

The AMD playbooks identify Ryzen AI Halo as the Ryzen AI Max+ family and target
`gfx1151`, the same GPU architecture reported by this GMKtec EVO-X2:

- Radeon 8060S;
- Ryzen AI Max+ 395;
- ROCm/HIP on `ROCm0`;
- 128 GB unified memory;
- Linux shared-memory GPU allocation.

AMD's official source is the [AMD Playbooks repository][amd-repo]. The relevant
Halo guides are the [Qwen3-Coder/VS Code playbook][amd-qwen] and the [Halo RPC
playbook][amd-rpc].

## AMD-recommended inference settings

The Qwen3-Coder Halo playbook uses a 32,768-token context, maximum GPU offload,
and Flash Attention. The RPC playbook's llama.cpp examples use:

- `-c 32768`;
- `-fa on`;
- `-ngl 999`;
- `-lm none` for very large models that exceed normal system RAM but fit the
  available accelerator memory.

The `-ngl 999` example is from AMD's two-node RPC launch for a 358B model. It
is an explicit maximum-offload convention, not a published single-node 1.5B
optimization result. The local change aligns the command with that convention;
it does not assume that the numeric change alone improves this small model.

The existing deployment already had the first two settings, one slot, q8_0 K/V
cache, reasoning disabled, and full ROCm offload. The only safe direct mismatch
was the explicit offload value: the profile used `-ngl 99` instead of AMD's
`-ngl 999`.

## Applied change

Changed `profiles/gmktec-evo-x2.yml` and the temporary benchmark launcher from:

```text
-ngl 99
```

to:

```text
-ngl 999
```

The running service was redeployed and verified with the new command line. No
profile change was made to batch or ubatch sizes because llama.cpp already
reports the AMD-compatible defaults of 2048 and 512. Flash Attention was already
on.

## Controlled local measurement

The same Qwen2.5-Coder-1.5B Q4_K_M model was tested with three short and three
fresh 8,110-token requests. Prompt caching was disabled, with one slot and a
32K context in both runs.

| Setting | Short decode | Long decode | Short end-to-end | Long end-to-end |
| --- | ---: | ---: | ---: | ---: |
| `-ngl 99` | 132.13 tok/s | 119.05 tok/s | 121.00 tok/s | 50.08 tok/s |
| `-ngl 999` | **135.72 tok/s** | **120.38 tok/s** | **124.00 tok/s** | **50.27 tok/s** |

The A/B result is **observational, not statistically proven**: it contains only
three runs per setting and no confidence interval or randomized interleaving.
The modest differences should therefore be treated as no proven optimization,
with `-ngl 999` retained for explicit AMD-style full-offload conformance.

The `-ngl 999` run peaked at 74 C GPU edge and 74 C ACPI. The service was
restored afterward and remained healthy with zero restarts.

## Expected token rates from the sources

The Compute Market review is directional and explicitly warns that rates vary
with model, quantization, context, backend, and benchmark boundary. Its same-
class reference values include:

| Workload | Reported rate | Comparability |
| --- | ---: | --- |
| Small dense under 10B | 40--80 tok/s | Broad directional range |
| Qwen3-Coder-class Q4 | About 100 tok/s | Community-reported |
| Strix Halo Llama 7B Q4 | 50.59--55.73 tok/s | ROCm/Vulkan grid |
| Strix Halo gpt-oss 20B | 72.68--79.78 tok/s | ROCm/Vulkan grid |
| Strix Halo gpt-oss 120B | 51.02--56.61 tok/s | ROCm/Vulkan grid |

The local 1.5B result above 130 tok/s is not contradictory: it is a much
smaller model than the review's broad small-model examples, and the local test
uses a specific ROCm build, quantization, prompt, and one-slot configuration.
The local Qwen3-Coder 30B result of about 70 tok/s is consistent with the
review's approximately 100 tok/s community claim being configuration-dependent,
not a guaranteed rate.

## Settings deliberately not changed

### AMD TTM / 120 GB shared memory

The official RPC playbook documents `amd-ttm --set 120` for Linux shared-memory
allocation and requires a reboot. The live host does not have `amd-ttm`
installed. ROCm already exposes 103 GB, with about 2 GB used at idle and the
current 1.5B service healthy. Increasing the allocation would primarily improve
model capacity and large-context headroom; it is not expected to increase decode
rate for a 1.5B model. It was not installed or changed without an A/B test and
rollback plan.

### `-lm none` / no memory mapping

AMD documents this for very large models that exceed normal system RAM but fit
in accelerator memory. The active 1.5B model does not meet that condition, so
no-mmap was not applied. It could change load behavior without improving the
steady-state token rate for this model.

## Final state

The active profile now uses:

```text
-ngl 999 --device ROCm0 --flash-attn on
--cache-type-k q8_0 --cache-type-v q8_0
--split-mode layer --parallel 1
```

The service is active, healthy, zero-restart, and uses the selected 1.5B model
with a 32,768-token context. All three downloaded candidate models remain on
the mini PC.

[amd-repo]: https://github.com/amd/playbooks
[amd-qwen]: https://developer.amd.com/playbooks/vscode-qwen3-coder/
[amd-rpc]: https://developer.amd.com/playbooks/clustering-rpc-server/
