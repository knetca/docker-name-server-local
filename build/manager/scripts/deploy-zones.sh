#!/bin/sh
# deploy-zones.sh — poll zones git repo, deploy on change, reload Unbound
#
# On each cron invocation:
#   1. Clone repo if not present, otherwise fetch and fast-forward
#   2. Compare HEAD before and after — exit early if no change
#   3. Copy *.conf from zones/ in the repo to the shared zones volume
#   4. Validate Unbound config
#   5. Reload Unbound (preserves cache)
#
# unbound-control connects to 127.0.0.1:8953 (host networking, no TLS).
set -eu

# Add random jitter to avoid thundering herd if many instances are running
# with the same schedule.
JITTER_MAX="${JITTER_MAX:-60}"
if [ "${JITTER_MAX}" -gt 0 ]; then
    sleep $(( RANDOM % JITTER_MAX ))
fi

ZONES_REPO="${ZONES_REPO:?}"
ZONES_BRANCH="${ZONES_BRANCH:-main}"
ZONES_TIMEOUT="${ZONES_TIMEOUT:-60}"
WORK_DIR="/var/lib/dns-manager/zones"
ZONE_DEST="/etc/unbound/zones"

log() { echo "$(date -Iseconds) [deploy-zones] $*"; }

# --- Clone or update ---
if [ ! -d "${WORK_DIR}/.git" ]; then
    find "${WORK_DIR:?}" -mindepth 1 -delete
    log "Cloning ${ZONES_REPO} branch=${ZONES_BRANCH}"
    if ! timeout "${ZONES_TIMEOUT}" git clone --branch "${ZONES_BRANCH}" --single-branch \
        "${ZONES_REPO}" "${WORK_DIR}"; then
        log "ERROR: git clone failed or timed out after ${ZONES_TIMEOUT} seconds"
        find "${WORK_DIR:?}" -mindepth 1 -delete
        exit 1
    fi
    CHANGED=1
else
    BEFORE=$(git -C "${WORK_DIR}" rev-parse HEAD)
    if ! timeout "${ZONES_TIMEOUT}" git -C "${WORK_DIR}" fetch --quiet origin "${ZONES_BRANCH}"; then
        log "ERROR: git fetch failed or timed out after ${ZONES_TIMEOUT} seconds"
        exit 1
    fi
    git -C "${WORK_DIR}" reset --hard "origin/${ZONES_BRANCH}" --quiet
    AFTER=$(git -C "${WORK_DIR}" rev-parse HEAD)

    SHORT_BEFORE=$(echo "$BEFORE" | cut -c1-7)
    SHORT_AFTER=$(echo "$AFTER" | cut -c1-7)

    if [ "${BEFORE}" = "${AFTER}" ]; then
        log "Same: ${SHORT_BEFORE} → ${SHORT_AFTER}"
        exit 0
    fi

    log "Updated: ${SHORT_BEFORE} → ${SHORT_AFTER}"
    CHANGED=1
fi

# --- Deploy zone files ---
# Expects zone files in a zones/ subdirectory of the repo.
# All *.conf files are copied to the shared zones volume.
ZONE_SRC="${WORK_DIR}/zones"

if [ ! -d "${ZONE_SRC}" ]; then
    log "ERROR: zones/ directory not found in repo — expected ${ZONE_SRC}"
    exit 1
fi

mkdir -p "${ZONE_DEST}"

DEPLOYED=0
for f in "${ZONE_SRC}"/*.conf; do
    [ -f "$f" ] || continue
    cp "$f" "${ZONE_DEST}/$(basename "$f")"
    log "Deployed: $(basename "$f")"
    DEPLOYED=$((DEPLOYED + 1))
done

if [ "${DEPLOYED}" -eq 0 ]; then
    log "WARNING: No *.conf files found in ${ZONE_SRC}"
    exit 1
fi

# --- Validate ---
if ! unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1; then
    log "ERROR: unbound-checkconf failed — not reloading"
    exit 1
fi

# --- Reload ---
if unbound-control -s 127.0.0.1@8953 status >/dev/null 2>&1; then
    unbound-control -s 127.0.0.1@8953 reload
    log "Unbound reloaded"
else
    log "ERROR: unbound-control not reachable at 127.0.0.1:8953"
    exit 1
fi
