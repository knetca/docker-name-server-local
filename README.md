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
- firewalld disabled or UDP/53, TCP/53, and UDP/123 explicitly permitted

## Repo structure

```
docker-name-server/
├── build
│   ├── chrony
│   │   └── Dockerfile                # custom Alpine chrony image
│   ├── manager
│   │   ├── Dockerfile
│   │   ├── entrypoint.sh
│   │   ├── scripts
│   │   │   ├── deploy-zones.sh       # git poll + zone deploy + reload
│   │   │   └── update-blocklist.sh   # OISD fetch + reload
│   │   └── ssh_config
│   └── unbound
│       └── Dockerfile                # custom Alpine unbound image
├── chrony
│   ├── chrony.conf                   # generic NTP sources — tracked in git
│   └── chrony.conf.d
│       ├── README.md                 # tracked
│       └── local.conf                # gitignored — host-specific NTP and allow
├── docker-compose.yml
├── manager
│   └── ssh
│       ├── SETUP.md                  # tracked
│       ├── id_ed25519                # gitignored — generated per host
│       ├── id_ed25519.pub            # gitignored — generated per host
│       └── known_hosts               # gitignored — generated per host
├── README.md
└── unbound
    ├── unbound.conf                  # entry point — include-toplevel only
    ├── custom.conf.d
    │   ├── README.md                 # tracked
    │   └── local.conf                # gitignored — host-specific overrides
    └── unbound.conf.d
        ├── 10-server.conf            # interfaces, hardening, performance
        ├── 20-access-control.conf    # RFC1918 defaults — tracked in git
        ├── 50-forward-zones.conf     # DoT upstream resolvers
        └── 60-dns-manager-zones.conf # includes zones volume managed by dns-manager
```

## Per-host configuration

This repo is designed to be cloned identically on every nameserver host.
Host-specific configuration lives in gitignored directories that survive
`git pull` without conflict:

| Directory | Purpose |
|-----------|---------|
| `unbound/custom.conf.d/` | Unbound overrides — access control, local directives |
| `chrony/chrony.conf.d/` | Chrony overrides — NTP sources, allow subnets |
| `manager/ssh/` | SSH deploy key and known_hosts |

Files in these directories are never committed. Each host creates its own
on first deployment and maintains them independently. See the `README.md`
in each directory for examples.

Tracked config files (`unbound.conf.d/*.conf`, `chrony.conf`) contain safe
generic defaults and are updated via `git pull`. Do not edit them directly
for host-specific changes — use the override directories instead.

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

# 5. Create host-specific config files
# See unbound/custom.conf.d/README.md and chrony/chrony.conf.d/README.md

# 6. Build all images
docker compose build

