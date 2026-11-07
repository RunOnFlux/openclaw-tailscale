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
    if tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TAILSCALE_HOSTNAME" $TAILSCALE_EXTRA_ARGS; then
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
        echo "ERROR: Tailscale failed to connect (bad auth key or network issue)."
        echo "       OpenClaw will start WITHOUT Tailscale networking."
        echo "       Please check your TAILSCALE_AUTHKEY and redeploy."
    fi
else
    echo "WARNING: TAILSCALE_AUTHKEY not set. Tailscale not connected."
fi

# Newer OpenClaw releases refuse to start on state written by older ones until
# "openclaw doctor --fix" has migrated it (2026.9.5 is the required bridge for
# anything older than July 2026). Run it once per image version, tracked by a
# marker inside the persistent volume. A Doctor failure must not stop the
# gateway from starting, so its exit code is only logged.
DOCTOR_MARKER="/home/node/.openclaw/.flux-doctor-${FLUX_IMAGE_OPENCLAW_VERSION:-unknown}"
if [ -n "$FLUX_IMAGE_OPENCLAW_VERSION" ] && [ ! -f "$DOCTOR_MARKER" ]; then
    echo "Running openclaw doctor --fix for ${FLUX_IMAGE_OPENCLAW_VERSION} (first start of this version)..."
    # Bounded so a stuck Doctor cannot keep the gateway from ever starting.
    if timeout 900 openclaw doctor --fix --non-interactive; then
        touch "$DOCTOR_MARKER"
    else
        echo "WARNING: openclaw doctor exited non-zero; will retry on next start."
    fi
fi

