# Base image: pin to the latest STABLE OpenClaw release (a YYYY.M.D tag), never
# :latest. Upstream's :latest is an alias of :main — a rolling build of their
# main branch (unreleased code) — so following it rebuilt this image whenever
# main advanced and restarted every Flux deployment onto unreleased builds. The
# rebuild workflow (.github/workflows/rebuild-on-new-release.yml) auto-bumps the
# published image to the newest stable tag when upstream cuts a release, passing
# it as --build-arg OPENCLAW_VERSION. This default is the fallback for local
# builds; override with: --build-arg OPENCLAW_VERSION=YYYY.M.D
ARG OPENCLAW_VERSION=2026.5.22
FROM ghcr.io/openclaw/openclaw:${OPENCLAW_VERSION}

USER root

# Install Tailscale
RUN apt-get update && \
    apt-get install -y curl gnupg lsb-release && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && \
    apt-get install -y tailscale ncat && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create state directory for Tailscale
RUN mkdir -p /var/run/tailscale /var/lib/tailscale

# Ensure OpenClaw config directory exists
RUN mkdir -p /home/node/.openclaw

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENV TAILSCALE_AUTHKEY=""
ENV TAILSCALE_HOSTNAME="openclaw"
ENV TAILSCALE_EXTRA_ARGS=""
ENV HOME=/home/node

CMD ["/start.sh"]