# 7. Start stack
docker compose up -d
```

## Unbound configuration

`unbound.conf` is the entry point — loads all config via `include-toplevel`:

```
include-toplevel: "/etc/unbound/unbound.conf.d/*.conf"
include-toplevel: "/etc/unbound/custom.conf.d/*.conf"
```

Files are loaded in lexicographic order within each directory. `custom.conf.d`
loads after `unbound.conf.d` so host-specific directives take precedence.

### Tracked config (`unbound.conf.d/`)

| File | Purpose |
|------|---------|
| `10-server.conf` | Interfaces, hardening, performance, health check record |
| `20-access-control.conf` | RFC1918 defaults — loopback + all private address space |
| `50-forward-zones.conf` | DoT upstream resolvers (CIRA, Quad9, Cloudflare filtered) |
| `60-dns-manager-zones.conf` | Includes `/etc/unbound/zones/*.conf` from zones volume |

### Host-specific config (`unbound/custom.conf.d/local.conf`)

Override or extend the tracked defaults. Loaded last — directives here
take precedence. Common uses:

**Add Tailscale CGNAT (all Tailscale devices including guests):**
```
server:
    access-control: 100.64.0.0/10 allow
```

**Tailscale-only host — deny RFC1918, allow Tailscale:**
```
server:
    access-control: 10.0.0.0/8 refuse
    access-control: 172.16.0.0/12 refuse
    access-control: 192.168.0.0/16 refuse
    access-control: 100.64.0.0/10 allow
```

Note: `100.64.0.0/10` covers all Tailscale devices including guests from
other tailnets sharing resources with you.

## Chrony configuration

`chrony/chrony.conf` contains generic NTP pool sources and loads
host-specific config via:

```
include /etc/chrony/chrony.conf.d/*.conf
```

### Host-specific config (`chrony/chrony.conf.d/local.conf`)

Add preferred NTP sources and allow directives. Example:

```
# Preferred sources — NRC Canada cesium-traceable
server time.nrc.ca iburst prefer
server time.chu.nrc.ca iburst

# Serve local clients
allow 192.168.0.0/16
```

## dns-manager

dns-manager handles two jobs on independent cron schedules:

- **Zone deployment** — polls a git repository, deploys changed zone files
  to the shared zones volume, reloads Unbound
- **Blocklist update** — fetches a blocklist in native Unbound format,
  validates it, reloads Unbound

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `ZONES_REPO` | *(required)* | SSH URL of the zones git repository |
| `ZONES_BRANCH` | `main` | Branch to track |
| `ZONES_CRON` | `*/5 * * * *` | Zone poll schedule |
| `BLOCKLIST_URL` | *(empty — disabled)* | Blocklist URL in native Unbound format. Empty disables blocklisting. |
| `BLOCKLIST_MIN_LINES` | `10000` | Fetch rejected if file is below this line count |
| `BLOCKLIST_CRON` | `0 3 * * *` | Blocklist fetch schedule |

### Blocklist

`BLOCKLIST_URL` must point to a blocklist in native Unbound `local-data`
format. OISD publishes directly in this format:

| Tier | URL | Coverage |
|------|-----|---------|
| big | `https://big.oisd.nl/unbound` | Ads, trackers, malware, phishing, adult — most aggressive |
| small | `https://small.oisd.nl/unbound` | Ads, trackers, malware, phishing — lower false-positive rate |
| nsfw | `https://nsfw.oisd.nl/unbound` | Adult content only |

Setting `BLOCKLIST_URL=` (empty) disables blocklisting. On the next
scheduled run any existing `20-blocklist.conf` is removed and Unbound
is reloaded. This is the explicit disable mechanism — no file is left
behind.

### Zones repo layout

The zones repo must have a `zones/` subdirectory. Files are in Unbound
`local-data` format — no SOA, no serial number required.

```
dns-zones/
└── zones/
    ├── 30-allowed.conf         # blocklist overrides for false positives
    ├── example.internal.conf   # internal zone — static type
    └── example.com.conf        # split-DNS zone — transparent type
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
dig @127.0.0.1 host.example.internal A

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

## Updating

After any change to a Dockerfile or manager scripts:

```bash
git pull
docker compose build
docker compose up -d
```

Config file changes in `unbound.conf.d/` or `chrony.conf` take effect after:

```bash
docker compose restart <container>
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
machine. Network-layer access control enforced at the perimeter.

### `unbound.conf.d/` numbered drop-in structure with `custom.conf.d/` overrides

`unbound.conf` contains only `include-toplevel` directives. Tracked config
lives in numbered drop-ins under `unbound.conf.d/` — load order is explicit
from the filename. Host-specific overrides go in gitignored `custom.conf.d/`
which loads after `unbound.conf.d/`, giving host config precedence without
touching tracked files. The same pattern applies to `chrony.conf.d/`.

This means `git pull` never conflicts with host-specific configuration.

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

### `crond` backgrounded with `tail -f /dev/null`

Alpine crond's `setpgid` call is blocked by the default container seccomp
profile when run with `-f` (foreground). Running crond in background and
keeping the container alive with `tail -f /dev/null` is the pragmatic fix.
Cron job output is redirected to `/proc/1/fd/1` so Docker captures it.

### firewalld

Cloud-init minimal installs do not include firewalld — no action needed.
Full OS installs from ISO include firewalld which blocks UDP/53 by default.
Disable it on dedicated nameserver hosts:

```bash
systemctl disable --now firewalld
```

## Changelog

| Date | Change |
|------|--------|
| 2026-05-13 | Blocklist URL configurable via BLOCKLIST_URL — empty disables blocklisting |
| 2026-05-13 | BLOCKLIST_MIN_LINES exposed as env var (default 10000) |
| 2026-05-11 | Added per-host config directories — unbound/custom.conf.d/ and chrony/chrony.conf.d/ |
| 2026-05-11 | Refactored unbound.conf.d — access control split to 20-access-control.conf, zones included via 60-dns-manager-zones.conf |
| 2026-05-11 | Initial working deployment on Alma 10 |
