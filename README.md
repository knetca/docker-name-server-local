# docker-name-server

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
- firewalld disabled or UDP/53 and TCP/53 explicitly permitted

## Repo structure

```
docker-name-server/
├── build
│   ├── chrony
│   │   └── Dockerfile             # custom Alpine chrony image
│   ├── manager
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   ├── scripts
│   │   │   ├── deploy-zones.sh      # git poll + zone deploy + reload
│   │   │   └── update-blocklist.sh  # OISD fetch + reload
│   │   ├── seed
│   │   │   ├── 00-seed.conf         # placeholder — prevents empty glob on cold start
│   │   │   └── 20-blocklist.conf    # placeholder — replaced on first blocklist fetch
│   │   └── ssh_config
│   └── unbound
│       └── Dockerfile               # custom Alpine unbound image
├── chrony
│   └── chrony.conf
├── docker-compose.yml
├── manager
│   └── ssh
│       ├── id_ed25519               # gitignored — generated per host
│       ├── id_ed25519.pub           # gitignored — generated per host
│       ├── known_hosts
│       └── SETUP.md
├── README.md
└── unbound
    ├── unbound.conf                 # entry point — include-toplevel only
    └── unbound.conf.d
        ├── 10-server.conf           # interfaces, hardening, performance
        ├── 20-access-control.conf   # access control — differs per deployment
        ├── 50-forward-zones.conf    # DoT upstream resolvers
        └── 60-dns-manager-zones.conf # includes zones volume managed by dns-manager
```

## Deployment

```bash
# 1. Clone repo
git clone <this-repo> /opt/docker-name-server
cd /opt/docker-name-server

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

## Unbound configuration

`unbound.conf` is the entry point — two lines only:

```
include-toplevel: "/etc/unbound/unbound.conf.d/*.conf"
```

All config lives in numbered drop-in files under `unbound.conf.d/`. Load
order is lexicographic — the number prefix controls sequence.

| File | Purpose |
|------|---------|
| `10-server.conf` | Interfaces, hardening, performance, health check record |
| `20-access-control.conf` | Access control — edit per deployment for correct subnets |
| `50-forward-zones.conf` | DoT upstream resolvers (CIRA, Quad9, Cloudflare filtered) |
| `60-dns-manager-zones.conf` | Includes `/etc/unbound/zones/*.conf` from the zones volume |

### Access control

`20-access-control.conf` is the one file that differs between deployments.
Edit to match the subnets that should be permitted to query this nameserver.

For homelab nameservers (ns1, ns2):
```
access-control: 192.168.0.0/16 allow
access-control: 100.64.0.0/10 allow    # Tailscale CGNAT
```

For Tailscale-only nameservers (kd-ns1):
```
access-control: 100.64.0.0/10 allow    # full Tailscale CGNAT range
```

Note: `100.64.0.0/10` covers all Tailscale devices including guests from
other tailnets who are sharing resources with you.

## Zones repo layout

The zones repo must have a `zones/` subdirectory. Files are in Unbound
`local-data` format — no SOA, no serial number required.

```
cstl-zones/
└── zones/
    ├── 30-allowed.conf         # blocklist overrides for false positives
    ├── cstl.one.conf           # internal zone — static type
    └── nwrg.ca.conf            # split-DNS zone — transparent type
```

Zone types:

| Type | Behaviour |
|------|-----------|
| `static` | Authoritative from local data only. NXDOMAIN for anything not defined. Use for purely internal zones. |
| `transparent` | Local data if present, falls through to forwarder if not. Use for split-DNS — internal overrides for a publicly registered domain. |

dns-manager polls on `ZONES_CRON` (default: every 5 minutes). On a new
commit, zone files are copied to the shared `zones` volume and
`unbound-control reload` is issued. No change = no reload.

### Allowlist

`30-allowed.conf` in the zones repo overrides blocklist false positives.
Loaded after `20-blocklist.conf` (lexicographic order) so entries take
precedence. Format:

```
server:
    local-zone: "example.com." transparent
```

## Verification

```bash
# DNS — health check
dig @127.0.0.1 health.check.unbound A

# DNS — internal zone
dig @127.0.0.1 ns1.cstl.one A

# DNS — external forwarded
dig @127.0.0.1 google.com A

# DNS — blocklist (expect 0.0.0.0)
dig @127.0.0.1 accounts.doubleclick.net A

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
git pull
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

### `unbound.conf.d/` numbered drop-in structure

`unbound.conf` contains only `include-toplevel` directives. All config
lives in numbered drop-ins — load order is explicit from the filename,
new files are picked up automatically without editing `unbound.conf`.
`20-access-control.conf` is the only file that varies between deployments.

### dns-manager as custom Alpine image

git, curl, unbound, and dcron in one container. Handles both zone git
polling and blocklist updates. Two cron jobs replace the two systemd timers
from the LXC build. Failure blast radius is contained at the script level —
a failed blocklist fetch does not affect zone deploys and vice versa.

### Git-managed zones via SSH deploy key

Zones repo is separate from the stack repo. Read-only SSH deploy key
generated per host — each nameserver has its own key registered on the
zones repo. Zone files use Unbound `local-data` format: no SOA, no serial
number, no BIND-style zone management overhead. Allowlist overrides live
in the zones repo as `30-allowed.conf`.

### Seed files for cold start

`00-seed.conf` and `20-blocklist.conf` are baked into the dns-manager image
and copied to the zones volume on first start if not already present.
Prevents Unbound failing on an empty glob before dns-manager has had a
chance to populate the volume from git.

### `crond` backgrounded with `tail -f /dev/null`

Alpine crond's `setpgid` call is blocked by the default container seccomp
profile when run with `-f` (foreground). Running crond in background and
keeping the container alive with `tail -f /dev/null` is the pragmatic fix.
Cron job output is redirected to `/proc/1/fd/1` so Docker captures it.

### firewalld

Cloud-init minimal installs (ns1, ns2) do not include firewalld — no action
needed. Full OS installs (kd-ns1 from ISO) include firewalld which blocks
UDP/53 by default. Disable it on dedicated nameserver hosts:

```bash
systemctl disable --now firewalld
```

## Changelog

| Date | Change |
|------|--------|
| 2026-05-11 | Refactored unbound.conf.d — access control split to 20-access-control.conf, zones included via 60-dns-manager-zones.conf |
| 2026-05-11 | Initial working deployment on Alma 10 |
