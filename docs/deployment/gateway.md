# Gateway: Caddy reverse proxy + local DNS

An optional role that fronts `llama-server` with a TLS ingress (Caddy) and an
authoritative local resolver (dnsmasq), so client tools use stable hostnames in
the RFC 8375 safe zone instead of raw ports:

| Service | Hostname | What it is |
|---|---|---|
| Inference API | `https://api.ai-gbrennon.home.arpa` | Caddy reverse_proxy -> llama-server (SSE, `tls internal`) |
| Web UI (opt.) | `https://web.ai-gbrennon.home.arpa` | Caddy -> a web UI (Open-WebUI etc.) |
| DNS | `127.0.0.1:53` | `*.ai-gbrennon.home.arpa` -> the AI host LAN IP |

It is installed natively (not containers) as systemd services: `caddy` and
`dnsmasq`. It is **disabled by default**; opt in per host or per profile.

## Why

- **Stable URLs for tools**: Cline, Aider, and OpenHands all point at
  `https://api.ai-gbrennon.home.arpa` regardless of the llama-server port.
- **Correct streaming**: `flush_interval -1` disables Caddy's response
  buffering so llama.cpp Server-Sent Events (SSE) tokens reach clients
  immediately instead of stalling in chunks.
- **Large prompts**: the client request-body limit is disabled (`max_size 0`)
  for big context windows and embedding uploads.
- **Local TLS without public DNS**: `.home.arpa` never gets public ACME certs,
  so Caddy uses its own internal CA (`tls internal`).

## Enable

In `group_vars/all.yml` or a profile set the gateway on, then re-run the
playbook (or `make gateway-only` after the first full deploy):

```yaml
gateway_enabled: true
gateway_domain: ai-gbrennon.home.arpa
# gateway_api_hostname: api.ai-gbrennon.home.arpa   # defaults under gateway_domain
# gateway_lan_ip: 192.168.1.100            # defaults to this host's LAN IP
```

```bash
make gateway-only      # localhost  (or re-run the full playbook)
make trust-caddy-ca    # optional: trust Caddy's internal root CA system-wide
./scripts/verify-gateway.sh
```

### Optional web UI

Set `gateway_chat_enabled: true` and `gateway_chat_upstream: http://<web>:<port>`
to also expose `web.ai-gbrennon.home.arpa` (WebSocket + SSE pass through transparently).

## What the role does

- Installs `dnsmasq` and an authoritative zone config
  (`address=/<domain>/<ip>` -> a real `*.ai-gbrennon.home.arpa` wildcard).
- Installs the pinned official Caddy static binary and a hardened systemd unit
  (drops to a `caddy` user, `CAP_NET_BIND_SERVICE`, strict sandboxing).
- Renders `/etc/caddy/Caddyfile` and `/etc/dnsmasq.d/ai-gateway.conf` from
  templates.
- Opens firewall ports `53/tcp`, `53/udp`, `80/tcp`, `443/tcp`.

Because Caddy runs as a host service, its `reverse_proxy` target is
`127.0.0.1:<gateway_llama_port>` directly.

## Verify & troubleshoot

- `dig @127.0.0.1 -p 53 api.ai-gbrennon.home.arpa +short` prints the LAN IP.
- `curl -k https://api.ai-gbrennon.home.arpa/health` returns `{"status":"ok"}`.
- `curl -k -N https://api.ai-gbrennon.home.arpa/v1/models` returns HTTP 200 over local TLS.

| Symptom | Check |
|---|---|
| DNS empty | `systemctl status dnsmasq`; `make gateway-only` re-renders the conf |
| TLS errors on clients | `sudo ./scripts/trust-caddy-ca.sh` (new CA after data dir wipe) |
| SSE stalls | confirm `flush_interval -1` is in `/etc/caddy/Caddyfile` |
| Want hostnames for other tools | run dnsmasq on `127.0.0.1` and point the tools at it |

All gateway files live in `roles/gateway/`; the wire-up is in `site.yml` and
`group_vars/all.yml`.
