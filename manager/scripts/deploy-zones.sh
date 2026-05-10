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

ZONES_REPO="${ZONES_REPO:?}"
ZONES_BRANCH="${ZONES_BRANCH:-main}"
WORK_DIR="/var/lib/dns-manager/zones"
ZONE_DEST="/etc/unbound/zones"

log() { echo "$(date -Iseconds) [deploy-zones] $*"; }

# --- Clone or update ---
if [ ! -d "${WORK_DIR}/.git" ]; then
    log "Cloning ${ZONES_REPO} branch=${ZONES_BRANCH}"
    git clone --branch "${ZONES_BRANCH}" --single-branch \
        "${ZONES_REPO}" "${WORK_DIR}"
    CHANGED=1
else
    BEFORE=$(git -C "${WORK_DIR}" rev-parse HEAD)
    git -C "${WORK_DIR}" fetch --quiet origin "${ZONES_BRANCH}"
    git -C "${WORK_DIR}" reset --hard "origin/${ZONES_BRANCH}" --quiet
    AFTER=$(git -C "${WORK_DIR}" rev-parse HEAD)

    if [ "${BEFORE}" = "${AFTER}" ]; then
        exit 0
    fi

    log "Updated: ${BEFORE%"${BEFORE#???????}"} → ${AFTER%"${AFTER#???????"}"}"
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
