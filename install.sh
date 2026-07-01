#!/usr/bin/env bash
# ClawPanel installer
# Usage: bash install.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo "  ClawPanel installer"
echo "============================================"

if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
fi

# --- Inputs ---
read -rp "Domain (e.g. vpn.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Domain required."; exit 1; }

read -rp "Admin email for Let's Encrypt: " LE_EMAIL
[[ -z "$LE_EMAIL" ]] && { echo "Email required."; exit 1; }

read -rp "Node name [FI1]: " NODE_NAME
NODE_NAME=${NODE_NAME:-FI1}

read -rp "Install hysteria2? [Y/n]: " INSTALL_HY2
INSTALL_HY2=${INSTALL_HY2:-Y}

read -rp "Restore from backup tarball (path or empty for fresh): " RESTORE_PATH

# --- Generate secrets ---
# SIGPIPE-safe: head reads a fixed chunk from /dev/urandom (infinite source, SIGPIPE harmless),
# tr consumes it fully to EOF, then bash slices to length. No downstream close kills tr.
randstr() {
    local charset="$1" len="$2" out
    out=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc "$charset")
    printf '%s' "${out:0:$len}"
}
ADMIN_PASS=$(randstr 'A-Za-z0-9' 16)
AGENT_SECRET=$(randstr 'A-Za-z0-9_-' 43)
XHTTP_PATH="/$(randstr 'A-Za-z0-9' 12)"

echo
echo "--- Installing system packages ---"
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip nginx certbot ufw curl

# --- xray-hy ---
echo "--- Installing xray-hy ---"
gunzip -c "$REPO_DIR/bin/xray-hy.gz" > /usr/local/bin/xray-hy
chmod +x /usr/local/bin/xray-hy

# geoip/geosite data — xray routing uses geoip:private; xray loads them from the binary's dir
echo "--- Downloading geo data ---"
GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
curl -fsSL -o /usr/local/bin/geoip.dat   "$GEO_BASE/geoip.dat"
curl -fsSL -o /usr/local/bin/geosite.dat "$GEO_BASE/geosite.dat"

# --- hysteria2 ---
if [[ "$INSTALL_HY2" =~ ^[Yy] ]]; then
    echo "--- Installing hysteria2 ---"
    bash <(curl -fsSL https://get.hy2.sh/) || true
fi

# --- Panel files ---
echo "--- Installing panel ---"
mkdir -p /opt/clawpanel /opt/claw-agent /etc/claw-xray-hy /etc/claw-agent /etc/hysteria /var/www/fake /var/lib/clawpanel/certs

cp -r "$REPO_DIR/panel/"* /opt/clawpanel/
cp "$REPO_DIR/agent/agent.py" /opt/claw-agent/
cp "$REPO_DIR/scripts/hy2-sync" /usr/local/bin/hy2-sync
chmod +x /usr/local/bin/hy2-sync
cp "$REPO_DIR/scripts/update-xray" /usr/local/bin/update-xray
chmod +x /usr/local/bin/update-xray
cp "$REPO_DIR/scripts/update-hysteria" /usr/local/bin/update-hysteria
chmod +x /usr/local/bin/update-hysteria
cp "$REPO_DIR/fake-site/index.html" /var/www/fake/

# --- Python venv ---
echo "--- Setting up Python venv ---"
python3 -m venv /opt/clawpanel/venv
/opt/clawpanel/venv/bin/pip install --quiet --upgrade pip
/opt/clawpanel/venv/bin/pip install --quiet -r /opt/clawpanel/requirements.txt

# --- TLS certificate ---
echo "--- Obtaining TLS certificate ---"
systemctl stop nginx 2>/dev/null || true
certbot certonly --standalone --non-interactive --agree-tos --email "$LE_EMAIL" -d "$DOMAIN"
ln -sf /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem /var/lib/clawpanel/certs/fullchain.pem
ln -sf /etc/letsencrypt/live/"$DOMAIN"/privkey.pem   /var/lib/clawpanel/certs/key.pem

# certbot renews the cert on a timer (~30 days before expiry), but the services
# read the cert into memory at startup and won't pick up the new one on their
# own. This deploy hook fires only after a successful renewal and reloads/restarts
# everyone that uses the cert. Without it, ~60 days out clients would silently get
# the expired cert.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/clawpanel.sh <<'HOOK'
#!/bin/bash
# Reload/restart everything that serves the renewed TLS cert.
# nginx terminates TLS for xhttp (443/2053/2083); reload is graceful.
systemctl reload nginx 2>/dev/null || true
# hysteria reads the cert files directly (UDP/443); needs a restart.
systemctl restart hysteria 2>/dev/null || true
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/clawpanel.sh

# --- Configs ---
echo "--- Writing configs ---"

# Panel .env
sed -e "s|__DOMAIN__|$DOMAIN|g" \
    "$REPO_DIR/panel/env.template" > /opt/clawpanel/.env
chmod 600 /opt/clawpanel/.env

# Agent env
sed -e "s|__AGENT_SECRET__|$AGENT_SECRET|g" \
    -e "s|__NODE_NAME__|$NODE_NAME|g" \
    "$REPO_DIR/agent/env.template" > /etc/claw-agent/env
chmod 600 /etc/claw-agent/env

# nginx
sed -e "s|__DOMAIN__|$DOMAIN|g" \
    -e "s|__XHTTP_PATH__|$XHTTP_PATH|g" \
    "$REPO_DIR/nginx/claw.conf.template" > /etc/nginx/sites-available/claw.conf
sed -e "s|__DOMAIN__|$DOMAIN|g" \
    "$REPO_DIR/nginx/panel.conf.template" > /etc/nginx/sites-available/panel.conf
ln -sf /etc/nginx/sites-available/claw.conf  /etc/nginx/sites-enabled/claw.conf
ln -sf /etc/nginx/sites-available/panel.conf /etc/nginx/sites-enabled/panel.conf
rm -f /etc/nginx/sites-enabled/default
nginx -t

# systemd
cp "$REPO_DIR/systemd/"*.service /etc/systemd/system/
systemctl daemon-reload

# --- Restore or init DB ---
mkdir -p /opt/clawpanel/data
if [[ -n "$RESTORE_PATH" ]] && [[ -f "$RESTORE_PATH" ]]; then
    echo "--- Restoring from backup ---"
    tar -xzf "$RESTORE_PATH" -C /opt/clawpanel/data --strip-components=1
fi

# Init DB on first boot via panel itself, then patch admin pass and agent secret
echo "--- Initializing database ---"
cd /opt/clawpanel
/opt/clawpanel/venv/bin/python3 -c "
import asyncio, sqlite3, hashlib
import models
asyncio.run(models.init_db())
con = sqlite3.connect('data/claw.db')
con.execute('UPDATE admin SET password_hash=? WHERE username=?',
            (hashlib.sha256(b'$ADMIN_PASS').hexdigest(), 'admin'))
con.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
            ('agent_secret', '$AGENT_SECRET'))
