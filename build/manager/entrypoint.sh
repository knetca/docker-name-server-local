#!/bin/sh
# entrypoint.sh — dns-manager container entrypoint
#
# Validates required environment, writes crontab for both jobs, runs
# initial sync of zones and blocklist, then execs crond in foreground.
#
# Logging: all output goes to stdout/stderr, captured by Docker.
# crond is run with -f (foreground) and -l 8 (log level notice).
set -eu

log() { echo "$(date -Iseconds) [dns-manager] $*"; }

# --- Validate required environment ---
: "${ZONES_REPO:?ZONES_REPO must be set in .env}"
: "${ZONES_BRANCH:=main}"
: "${ZONES_CRON:=*/5 * * * *}"
: "${BLOCKLIST_CRON:=0 3 * * *}"
: "${BLOCKLIST_MIN_LINES:=10000}"
: "${JITTER_MAX:=60}"

log "Starting dns-manager"
log "Zones repo:      ${ZONES_REPO}"
log "Zones branch:    ${ZONES_BRANCH}"
log "Zones cron:      ${ZONES_CRON}"
log "Blocklist cron:  ${BLOCKLIST_CRON}"
log "Blocklist min lines: ${BLOCKLIST_MIN_LINES}"
log "Jitter max:      ${JITTER_MAX}"
if [ -z "${BLOCKLIST_URL:-}" ]; then
    log "Blocklist URL:   disabled"
else
    log "Blocklist URL:   ${BLOCKLIST_URL}"
fi

# --- SSH key permissions ---
# git/ssh will refuse keys with permissions wider than 0600
KEYFILE=/root/.ssh/id_ed25519
if [ ! -f "${KEYFILE}" ]; then
    log "ERROR: ${KEYFILE} not found — mount the deploy key"
    exit 1
fi
PERMS=$(stat -c "%a" "${KEYFILE}")
if [ "${PERMS}" != "600" ]; then
    log "ERROR: ${KEYFILE} has permissions ${PERMS} — must be 600 on the host"
    exit 1
fi

# --- Write crontab ---
# Both jobs redirect output to /proc/1/fd/1 so Docker captures them.
cat > /etc/crontabs/root <<CRONTAB
# dns-manager crontab
# Zones: poll git repo, deploy on change, reload Unbound
${ZONES_CRON} /usr/local/bin/deploy-zones.sh >> /proc/1/fd/1 2>&1
# Blocklist: fetch configured list, reload Unbound
${BLOCKLIST_CRON} /usr/local/bin/update-blocklist.sh >> /proc/1/fd/1 2>&1
CRONTAB

log "Crontab installed"

# --- Initial runs ---
# Run both jobs immediately so the first cron cycle isn't delayed.
# unbound-control reload will fail softly if Unbound is not yet healthy —
# the cron jobs succeed on subsequent runs once Unbound is up.
log "Running initial zone deploy..."
/usr/local/bin/deploy-zones.sh || log "WARNING: Initial zone deploy failed — will retry on schedule"

log "Running initial blocklist fetch..."
/usr/local/bin/update-blocklist.sh || log "WARNING: Initial blocklist fetch failed — will retry on schedule"

# --- Hand off to crond ---
log "Starting crond"
crond -l 8
tail -f /dev/null
