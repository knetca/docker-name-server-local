# docker-dns

Unbound (recursive DNS, DoT upstreams, OISD ad/tracker blocking,
git-managed local zones) and Chrony (NTP server) as a Docker Compose stack.

## Services

| Container | Image | Purpose |
|-----------|-------|---------|
| unbound | klutchell/unbound | Recursive resolver, DoT upstreams, local zones, ad blocking |
| chrony | dockurr/chrony | NTP server — tracks upstream sources, serves LAN clients |
| dns-manager | local build (alpine) | Zone git polling, blocklist updates, unbound-control reload |

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
    │   ├── id_ed25519.pub
    │   └── known_hosts
    └── scripts/
        ├── deploy-zones.sh         # git poll + zone deploy + reload
        └── update-blocklist.sh     # OISD fetch + reload
```

## Prerequisites

Run through `manager/ssh/SETUP.md` on the host and confirm `ssh -T git@github.com` works 
from inside a throwaway container before the real bring-up — saves debugging SSH issues 
while the rest of the stack is also trying to start.

```bash
docker run --rm -it \
    -v "$(pwd)/manager/ssh/id_ed25519:/root/.ssh/id_ed25519:ro" \
    -v "$(pwd)/manager/ssh/known_hosts:/root/.ssh/known_hosts:ro" \
    -v "$(pwd)/manager/ssh_config:/root/.ssh/config:ro" \
    alpine sh -c "apk add --no-cache openssh-client && ssh -T git@github.com"
```

Run from the repo root. It mounts the same key material the real container will use, 
installs `openssh-client`, and attempts the GitHub handshake. Expected output is:

```
Hi you/dns-zones! You've successfully authenticated, but GitHub does not provide shell access.
```

If you see that, the `deploy key`, `known_hosts`, and `ssh_config` are all correct and the 
real container will work.

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

# 4. Build dns-manager image
docker compose build

# 5. Start stack
docker compose up -d

# 6. Monitor logs
docker logs dns-manager --follow
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

## Updating dns-manager

After changes to `manager/` scripts or Dockerfile:

```bash
docker compose build
docker compose up -d dns-manager
```

Increment `MANAGER_TAG` in `.env` to track the local image version.

## Changelog

| Date | Change |
|------|--------|
|      |        |
