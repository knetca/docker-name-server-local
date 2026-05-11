# unbound — recursive DNS resolver
# Plain Alpine + unbound package. No opinions, no startup scripts.
# Config is bind-mounted from the repo at runtime.
# Runs as root — consistent with the rest of the stack.

ARG ALPINE_TAG=3.20
FROM alpine:${ALPINE_TAG}

RUN apk add --no-cache \
    unbound \
    drill

# Remove the default unbound config — ours is bind-mounted at runtime.
# Prevents any conflict between Alpine defaults and our config.
RUN rm -f /etc/unbound/unbound.conf

EXPOSE 53/udp 53/tcp

# -d: run in foreground (log to stderr, captured by Docker)
# -p "": disable pid file (not needed in a container)
# Config path matches the bind mount in docker-compose.yml
CMD ["unbound", "-d", "-p", "-c", "/etc/unbound/unbound.conf"]
