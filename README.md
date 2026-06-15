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
```
