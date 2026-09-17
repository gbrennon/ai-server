# Switching the running model

The active model is selected in
[`profiles/gmktec-evo-x2.yml`](../../profiles/gmktec-evo-x2.yml):

```yaml
llamacpp_model_url: https://huggingface.co/<owner>/<repo>/resolve/main/<file>.gguf
llamacpp_model_file: <file>.gguf
```

Change both values, then deploy:

```bash
./scripts/deploy-remote.sh \
  192.168.0.2 \
  gbrennon-local-ai \
  profiles/gmktec-evo-x2.yml
```

The model task downloads the file only when it is missing. Deployment updates
the systemd service, restarts `llama-server`, and verifies `/health`. The old
model remains on disk for rollback.

## Verify

```bash
curl -s http://192.168.0.2:8080/v1/models | python3 -m json.tool
curl -s http://192.168.0.2:8080/props | python3 -m json.tool
ssh gbrennon-local-ai@192.168.0.2 \
  'journalctl -u llama-server -n 80 --no-pager | grep -E "model|context|offload|Vulkan"'
```

Refresh OMP's model metadata after the server restarts:

```bash
omp models refresh
omp models llama.cpp
```

## Already-downloaded models

There are two ways to skip the download when you already have the GGUF.

### On the target

If the GGUF is already in `/var/lib/llama.cpp/models/`, set
`llamacpp_model_file` to its exact filename. The download task will skip it.
Keep `llamacpp_model_url` valid for future deployments.

### On the controller (push a local copy)

If the GGUF only exists on the machine you run Ansible from, set
`llamacpp_model_src` to its absolute path. The models role rsyncs it to
`{{ llamacpp_models_dir }}/{{ llamacpp_model_file }}` on the target (resumable,
via `--rsync-path=sudo rsync`) and skips the download:

```yaml
llamacpp_model_src: /home/you/models/<file>.gguf   # path on THIS machine
llamacpp_model_file: <file>.gguf                    # bare filename on the target
```

Leave `llamacpp_model_src` empty (the default) to download from
`llamacpp_model_url` instead. The push relies on passwordless sudo on the
target, which `scripts/deploy-remote.sh` already checks.

## Multi-part GGUF files

Some models, including gpt-oss-120b, are published as multiple parts. Download
all parts separately and concatenate them in numeric order on the mini PC:

```bash
cat gpt-oss-120b-mxfp4-00001-of-00003.gguf \
    gpt-oss-120b-mxfp4-00002-of-00003.gguf \
    gpt-oss-120b-mxfp4-00003-of-00003.gguf \
  > /var/lib/llama.cpp/models/gpt-oss-120b-mxfp4.gguf
```

Set `llamacpp_model_file` to the resulting filename before deploying.

## Rollback and cleanup

Restore the previous URL and filename, then run the same deployment command.
After verifying the replacement, inspect old files before deleting them:

```bash
ssh gbrennon-local-ai@192.168.0.2 \
  'sudo du -h /var/lib/llama.cpp/models/*'
```
