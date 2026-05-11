# unbound/custom.conf.d/

Host-specific Unbound configuration. Files in this directory are gitignored
and generated per deployment.

Loaded via `include-toplevel` in `unbound.conf` after `unbound.conf.d/`.

## Example — restrict or extend access control

Create `local.conf`:

```
server:
    # Add Tailscale CGNAT on top of RFC1918 defaults
    access-control: 100.64.0.0/10 allow
```

## Example — override RFC1918 defaults for Tailscale-only host

```
server:
    access-control: 192.168.0.0/16 refuse
    access-control: 10.0.0.0/8 refuse
    access-control: 172.16.0.0/12 refuse
    access-control: 100.64.0.0/10 allow
```