con.commit()
con.close()
"

# Create node entry for this server
/opt/clawpanel/venv/bin/python3 -c "
import sqlite3, uuid, time
con = sqlite3.connect('/opt/clawpanel/data/claw.db')
nid = str(uuid.uuid4())[:8]
con.execute(
    'INSERT OR IGNORE INTO nodes (id, name, address, flag, label, xhttp_path, created_at) VALUES (?,?,?,?,?,?,?)',
    (nid, '$NODE_NAME', '$DOMAIN', '🌍', '$NODE_NAME', '$XHTTP_PATH', time.time())
)
con.commit()
con.close()
"

# --- Firewall ---
echo "--- Configuring UFW ---"
ufw --force enable
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'ACME http-01 (certbot standalone renewal)'
ufw allow 443/tcp comment 'nginx TLS'
ufw allow 2053/tcp comment 'panel/xray'
ufw allow 2083/tcp comment 'panel admin'
[[ "$INSTALL_HY2" =~ ^[Yy] ]] && ufw allow 443/udp comment 'hysteria2'

# --- Start services ---
# Order matters: the agent fetches its config from the panel, and xray-hy /
# hysteria need the config the agent renders. Starting them all at once makes
# xray-hy crash-loop on a missing config and hit the systemd start limit.
echo "--- Starting services ---"
systemctl enable claw-xray-hy
[[ "$INSTALL_HY2" =~ ^[Yy] ]] && systemctl enable hysteria

# 1. Panel first.
systemctl enable --now clawpanel

# 2. Wait until the panel answers, so the agent's first sync succeeds.
echo -n "    waiting for panel "
for _ in $(seq 1 30); do
    if curl -fsS -o /dev/null http://127.0.0.1:3100/healthz 2>/dev/null; then
        echo "ok"; break
    fi
    echo -n "."; sleep 1
done

# 3. Agent — renders /etc/claw-xray-hy/config.json (and the hysteria config)
#    on its first sync, which runs immediately on start.
systemctl enable --now claw-agent

# 4. Wait for the rendered xray config before starting xray-hy.
echo -n "    waiting for xray config "
for _ in $(seq 1 60); do
    if [[ -s /etc/claw-xray-hy/config.json ]]; then
        echo "ok"; break
    fi
    echo -n "."; sleep 1
done
systemctl start claw-xray-hy || true

# 5. Hysteria — wait for its config too.
if [[ "$INSTALL_HY2" =~ ^[Yy] ]]; then
    echo -n "    waiting for hysteria config "
    for _ in $(seq 1 30); do
        if [[ -s /etc/hysteria/config.yaml ]]; then
            echo "ok"; break
        fi
        echo -n "."; sleep 1
    done
    systemctl start hysteria || true
fi

systemctl start nginx

echo
echo "============================================"
echo "  ClawPanel installed"
echo "============================================"
echo "  Panel:    https://$DOMAIN:2083"
echo "  Login:    admin"
echo "  Password: $ADMIN_PASS"
echo
echo "  Agent secret: $AGENT_SECRET"
echo "  XHTTP path:   $XHTTP_PATH"
echo
echo "  Save these credentials — they are not shown again."
echo "============================================"
