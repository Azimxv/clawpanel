# ClawPanel

Self-hosted VPN panel: VLESS-XHTTP + Hysteria2 + VLESS-REALITY, with custom xray-hy backend.

## Stack

- **Panel**: FastAPI + SQLite, listens on `127.0.0.1:3100`
- **Agent**: syncs xray config from panel, every 60s
- **xray-hy**: custom Xray 26.6.27 build, two VLESS-XHTTP inbounds (EXIT 10443, DIRECT 12052)
- **Hysteria2**: standalone UDP/443, optional
- **VLESS-REALITY**: optional 3rd protocol, direct TCP (default 8443), borrows a real site's TLS handshake — no LE cert. Off by default; enable via `ENABLE_REALITY=1` in panel `.env` (see `panel/env.template`). Client SNI must exactly match `REALITY_SNI`.
- **Nginx**: TLS termination on 443/2053/2083, masquerade fake site
- **fail2ban + UFW** for SSH hardening

## Install

On a fresh Ubuntu 24.04 server (root):

```bash
git clone https://github.com/azimxv/clawpanel.git
cd clawpanel
bash install.sh
```

The installer asks for:
- domain (must point to the server)
- Let's Encrypt email
- node name
- whether to install Hysteria2
- optional backup tarball to restore

It generates a random admin password, agent secret, and XHTTP path. Save them — they are shown only once.

After install:
- Panel: `https://<domain>:2083`
- Default user: `admin` / `<random>`

## Uninstall

Remove ClawPanel and all its data from the server with one command:

```bash
cd clawpanel && bash uninstall.sh
```

It stops and removes every service, directory, binary, nginx site, and UFW rule
the installer created, including the panel database (users, nodes). It asks for
confirmation first; pass `--yes` to skip the prompt.

Flags:
- `--keep-certs` keep `/etc/letsencrypt` so a reinstall won't hit the Let's Encrypt rate limit
- `--purge-hy2` also remove the hysteria binary

It leaves SSH, the git repo, and system packages (nginx/certbot/ufw) untouched.

## Backup

```bash
tar -czf clawpanel-backup-$(date +%F).tar.gz -C /opt/clawpanel/data .
```

Restore by passing the tarball path during install.

## Update

Pull the repo and re-run a subset of `install.sh` manually (rsync `panel/` to `/opt/clawpanel/`, restart `clawpanel.service`). Full re-run is destructive (overwrites secrets).

### Upgrade the Xray core

`update-xray` (installed to `/usr/local/bin`) upgrades the xray-hy core in place:

```bash
update-xray            # upgrade to the latest stable Xray-core release
update-xray v26.6.27   # or pin a specific version
```

It downloads the official Xray build for the server's architecture, validates
the current config against the new binary before swapping, restarts
`claw-xray-hy`, updates the version label shown in the panel Settings page, and
**rolls back automatically** if the service fails to come up. The previous
binary is kept at `/usr/local/bin/xray-hy.bak-<timestamp>`.

### Upgrade the hysteria2 core

`update-hysteria` works the same way for the hysteria2 binary:

```bash
update-hysteria            # upgrade to the latest stable hysteria release
update-hysteria v2.9.3     # or pin a specific version
```

It downloads the official build for the server's architecture, backs up the
running binary, swaps it in, restarts `hysteria`, and **rolls back
automatically** if the service fails to come up. hysteria has no config
`-test`, so validation is "does the service come back active". The previous
binary is kept at `/usr/local/bin/hysteria.bak-<timestamp>`.

## Layout

```
panel/         FastAPI app (main.py, models.py, xray.py, templates/, static/)
agent/         claw-agent.py
scripts/       hy2-sync (renders /etc/hysteria/config.yaml from claw.db)
               update-xray (in-place Xray core upgrade with rollback)
               update-hysteria (in-place hysteria2 upgrade with rollback)
nginx/         *.conf templates
systemd/       *.service units
bin/           xray-hy.gz (custom Xray binary)
fake-site/     masquerade page served by nginx
install.sh
uninstall.sh
```
