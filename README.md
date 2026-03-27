# OpenClaw + Tailscale for Flux Cloud

Docker image that bundles [OpenClaw](https://github.com/openclaw/openclaw) with [Tailscale](https://tailscale.com/) using **userspace networking** — no `NET_ADMIN` capability required. Designed to run on [Flux Cloud](https://runonflux.io/) where privileged containers are not available.

## How it works

Since Flux Cloud does not allow `--cap-add=NET_ADMIN` or `--privileged`, Tailscale runs in **userspace networking mode** (`--tun=userspace-networking`). Instead of creating a TUN interface, it exposes local SOCKS5 and HTTP proxies that route traffic through the Tailscale network.

```
Container
+------------------------------------------+
|  tailscaled (userspace networking)       |
|    SOCKS5 proxy  -> localhost:1055       |
|    HTTP proxy    -> localhost:1055       |
|         |                                |
|         +---> Tailscale network (encrypted WireGuard) ---> Your devices
|                                          |
|  openclaw (main process)                 |
+------------------------------------------+
```

## Quick start

```bash
docker run \
  -e TAILSCALE_AUTHKEY=tskey-auth-xxxxx \
  -e TAILSCALE_HOSTNAME=my-openclaw \
  runonflux/openclaw-tailscale:latest
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `TAILSCALE_AUTHKEY` | *(required)* | Tailscale auth key. Generate at [Tailscale Admin](https://login.tailscale.com/admin/settings/keys). Use an **ephemeral + reusable** key for containers. |
| `TAILSCALE_HOSTNAME` | `openclaw` | Hostname for the container on your tailnet. |
| `TAILSCALE_EXTRA_ARGS` | *(empty)* | Additional arguments passed to `tailscale up` (e.g. `--advertise-tags=tag:server`). |
| `TAILSCALE_SOCKS5_PORT` | `1055` | SOCKS5 proxy listen port. |
| `TAILSCALE_HTTP_PROXY_PORT` | `1055` | HTTP proxy listen port. |

## Accessing the Tailscale network

Because userspace networking does not create a network interface, applications must use the SOCKS5 proxy to reach other devices on your tailnet. Direct TCP connections (SSH, curl, etc.) will **not** route through Tailscale automatically.

```bash
# SSH into a Tailscale machine
ssh -o ProxyCommand='ncat --proxy-type socks5 --proxy localhost:1055 %h %p' user@100.64.0.1

# curl via SOCKS5
curl --socks5-hostname localhost:1055 http://100.64.0.1:8080

# Via HTTP proxy
HTTP_PROXY=http://localhost:1055 curl http://my-server.tail12345.ts.net
```

> **Tip:** Add a `~/.ssh/config` entry to avoid typing the proxy option every time:
> ```
> Host 100.*
>     ProxyCommand ncat --proxy-type socks5 --proxy localhost:1055 %h %p
> ```

## Tailscale state persistence

Tailscale state is stored in `/home/node/.openclaw/tailscale/` — inside the Flux persistent volume (`containerData`). This means the node identity survives container restarts and redeploys, preventing duplicate devices on your tailnet.

## Build locally

```bash
docker build -t runonflux/openclaw-tailscale:latest .
docker push runonflux/openclaw-tailscale:latest
```

## Automated rebuilds

A GitHub Actions workflow (`.github/workflows/rebuild-on-digest-change.yml`) checks every 6 hours if the upstream `ghcr.io/openclaw/openclaw:latest` image has changed. If the digest differs, it automatically rebuilds and pushes a new image.

### Required GitHub secrets

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

The workflow can also be triggered manually via `workflow_dispatch`.

## Project structure

```
.
├── Dockerfile                                  # OpenClaw + Tailscale image
├── start.sh                                    # Entrypoint: starts tailscaled then openclaw
├── README.md
└── .github/
    └── workflows/
        └── rebuild-on-digest-change.yml        # Auto-rebuild on upstream changes
```

## License

MIT
