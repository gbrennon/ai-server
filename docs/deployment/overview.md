# Deployment overview

This guide is the authoritative deployment procedure for the GMKtec EVO X2.

## Canonical deployment

Run deployment from the `ai-server` repository on the workstation:

```bash
make deploy-gmktec HOST=192.168.0.2 USER=gbrennon-local-ai
```

This command is the single supported deployment path for the GMKtec. It uses
`profiles/gmktec-evo-x2.yml`, which defines the ROCm/HIP backend, model, context
size, GPU offload, parallel factor, gateway, and runtime library path.

Use the setup variant only for a new host that still needs SSH key installation
and passwordless sudo:

```bash
make deploy-gmktec-setup HOST=192.168.0.2 USER=gbrennon-local-ai
```

Do not substitute `deploy-remote.sh` or `deploy-interactive.sh` for normal
GMKtec deployments. Those scripts are lower-level or generic entry points and
are not the source of truth for this host.

## Network addresses

Use the target IP only for deployment and SSH:

```text
SSH:       gbrennon-local-ai@192.168.0.2
Deployment: 192.168.0.2
```

Use the internal gateway domain for inference clients:

```text
API: https://api.ai-gbrennon.home.arpa
```

The gateway terminates TLS and forwards to llama-server on the target. Do not
send HTTPS requests to the IP address. The direct backend address is HTTP on
port `8080` and is for diagnostics only:

```text
Diagnostic backend: http://192.168.0.2:8080
```

Use the gateway hostname for Pi, OMP, and other OpenAI-compatible clients.
Use the direct backend only when diagnosing the gateway or checking local
llama-server health.

## Before deployment

- Confirm the target is reachable at `192.168.0.2`.
- Confirm SSH works as `gbrennon-local-ai`.
- Confirm the target has a dedicated power source.
- Confirm the target is not running the `evo-power-guard` daemon when testing
  the llama-server power behavior.

The deployment checks SSH, sudo, Ansible collections, the selected model, the
llama-server service, and the `/health` endpoint. It also sends a test chat
completion before returning success.

## Idempotency

Re-running the canonical deployment applies changed configuration and restarts
services when necessary. Existing model files are reused when their configured
filename is present on the target.

Successful deployment also registers the profile-owned provider in Pi and OMP.
To remove that provider from both clients without changing the remote server:

```bash
make unregister-gmktec-model
```

Re-running the canonical deployment restores the registration from the profile.

## Gateway verification

The profile enables the Caddy TLS gateway and dnsmasq resolver. Verify the
client-facing endpoint after deployment:

```bash
curl -fsS https://api.ai-gbrennon.home.arpa/health
```

The expected response is:

```json
{"status":"ok"}
```

See [gateway.md](gateway.md) for gateway trust installation and diagnostics.
