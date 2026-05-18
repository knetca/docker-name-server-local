#!/bin/sh
# update-blocklist.sh — fetch blocklist in Unbound format, reload Unbound
#
# BLOCKLIST_URL — URL of a blocklist in native Unbound local-data format.
# If empty or unset, blocklists are disabled: any existing blocklist file
# is removed and Unbound is reloaded.
#
# Safety checks before replacing the live blocklist:
#   - curl must succeed within timeout
#   - downloaded file must exceed BLOCKLIST_MIN_LINES
#   - unbound-checkconf must pass with new file in place
#
# On any failure the existing blocklist is preserved and Unbound is not reloaded.
# unbound-control connects to 127.0.0.1:8953 (host networking, no TLS).
set -eu

# Add random jitter to avoid thundering herd if many instances are running
# with the same schedule.
JITTER_MAX="${JITTER_MAX:-60}"
sleep $(( RANDOM % JITTER_MAX ))

ZONE_DEST="/etc/unbound/blocklist"
OUTPUT="${ZONE_DEST}/20-blocklist.conf"
TMP="${OUTPUT}.tmp"
MIN_LINES="${BLOCKLIST_MIN_LINES:-10000}"

log() { echo "$(date -Iseconds) [update-blocklist] $*"; }

mkdir -p "${ZONE_DEST}"

# --- Disabled path ---
# Empty BLOCKLIST_URL means blocklists are intentionally disabled.
# Remove any existing blocklist file and reload Unbound if it was present.
if [ -z "${BLOCKLIST_URL:-}" ]; then
    log "Blocklist disabled (BLOCKLIST_URL is empty)"
    if [ -f "${OUTPUT}" ]; then
        rm -f "${OUTPUT}"
        log "Removed: $(basename "${OUTPUT}")"
        if ! unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1; then
            log "ERROR: unbound-checkconf failed — not reloading"
            exit 1
        fi
        if unbound-control -s 127.0.0.1@8953 status >/dev/null 2>&1; then
            unbound-control -s 127.0.0.1@8953 reload
            log "Unbound reloaded"
        else
            log "ERROR: unbound-control not reachable at 127.0.0.1:8953"
            exit 1
        fi
    else
        log "No blocklist file present — nothing to do"
    fi
    exit 0
fi

# --- Fetch ---
log "Fetching blocklist: ${BLOCKLIST_URL}"

if ! curl -sf --max-time 120 "${BLOCKLIST_URL}" -o "${TMP}"; then
    log "ERROR: curl failed — keeping existing"
    rm -f "${TMP}"
    exit 1
fi

LINE_COUNT=$(wc -l < "${TMP}")

if [ "${LINE_COUNT}" -lt "${MIN_LINES}" ]; then
    log "ERROR: Blocklist suspiciously small (${LINE_COUNT} lines, minimum ${MIN_LINES}) — keeping existing"
    rm -f "${TMP}"
    exit 1
fi

mv "${TMP}" "${OUTPUT}"
log "Blocklist written: ${LINE_COUNT} lines"

# --- Validate ---
if ! unbound-checkconf /etc/unbound/unbound.conf >/dev/null 2>&1; then
    log "ERROR: unbound-checkconf failed after blocklist update — removing new file"
    rm -f "${OUTPUT}"
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
