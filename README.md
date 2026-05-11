# docker-dns

Unbound (recursive DNS, DoT upstreams, OISD ad/tracker blocking,
git-managed local zones) and Chrony (NTP server) as a Docker Compose stack.

## Services

| Container | Image | Purpose |
|-----------|-------|---------|
| unbound | local build (alpine) | Recursive resolver, DoT upstreams, local zones, ad blocking |
| chrony | local build (alpine) | NTP server — tracks upstream sources, serves LAN clients |
| dns-manager | local build (alpine) | Zone git polling, blocklist updates, unbound-control reload |

All three images are built locally from the same `ALPINE_TAG` pin.

## Requirements

- Docker and Docker Compose plugin
- Linux host — dedicated recommended
- `network_mode: host` — DNS (UDP/53) and NTP (UDP/123) require host networking
- Dedicated zones git repository with SSH deploy key

## Repo structure

```
docker-dns/
├── docker-compose.yml
├── .env.example
├── build/
│   ├── unbound/Dockerfile      # custom Alpine unbound image
│   └── chrony/Dockerfile       # custom Alpine chrony image
├── unbound/
│   ├── unbound.conf
│   └── unbound.conf.d/
│       ├── 10-server.conf          # interfaces, access control, hardening
│       └── 50-forward-zones.conf   # DoT upstream resolvers
├── chrony/
│   └── chrony.conf
└── manager/
    ├── Dockerfile
    ├── entrypoint.sh
    ├── ssh_config
    ├── ssh/
    │   ├── SETUP.md
    │   ├── id_ed25519              # gitignored — generated per host
    │   └── known_hosts
    └── scripts/
        ├── deploy-zones.sh         # git poll + zone deploy + reload
        └── update-blocklist.sh     # OISD fetch + reload
```

## Deployment

```bash
# 1. Clone repo
git clone <this-repo> /opt/docker/dns
cd /opt/docker/dns

# 2. Configure environment
cp .env.example .env
$EDITOR .env

# 3. Set up SSH deploy key
# Follow manager/ssh/SETUP.md

# 4. Set correct permissions on deploy key
chmod 600 manager/ssh/id_ed25519

# 5. Build all images
docker compose build

# 6. Start stack
docker compose up -d
```

## Zones repo layout

The zones repo must have a `zones/` subdirectory containing Unbound
`local-data` format files — no SOA, no serial number required.

```
dns-zones/
└── zones/
    └── cstl.one.conf
```

```
local-zone: "cstl.one." static
local-data: "host.cstl.one. IN A 192.168.x.x"
```

dns-manager polls on `ZONES_CRON` (default: every 5 minutes). On a new
commit, zone files are copied to the shared `zones` volume and
`unbound-control reload` is issued. No change = no reload.

## Verification

```bash
# DNS
dig @127.0.0.1 health.check.unbound A
dig @127.0.0.1 ns1.cstl.one A

# NTP
docker exec chrony chronyc tracking
docker exec chrony chronyc sources

# Manager logs (zone sync + blocklist)
docker logs dns-manager --follow

# Unbound status
docker exec unbound unbound-control -s 127.0.0.1@8953 status

# Force immediate zone deploy
docker exec dns-manager deploy-zones.sh

# Force immediate blocklist update
docker exec dns-manager update-blocklist.sh
```

## Updating images

After any change to a Dockerfile or manager scripts:

```bash
docker compose build
docker compose up -d
```

To update the Alpine base across all three images, change `ALPINE_TAG` in
`.env` and rebuild.

## Design decisions

### Custom Alpine images over upstream

`klutchell/unbound` is built `FROM scratch` — no shell, no package manager,
making debugging and exec access impossible. `dockurr/chrony` has an
opinionated startup script that unconditionally overwrites `/etc/chrony/chrony.conf`
on every start, conflicting with a bind-mounted config.

Alpine packages for both are plain vanilla, close to upstream defaults, and
fully debuggable. All three images share a single `ALPINE_TAG` pin — one
variable controls the entire stack's base.

### `build/` directory for Dockerfiles

`unbound/` and `chrony/` contain only config files bind-mounted at runtime.
Dockerfiles live under `build/` to keep build artefacts separate from
runtime config.

### `network_mode: host`

Required for DNS (UDP/53) and NTP (UDP/123). All containers share the host
network stack. `unbound-control` reaches Unbound at `127.0.0.1:8953`
directly from dns-manager without any cross-container networking complexity.

### `unbound-control` no-TLS, loopback only

Eliminates the need to share TLS keys between containers. Acceptable on a
dedicated single-purpose host where the control interface never leaves the
machine. Fortigate enforces network-layer access control.

### dns-manager as custom Alpine image

git, curl, unbound, and dcron in one container. Handles both zone git
polling and blocklist updates. Two cron jobs replace the two systemd timers
from the LXC build. Failure blast radius is contained at the script level —
a failed blocklist fetch does not affect zone deploys and vice versa.

### Git-managed zones via SSH deploy key

Zones repo is separate from the stack repo. Read-only SSH deploy key
generated per host — each nameserver has its own key registered on the
zones repo. Zone files use Unbound `local-data` format: no SOA, no serial
number, no BIND-style zone management overhead.

### Seed files for cold start

`00-seed.conf` and `20-blocklist.conf` are baked into the dns-manager image
and copied to the zones volume on first start if not already present.
Prevents Unbound failing on an empty `include-toplevel` glob before
dns-manager has had a chance to populate the volume from git.

### `crond` backgrounded with `tail -f /dev/null`

Alpine crond's `setpgid` call is blocked by the default container seccomp
profile when run with `-f` (foreground). Running crond in background and
keeping the container alive with `tail -f /dev/null` is the pragmatic fix.
Cron job output is redirected to `/proc/1/fd/1` so Docker captures it.

## Changelog

| Date | Change |
|------|--------|
| 2026-05-11 | Initial working deployment on Alma 10 |
