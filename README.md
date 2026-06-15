# ClawPanel

Self-hosted VPN panel: VLESS-XHTTP + Hysteria2, with custom xray-hy backend.

## Stack

- **Panel**: FastAPI + SQLite, listens on `127.0.0.1:3100`
- **Agent**: syncs xray config from panel, every 60s
- **xray-hy**: custom Xray 26.6.1 build, two VLESS-XHTTP inbounds (EXIT 10443, DIRECT 12052)
- **Hysteria2**: standalone UDP/443, optional
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

## Layout

```
panel/         FastAPI app (main.py, models.py, xray.py, templates/, static/)
agent/         claw-agent.py
scripts/       hy2-sync (renders /etc/hysteria/config.yaml from claw.db)
nginx/         *.conf templates
systemd/       *.service units
bin/           xray-hy.gz (custom Xray binary)
fake-site/     masquerade page served by nginx
install.sh
uninstall.sh
```
