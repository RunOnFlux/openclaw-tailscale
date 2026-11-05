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

## Base image version & automated rebuilds

This image pins to upstream's **stable releases** — the `YYYY.M.D` tags of `ghcr.io/openclaw/openclaw`, never `:latest`. Upstream's `:latest` is an alias of `:main` (a rolling build of their main branch, i.e. unreleased code); following it rebuilt this image whenever `main` advanced and restarted every Flux deployment onto unreleased builds. The pinned default lives in the `Dockerfile` (`ARG OPENCLAW_VERSION`) and is overridable at build time with `--build-arg OPENCLAW_VERSION=YYYY.M.D`.

A GitHub Actions workflow (`.github/workflows/rebuild-on-new-release.yml`) runs daily and **follows new stable releases automatically**: it detects the newest stable `YYYY.M.D[-N]` tag on GHCR (excluding `-slim` variants and `-alpha`/`-beta`/`-rc` pre-releases), compares it to the version baked into the currently-published image (label `org.opencontainers.image.base.version`), and rebuilds **only when a genuinely new release appears**. It pushes `:latest` and `:<version>`. It also rebuilds when `Dockerfile` or `start.sh` change on `main`, and on manual dispatch (`force_version` pins a specific release).

- GHCR lists at most 1000 tags per page, so the workflow follows the `Link` header to read all of them.
- `MAX_VERSION` in the workflow holds the scheduled job at a release. Leave it empty to follow upstream.
- A daily call to the workflow's `enable` endpoint stops GitHub from disabling the schedule after 60 days without commits.
- Flux nodes soft-redeploy an app when the `:latest` digest changes, so every real rebuild reaches running apps within hours. Use the `:<version>` tags to pin an app.

### Upgrading from older OpenClaw state

OpenClaw refuses to start on state written before its migrations have run, and the migration has to run while the gateway is stopped. `start.sh` therefore runs `openclaw doctor --fix --non-interactive` once per image version, before the gateway, and records it with a marker file (`/home/node/.openclaw/.flux-doctor-<version>`). A Doctor failure is logged and retried on the next start, and never blocks the gateway from starting.

Installations older than July 2026 should go through `2026.9.5` first (upstream's documented bridge). The `:2026.9.5` image does that on its own at first start.

### Behind Flux's FDM proxy (OpenClaw 2026.11 and later)

OpenClaw 2026.11 answers `403 proxy_attribution_required` to any request that carries proxy headers (`X-Forwarded-For`, which FDM always adds) unless the connection comes from an address in `gateway.trustedProxies`. FDM's addresses are not fixed, so `start.sh` makes the setup address independent: when the command is `gateway` it moves the gateway to `127.0.0.1:<port+1>` (rewriting `--port` and `--bind`, which win over environment variables), starts a `socat` relay on the published port, and adds `127.0.0.1/32` and `::1/128` to `gateway.trustedProxies` (existing entries are kept). The relay forwards bytes untouched, so the gateway sees the client address FDM appended to `X-Forwarded-For`. A supervisor loop restarts the relay if it dies.

Things to know:

- The relay needs a gateway password or token and is skipped without one (the gateway then refuses to bind publicly, as before).
- The gateway cannot tell FDM from a client that connects to the published port directly, so such a client chooses its own address for per-IP limits (for example the failed-login limiter). Authentication is still required, so use a strong password or token.
- `FLUX_PROXY_RELAY=0` disables all of this. `FLUX_GATEWAY_INTERNAL_PORT` changes the internal port (default: public port + 1).
- The Control UI still has to be reached from an allowed origin (`gateway.controlUi.allowedOrigins` or `gateway.publicOrigin`).

### Required GitHub secrets

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub username |
| `DOCKERHUB_TOKEN` | Docker Hub access token |

## Project structure

```
.
├── Dockerfile                                  # OpenClaw + Tailscale image
├── start.sh                                    # Entrypoint: starts tailscaled then openclaw
├── README.md
└── .github/
    └── workflows/
        └── rebuild-on-new-release.yml          # Auto-rebuild on new stable upstream release
```

## License

MIT
