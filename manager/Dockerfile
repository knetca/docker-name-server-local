# dns-manager — zone sync and blocklist management for docker-dns stack
#
# Handles:
#   - Polling a git zones repo and reloading Unbound on change
#   - Fetching the OISD blocklist daily and reloading Unbound
#
# Both jobs call unbound-control directly (host networking, loopback, no TLS).

ARG ALPINE_TAG=3.20
FROM alpine:${ALPINE_TAG}

RUN apk add --no-cache \
    git \
    curl \
    unbound \
    dcron \
    openssh-client \
    tzdata

# Scripts are copied in and made executable at build time.
# No runtime package installation — image is self-contained.
COPY scripts/deploy-zones.sh /usr/local/bin/deploy-zones.sh
COPY scripts/update-blocklist.sh /usr/local/bin/update-blocklist.sh
COPY entrypoint.sh /entrypoint.sh

# Seed files — copied to zones volume on first start if not already present.
# Ensures Unbound's include glob never matches an empty directory.
COPY seed/ /etc/dns-manager/seed/

RUN chmod +x \
    /usr/local/bin/deploy-zones.sh \
    /usr/local/bin/update-blocklist.sh \
    /entrypoint.sh \
    && chmod 644 /etc/dns-manager/seed/*.conf

# SSH client config — accept known_hosts from bind mount, strict host checking.
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh
COPY ssh_config /root/.ssh/config

ENTRYPOINT ["/entrypoint.sh"]
