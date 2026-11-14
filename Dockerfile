# SPDX-License-Identifier: GPL-3.0-or-later
ARG SINGBOX_VERSION=1.14.2
ARG DEBIAN_VERSION=bookworm-slim

FROM ghcr.io/sagernet/sing-box:v${SINGBOX_VERSION} AS singbox

FROM debian:${DEBIAN_VERSION}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates nftables iproute2 jq \
    && rm -rf /var/lib/apt/lists/*

COPY --from=singbox /usr/local/bin/sing-box /usr/local/bin/sing-box
COPY config.json /etc/sing-box/config.json
COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
COPY render_config.sh /render_config.sh
COPY render_config.jq /render_config.jq
COPY LICENSE LICENSE.sing-box THIRD_PARTY_NOTICES.md /usr/share/doc/docker-singbox-tun-gateway/

LABEL org.opencontainers.image.title="docker-singbox-tun-gateway" \
      org.opencontainers.image.description="sing-box TUN gateway for a shared container network namespace" \
      org.opencontainers.image.authors="2070800 <no@email.me>" \
      org.opencontainers.image.source="https://github.com/2070800/docker-singbox-tun-gateway" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

RUN chmod 0755 /entrypoint.sh /healthcheck.sh /render_config.sh

ENV SINGBOX_CONFIG_FILE=/etc/sing-box/config.json

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
