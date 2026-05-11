# chrony — NTP server
# Plain Alpine + chrony package. No startup scripts, no env var generation.
# Config is bind-mounted from the repo at runtime.
# Runs as root — consistent with the rest of the stack.

ARG ALPINE_TAG=3.20
FROM alpine:${ALPINE_TAG}

RUN apk add --no-cache \
    chrony

# Remove Alpine default chrony config — ours is bind-mounted at runtime.
RUN rm -f /etc/chrony/chrony.conf

# -d: run in foreground
# -x: disable system clock adjustment — container tracks and serves NTP
#     only, does not modify the host clock (equivalent to LXC DAEMON_OPTS=-x)
# -f: config file path matches bind mount in docker-compose.yml
CMD ["chronyd", "-d", "-x", "-f", "/etc/chrony/chrony.conf"]
