#!/bin/bash
set -e

SOCKS5_PORT="${TAILSCALE_SOCKS5_PORT:-1055}"
HTTP_PROXY_PORT="${TAILSCALE_HTTP_PROXY_PORT:-1055}"
TS_STATE_DIR="/home/node/.openclaw/tailscale"

# Persist Tailscale state in the mounted volume so node identity
# survives container restarts and redeploys
mkdir -p "$TS_STATE_DIR"

echo "Starting Tailscale daemon (userspace networking)..."
echo "NOTE: Userspace networking provides SOCKS5/HTTP proxy only."
echo "      Direct TCP (e.g. SSH) must go through the proxy."
tailscaled \
  --tun=userspace-networking \
  --socks5-server=localhost:${SOCKS5_PORT} \
  --outbound-http-proxy-listen=localhost:${HTTP_PROXY_PORT} \
  --state="${TS_STATE_DIR}/tailscaled.state" &

# Wait for tailscaled to be ready
sleep 3

if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "Connecting to Tailscale network..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" $TAILSCALE_EXTRA_ARGS
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "unknown")
    echo "Tailscale connected. IP: ${TS_IP}"
    echo ""
    echo "=== IMPORTANT: Tailscale userspace networking mode ==="
    echo "Flux containers do not support kernel-level TUN devices."
    echo "Tailscale runs in userspace-networking mode, which means:"
    echo "  - 'tailscale ping' and 'tailscale status' work normally"
    echo "  - Direct TCP connections (SSH, etc.) do NOT go through Tailscale"
    echo "  - You MUST route traffic through the proxy:"
    echo ""
    echo "  SOCKS5 proxy: localhost:${SOCKS5_PORT}"
    echo "  HTTP proxy:   localhost:${HTTP_PROXY_PORT}"
    echo ""
    echo "  SSH example:"
    echo "    ssh -o ProxyCommand='nc -x localhost:${SOCKS5_PORT} %h %p' user@<tailscale-ip>"
    echo "  or with ncat:"
    echo "    ssh -o ProxyCommand='ncat --proxy-type socks5 --proxy localhost:${SOCKS5_PORT} %h %p' user@<tailscale-ip>"
    echo "  curl example:"
    echo "    curl --socks5 localhost:${SOCKS5_PORT} http://<tailscale-ip>:8080"
    echo "======================================================="
else
    echo "WARNING: TAILSCALE_AUTHKEY not set. Tailscale not connected."
fi

echo "Starting OpenClaw..."
exec openclaw "$@"
