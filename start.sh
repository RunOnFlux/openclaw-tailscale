#!/bin/bash
set -e

SOCKS5_PORT="${TAILSCALE_SOCKS5_PORT:-1055}"
HTTP_PROXY_PORT="${TAILSCALE_HTTP_PROXY_PORT:-1055}"

echo "Starting Tailscale daemon (userspace networking)..."
tailscaled \
  --tun=userspace-networking \
  --socks5-server=localhost:${SOCKS5_PORT} \
  --outbound-http-proxy-listen=localhost:${HTTP_PROXY_PORT} \
  --state=/var/lib/tailscale/tailscaled.state &

# Wait for tailscaled to be ready
sleep 3

if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "Connecting to Tailscale network..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" $TAILSCALE_EXTRA_ARGS
    echo "Tailscale connected. IP: $(tailscale ip -4)"
    echo "SOCKS5 proxy: localhost:${SOCKS5_PORT}"
    echo "HTTP proxy:   localhost:${HTTP_PROXY_PORT}"
else
    echo "WARNING: TAILSCALE_AUTHKEY not set. Tailscale not connected."
fi

echo "Starting OpenClaw..."
exec openclaw "$@"
