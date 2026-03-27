FROM ghcr.io/openclaw/openclaw:latest

USER root

# Install Tailscale
RUN apt-get update && \
    apt-get install -y curl gnupg lsb-release && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null && \
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list && \
    apt-get update && \
    apt-get install -y tailscale && \
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
