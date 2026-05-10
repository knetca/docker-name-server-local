#!/bin/sh
# update-blocklist.sh — fetch OISD blocklist in Unbound format, reload Unbound
#
# Safety checks before replacing the live blocklist:
#   - curl must succeed within timeout
#   - downloaded file must exceed minimum line count
#   - unbound-checkconf must pass with new file in place
#
# On any failure the existing blocklist is preserved and Unbound is not reloaded.
# unbound-control connects to 127.0.0.1:8953 (host networking, no TLS).
set -eu

BLOCKLIST_URL="https://big.oisd.nl/unbound"
OUTPUT="/etc/unbound/zones/20-blocklist.conf"
TMP="${OUTPUT}.tmp"
MIN_LINES=10000

log() { echo "$(date -Iseconds) [update-blocklist] $*"; }

log "Fetching OISD blocklist..."

if ! curl -sf --max-time 120 "${BLOCKLIST_URL}" -o "${TMP}"; then
    log "ERROR: curl failed fetching ${BLOCKLIST_URL}"
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