# The once-per-version Doctor run above is not enough on its own: the config
# can become invalid AFTER it ran (the Flux spec seeds openclaw.json with a
# key newer releases reject, a restored backup or a synced volume can bring
# one back). OpenClaw then exits with code 78 on every start, the container
# stays down, and a restart or failover hits the same file. So validate on
# every start and repair what is wrong. Nothing here is fatal: if the config
# is still invalid afterwards, OpenClaw prints its own error.
#
# Step 1 is surgical: drop the one key the Flux spec seeds and 2026.11 removed
# (gateway.controlUi.allowInsecureAuth), touching nothing else. Doctor is the
# fallback for anything else, but it also resets settings the owner chose in
# the UI (it switched an enabled skill back off in testing), so it goes second.
strip_removed_seed_key() {
    CFG="${OPENCLAW_CONFIG_DIR:-/home/node/.openclaw}/openclaw.json" node -e '
        const fs = require("fs");
        const f = process.env.CFG;
        let d;
        try { d = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { process.exit(3); }
        const ui = d && d.gateway && d.gateway.controlUi;
        if (!ui || typeof ui !== "object" || !("allowInsecureAuth" in ui)) process.exit(3);
        delete ui.allowInsecureAuth;
        const mode = fs.statSync(f).mode & 0o777;
        const tmp = f + ".flux-tmp";
        fs.writeFileSync(tmp, JSON.stringify(d, null, 2) + "\n", { mode });
        fs.renameSync(tmp, f);
    '
}

if ! timeout 120 openclaw config validate >/dev/null 2>&1; then
    echo "OpenClaw config is invalid; trying to repair it..."
    if strip_removed_seed_key; then
        echo "Removed gateway.controlUi.allowInsecureAuth, which this OpenClaw release no longer accepts."
    fi
    if ! timeout 120 openclaw config validate >/dev/null 2>&1; then
        echo "Running openclaw doctor --fix..."
        timeout 300 openclaw doctor --fix --non-interactive || echo "WARNING: openclaw doctor exited non-zero."
    fi
    if timeout 120 openclaw config validate >/dev/null 2>&1; then
        echo "OpenClaw config repaired."
    else
        echo "WARNING: OpenClaw config is still invalid after repair."
    fi
fi

# OpenClaw 2026.11 refuses requests that carry proxy headers (X-Forwarded-For,
# which Flux's FDM always adds) unless the connection comes from an address in
# gateway.trustedProxies, and FDM's addresses are not fixed. So the gateway
# listens on loopback only, a plain TCP relay owns the published port, and
# loopback is the one trusted proxy: the gateway then reads the real client
# address from the X-Forwarded-For that FDM appended. The relay forwards bytes
# untouched, so headers and WebSockets pass through as they are.
#
# Trade-off, by design: the gateway can no longer tell FDM from a client that
# connects to the published port directly, so a direct client chooses its own
# address for per-IP limits. Authentication is still required, and the relay is
# skipped when no gateway password or token is configured. Disable with
# FLUX_PROXY_RELAY=0.
gateway_has_auth() {
    [ -n "${OPENCLAW_GATEWAY_PASSWORD:-}" ] && return 0
    [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && return 0
    MODE=$(timeout 30 openclaw config get gateway.auth.mode 2>/dev/null | tr -d '"[:space:]')
    [ "$MODE" = "token" ] || [ "$MODE" = "password" ]
}

# Keep whatever the owner already trusts and add loopback; skip the write (and
# the config backup rotation it causes) when loopback is already there.
ensure_loopback_trusted_proxy() {
    CURRENT=$(timeout 30 openclaw config get gateway.trustedProxies --json 2>/dev/null || echo '[]')
    MERGED=$(CURRENT="$CURRENT" node -e '
        let cur = [];
        try { const v = JSON.parse(process.env.CURRENT); if (Array.isArray(v)) cur = v.filter((x) => typeof x === "string"); } catch (e) {}
        const want = ["127.0.0.1/32", "::1/128"];
        if (want.every((w) => cur.includes(w))) process.exit(3);
        console.log(JSON.stringify([...cur, ...want.filter((w) => !cur.includes(w))]));
    ') && RC=0 || RC=$?
    if [ "$RC" = "3" ]; then return 0; fi
    [ "$RC" = "0" ] && [ -n "$MERGED" ] && timeout 60 openclaw config set gateway.trustedProxies "$MERGED" >/dev/null 2>&1
}

if [ "${FLUX_PROXY_RELAY:-1}" = "1" ] && [ "${1:-}" = "gateway" ] && command -v socat >/dev/null 2>&1; then
    PUBLIC_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
    PREV=""
    for ARG in "$@"; do
        [ "$ARG" = "--" ] && break
        case "$ARG" in
            --port=*) PUBLIC_PORT="${ARG#--port=}" ;;
        esac
        if [ "$PREV" = "--port" ]; then PUBLIC_PORT="$ARG"; fi
        PREV="$ARG"
    done

    if ! [[ "$PUBLIC_PORT" =~ ^[0-9]+$ ]] || [ "$PUBLIC_PORT" -lt 1 ] || [ "$PUBLIC_PORT" -gt 65534 ]; then
        echo "WARNING: unusable gateway port '${PUBLIC_PORT}'; starting without the proxy relay."
    elif ! gateway_has_auth; then
        echo "WARNING: no gateway password or token configured; starting without the proxy relay."
    else
        INTERNAL_PORT="${FLUX_GATEWAY_INTERNAL_PORT:-$((PUBLIC_PORT + 1))}"
        if ensure_loopback_trusted_proxy; then
            # Rewrite --port / --bind wherever the caller put them (the Flux
            # spec passes both, and flags win over environment variables).
            NEW_ARGS=()
            PREV=""
            REST=0
            for ARG in "$@"; do
                if [ "$REST" = "1" ]; then
                    NEW_ARGS+=("$ARG")
                elif [ "$ARG" = "--" ]; then
                    REST=1
                    NEW_ARGS+=("$ARG")
                elif [ "$PREV" = "--port" ]; then
                    NEW_ARGS+=("$INTERNAL_PORT")
                elif [ "$PREV" = "--bind" ]; then
                    NEW_ARGS+=("loopback")
                else
                    case "$ARG" in
                        --port=*) NEW_ARGS+=("--port=$INTERNAL_PORT") ;;
                        --bind=*) NEW_ARGS+=("--bind=loopback") ;;
                        *) NEW_ARGS+=("$ARG") ;;
                    esac
                fi
                PREV="$ARG"
            done
            set -- "${NEW_ARGS[@]}"
            export OPENCLAW_GATEWAY_PORT="$INTERNAL_PORT"
            export OPENCLAW_GATEWAY_BIND="loopback"
            echo "Proxy relay: 0.0.0.0:${PUBLIC_PORT} -> 127.0.0.1:${INTERNAL_PORT}"
            (
                # set -e would end this loop the first time socat dies, which is
                # exactly when it has to come back.
                set +e
                while true; do
                    socat "TCP-LISTEN:${PUBLIC_PORT},fork,reuseaddr" "TCP:127.0.0.1:${INTERNAL_PORT}"
                    echo "WARNING: proxy relay exited, restarting in 1s"
                    sleep 1
                done
            ) &
        else
            echo "WARNING: could not set gateway.trustedProxies; starting without the proxy relay."
        fi
    fi
fi

echo "Starting OpenClaw..."
exec openclaw "$@"
