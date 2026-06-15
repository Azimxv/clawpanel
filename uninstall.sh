#!/usr/bin/env bash
# ClawPanel uninstaller — removes everything install.sh creates.
# Usage:
#   bash uninstall.sh              # interactive, asks for confirmation
#   bash uninstall.sh --yes        # no prompt
#   bash uninstall.sh --keep-certs # keep /etc/letsencrypt (avoid LE rate limit on reinstall)
#   bash uninstall.sh --purge-hy2  # also remove the hysteria binary
set -uo pipefail

ASSUME_YES=0
KEEP_CERTS=0
PURGE_HY2=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)      ASSUME_YES=1 ;;
        --keep-certs)  KEEP_CERTS=1 ;;
        --purge-hy2)   PURGE_HY2=1 ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

echo "============================================"
echo "  ClawPanel uninstaller"
echo "============================================"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
fi

cat <<'EOF'

This will REMOVE:
  - services: clawpanel, claw-agent, claw-xray-hy, hysteria
  - /opt/clawpanel  /opt/claw-agent
  - /etc/claw-xray-hy  /etc/claw-agent  /etc/hysteria
  - /var/www/fake  /var/lib/clawpanel
  - /usr/local/bin/{xray-hy,hy2-sync,geoip.dat,geosite.dat}
  - nginx sites: claw.conf, panel.conf
  - UFW rules added by the installer
  - ALL PANEL DATA (users, nodes, claw.db)

It will NOT touch: SSH, the git repo, system packages (nginx/certbot/ufw stay installed).
EOF

if [[ "$KEEP_CERTS" -eq 1 ]]; then
    echo "  Let's Encrypt certs: KEPT (--keep-certs)"
else
    echo "  Let's Encrypt certs: will be DELETED (pass --keep-certs to keep them)"
fi
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -rp "Type 'yes' to proceed: " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

echo
echo "--- Stopping & disabling services ---"
for svc in clawpanel claw-agent claw-xray-hy hysteria; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

echo "--- Removing systemd units ---"
rm -f /etc/systemd/system/clawpanel.service \
      /etc/systemd/system/claw-agent.service \
      /etc/systemd/system/claw-xray-hy.service \
      /etc/systemd/system/hysteria.service \
      /etc/systemd/system/hysteria-server.service \
      /etc/systemd/system/hysteria-server@.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "--- Removing application directories ---"
rm -rf /opt/clawpanel /opt/claw-agent \
       /etc/claw-xray-hy /etc/claw-agent /etc/hysteria \
       /var/www/fake /var/lib/clawpanel

echo "--- Removing binaries ---"
rm -f /usr/local/bin/xray-hy \
      /usr/local/bin/hy2-sync \
      /usr/local/bin/geoip.dat \
      /usr/local/bin/geosite.dat
if [[ "$PURGE_HY2" -eq 1 ]]; then
    rm -f /usr/local/bin/hysteria
    # get.hy2.sh creates a dedicated system user; remove it too for a clean slate.
    if id hysteria >/dev/null 2>&1; then
        userdel hysteria 2>/dev/null || true
        echo "    hysteria binary + system user removed (--purge-hy2)"
    else
        echo "    hysteria binary removed (--purge-hy2)"
    fi
fi

echo "--- Removing nginx site configs ---"
rm -f /etc/nginx/sites-enabled/claw.conf  /etc/nginx/sites-available/claw.conf \
      /etc/nginx/sites-enabled/panel.conf /etc/nginx/sites-available/panel.conf
# restore the default site if nothing else is enabled, so nginx still starts
if [[ -z "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]] && [[ -f /etc/nginx/sites-available/default ]]; then
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
fi
if nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
else
    systemctl stop nginx 2>/dev/null || true
    echo "    nginx config now empty/invalid; nginx stopped."
fi

echo "--- Removing UFW rules ---"
ufw --force delete allow 443/tcp   2>/dev/null || true
ufw --force delete allow 2053/tcp  2>/dev/null || true
ufw --force delete allow 2083/tcp  2>/dev/null || true
ufw --force delete allow 443/udp   2>/dev/null || true

if [[ "$KEEP_CERTS" -ne 1 ]]; then
    echo "--- Removing Let's Encrypt certs ---"
    rm -rf /etc/letsencrypt
fi

echo
echo "============================================"
echo "  ClawPanel removed"
echo "============================================"
echo "  Kept: SSH, git repo, system packages (nginx/certbot/ufw)."
[[ "$KEEP_CERTS" -eq 1 ]] && echo "  Kept: /etc/letsencrypt (reinstall won't hit LE rate limit)."
[[ "$PURGE_HY2" -ne 1 ]] && echo "  Kept: /usr/local/bin/hysteria (pass --purge-hy2 to remove)."
echo "============================================"
