# Operations

## Health and API checks

```bash
curl http://<mini-pc-ip>:8080/health
curl http://<mini-pc-ip>:8080/v1/models

curl http://<mini-pc-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"llama","messages":[{"role":"user","content":"Say hello"}],"max_tokens":50}'
```

The web UI is available at `http://<mini-pc-ip>:8080/`.

## Service control

```bash
sudo systemctl status llama-server
sudo journalctl -u llama-server -f
sudo systemctl restart llama-server
sudo systemctl stop llama-server
sudo systemctl disable llama-server
```

Apply configuration changes with:

```bash
sudo ./bootstrap.sh
```

For remote model changes, use [model switching](../models/switching.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| Service will not start | `sudo journalctl -u llama-server -e`; check for OOM |
| Unreachable from LAN | `sudo firewall-cmd --list-ports` should include `8080/tcp` |
| No GPU acceleration | Check [GPU offload](../hardware/gpu-offload.md) |
| Model OOM | Lower context, use a smaller quantization, or choose a smaller model |
| Remote deployment fails | Confirm SSH, passwordless sudo, and `python3` |

Avoid running a large CPU-only model interactively on a machine that must stay
responsive. Stop the service directly if needed:

```bash
sudo systemctl stop llama-server
```

## Uninstall

```bash
sudo systemctl disable --now llama-server
sudo rm /etc/systemd/system/llama-server.service
sudo systemctl daemon-reload
sudo rm -rf /opt/llama.cpp /var/lib/llama.cpp /var/log/llama.cpp
sudo userdel llamacpp
```
