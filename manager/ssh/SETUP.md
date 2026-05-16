# SSH Deploy Key Setup

Run once on each nameserver host. The key is read-only on the zones repo.
`id_ed25519` is gitignored — never committed on either branch.
`known_hosts` is safe to commit on the private branch.

## 1. Generate the deploy key

```bash
ssh-keygen -t ed25519 -C "dns-manager@$(hostname)" \
    -f manager/ssh/id_ed25519 -N ""
```

This creates:
- `manager/ssh/id_ed25519` — private key (gitignored, bind-mounted into container)
- `manager/ssh/id_ed25519.pub` — public key (add to GitHub)

## 2. Add to GitHub as a deploy key

GitHub → zones repo → Settings → Deploy keys → Add deploy key

- Title: `dns-manager-<hostname>`
- Key: paste contents of `manager/ssh/id_ed25519.pub`
- Allow write access: **NO**

## 3. Capture GitHub host key

```bash
ssh-keyscan github.com > manager/ssh/known_hosts
```

Verify the fingerprint matches GitHub's published keys:
https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints

## 4. Verify permissions

The entrypoint enforces 0600 on the key at startup. If docker runs as root
(default), the bind mount will be readable. No manual chmod needed unless
you run rootless Docker.
