# Switch report: IQ3 dense 27B to Coder 30B-A3B

Decision record for replacing the dedicated-box served model with
`Qwen3-Coder-30B-A3B-Instruct-Q4_K_M` behind the unchanged provider name
`gbrennon-ai-server`. Written autonomously; verify against the evidence below.

## Problem

The previously served model, `Qwen3.8-27B-GSQ-RCO-IQ3_XXS` (dense 27B at
3-bit), could call tools but mangled structured tool arguments. At 3-bit it
serialized list and object arguments as malformed text, which broke agentic
coding: selective staging of one path, committing with a message, and shell
commands that take an args array. It also needed `--reasoning off` to stop
thousands of tokens of reasoning with no tool call, and decoded at only
~13.3 tok/s.

## Decision

Serve `Qwen3-Coder-30B-A3B-Instruct` at `Q4_K_M`. It is a coding-tuned sparse
MoE (128 experts, 8 used per token; ~3.3B active of ~30.53B). Four-bit
precision restores reliable structured tool-argument serialization, the MoE
shape makes decoding much faster, and the coder-instruct tuning calls tools
directly without the reasoning workaround.

## Why this model and quant

- Quant `Q4_K_M` (4.86 BPW), not a 3-bit quant: 3-bit was the root cause of the
  mangled JSON arguments. Four-bit is the smallest quant that reliably keeps
  tool-argument structure intact for this family.
- MoE over dense: ~3.3B active parameters per token decode about 2.4x faster
  than the dense 27B while fitting the 96 GB iGPU carve with large KV headroom.
- Coder-instruct tuning: prefers tool calls over prose, removing the need for
  `--reasoning off` and reducing wasted tokens per agent turn.
- Native 262144 context: matches the prior served context, so no client-side
  context assumptions change.

## Configuration decisions

Profile: `profiles/gmktec-evo-x2.yml`.

- `--jinja`: required so llama.cpp uses the model's embedded chat template and
  parses Qwen3-Coder's native tool-call format into OpenAI `tool_calls`.
- Sampling per the Qwen3-Coder card: `--temp 0.7 --top-p 0.8 --top-k 20
  --repeat-penalty 1.05`. The old profile's aggressive penalties and `--temp
  0.2` were tuning for the 3-bit dense model and were removed.
- Dropped `--reasoning off`: Coder-Instruct has no thinking mode, so the flag
  is moot; `client_reasoning: false` stays.
- Kept `-ngl 99`, ROCm device, flash-attn, `q8_0` KV cache, `--parallel 1`,
  `--n-predict 4096`, `llamacpp_ctx_size: 262144`, and `client_max_tokens: 4096`.

## Deployment mechanics and the partial-file landmine

- The box had a truncated 4.4 GB partial of the Coder GGUF in the managed dir.
  The Ansible download task guards on `creates:` (existence only, not size), so
  a plain redeploy would have skipped the download and served the truncated
  file. This was caught and avoided.
- The managed dir (`/var/lib/llama.cpp/models`) is on the small 70 GB root
  filesystem; a full 17.3 GB copy does not fit there alongside other models.
  The model was downloaded to the 1.8 TB `/home` volume, byte-verified against
  the expected size (18,556,689,568), and exposed to the service through a
  symlink in the managed dir -- the same pattern the box already used for the
  `2507` model.
- `deploy-gmktec.sh` then installed the updated unit, restarted the service,
  passed `/health`, and re-registered `gbrennon-ai-server` with model id
  `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf` at context 262144.

## Verification evidence

- GGUF identity read from the file header: `general.name =
  Qwen3-Coder-30B-A3B-Instruct`, `general.finetune = Instruct`, arch
  `qwen3moe`, `size_label = 30B-A3B`.
- Live load: arch `qwen3moe`, 48 layers, 128 experts / 8 used, `Q4_K_M`
  4.86 BPW (17.28 GiB), `n_ctx` 262144.
- Direct tools request: `finish_reason: tool_calls` with valid JSON arguments,
  including `{"command":"cargo","args":["test"]}` (string array serialized
  correctly) and a properly escaped multi-line `content` string.
- Throughput from live timings: ~995 tok/s prefill, ~38.8 tok/s decode.
- Agentic `omp` smoke test: wrote a file, shell-verified it, replied cleanly.
- Agentic `omp` git test: staged only the requested path, committed with `-m`,
  left the other file modified and unstaged -- the scenario that failed before.

## Trade-offs, risks, and rollback

- Larger footprint: 17.3 GB vs 9.5 GB, still well within the iGPU carve.
- Symlink dependency: the served file lives under `/home`; if that volume is
  unmounted the symlink breaks. Acceptable given the box's existing precedent
  and the root volume being too small for the file.
- Old GGUFs remain on disk unused. They were left in place (non-destructive)
  rather than deleted; cleanup is a separate, reversible follow-up.
- Rollback: point `llamacpp_model_file`/`llamacpp_model_url` back at the prior
  GGUF and redeploy; the retired files are still present.

## Open items

- Optionally prune retired GGUFs to reclaim space on the dedicated box.
- Optionally run a full `pr-auto-reviewer` pass end to end; its core failure
  mode (selective git tool args) is already reproduced as fixed here.
- Profile change is staged on branch `feat/register-model` and not yet
  committed; commit when ready.
