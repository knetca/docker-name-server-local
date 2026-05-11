#!/bin/sh
# entrypoint.sh — dns-manager container entrypoint
#
# Validates required environment, seeds zones volume with placeholder files,
# writes crontab for both jobs, runs initial sync of zones and blocklist,
# then execs crond in foreground.
#
# Seed files ensure Unbound's include glob (/etc/unbound/zones/*.conf)
# always matches at least one file on first start, before deploy-zones.sh
# has had a chance to populate the volume from git.
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

log "Starting dns-manager"
log "Zones repo:     ${ZONES_REPO}"
log "Zones branch:   ${ZONES_BRANCH}"
log "Zones cron:     ${ZONES_CRON}"
log "Blocklist cron: ${BLOCKLIST_CRON}"

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

# --- Seed zones volume ---
# Copy seed files to the zones volume only if the target does not already
# exist. Ensures Unbound's include glob always matches at least one file,
# preventing a startup failure on a brand new empty volume.
# Seed files are comment-only placeholders — deploy-zones.sh and
# update-blocklist.sh replace them on first successful run.
ZONES_DIR="/etc/unbound/zones"
mkdir -p "${ZONES_DIR}"

for seed in /etc/dns-manager/seed/*.conf; do
    [ -f "$seed" ] || continue
    target="${ZONES_DIR}/$(basename "$seed")"
    if [ ! -f "${target}" ]; then
        cp "${seed}" "${target}"
        log "Seeded: $(basename "$seed")"
    else
        log "Seed skipped (already present): $(basename "$seed")"
    fi
done

# --- Write crontab ---
# Both jobs redirect output to /proc/1/fd/1 so Docker captures them.
cat > /etc/crontabs/root <<EOF
# dns-manager crontab
# Zones: poll git repo, deploy on change, reload Unbound
${ZONES_CRON} /usr/local/bin/deploy-zones.sh >> /proc/1/fd/1 2>&1
# Blocklist: fetch OISD, reload Unbound
${BLOCKLIST_CRON} /usr/local/bin/update-blocklist.sh >> /proc/1/fd/1 2>&1
EOF

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
