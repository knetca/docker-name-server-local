# chrony/chrony.conf.d/

Host-specific Chrony configuration. Files in this directory are gitignored
and generated per deployment.

Loaded via `include /etc/chrony/chrony.conf.d/*.conf` in `chrony.conf`.

## Example — allow local clients

Create `local.conf` with your subnet:

```
allow 192.168.0.0/16
```

## Example — additional NTP sources

```
server time.example.com iburst
```
