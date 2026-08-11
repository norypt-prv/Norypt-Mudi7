#!/usr/bin/env bash
# Deploy Norypt Ghost files to the Mudi 7 over SSH.
# Usage:  ./deploy.sh [host]   (default host: root@192.168.8.1)
set -e
HOST="${1:-root@192.168.8.1}"
REPO="$(cd "$(dirname "$0")" && pwd)"

echo "==> Deploying Norypt Ghost to $HOST"

# Create target directories
ssh "$HOST" 'mkdir -p /lib/norypt-ghost /usr/bin /usr/libexec /usr/share/norypt-ghost /etc/init.d \
    /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view'

# Library files (-O forces legacy SCP protocol; OpenWrt busybox sshd needs it)
scp -O "$REPO/files/lib/norypt-ghost/functions.sh"      "$HOST:/lib/norypt-ghost/functions.sh"
scp -O "$REPO/files/lib/norypt-ghost/imei_generate.lua" "$HOST:/lib/norypt-ghost/imei_generate.lua"
scp -O "$REPO/files/lib/norypt-ghost/luhn.lua"          "$HOST:/lib/norypt-ghost/luhn.lua"

# CLI
scp -O "$REPO/files/usr/bin/norypt-ghost"       "$HOST:/usr/bin/norypt-ghost"
scp -O "$REPO/files/usr/bin/norypt-ghost-touch" "$HOST:/usr/bin/norypt-ghost-touch"
ssh "$HOST" 'chmod +x /usr/bin/norypt-ghost /usr/bin/norypt-ghost-touch'

# init.d services
scp -O "$REPO/files/etc/init.d/norypt-ghost-wireless"      "$HOST:/etc/init.d/norypt-ghost-wireless"
scp -O "$REPO/files/etc/init.d/norypt-ghost-sim-swap"      "$HOST:/etc/init.d/norypt-ghost-sim-swap"
scp -O "$REPO/files/etc/init.d/norypt-ghost-volatile-macs" "$HOST:/etc/init.d/norypt-ghost-volatile-macs"
scp -O "$REPO/files/etc/init.d/norypt-ghost-touch"         "$HOST:/etc/init.d/norypt-ghost-touch"
ssh "$HOST" 'chmod +x /etc/init.d/norypt-ghost-wireless /etc/init.d/norypt-ghost-sim-swap \
        /etc/init.d/norypt-ghost-volatile-macs /etc/init.d/norypt-ghost-touch \
    && rm -f /etc/rc.d/S*norypt-ghost-wireless /etc/rc.d/S*norypt-ghost-sim-swap \
        /etc/rc.d/S*norypt-ghost-volatile-macs /etc/rc.d/S*norypt-ghost-touch \
    && /etc/init.d/norypt-ghost-wireless enable \
    && /etc/init.d/norypt-ghost-sim-swap enable \
    && /etc/init.d/norypt-ghost-volatile-macs enable \
    && /etc/init.d/norypt-ghost-touch enable'

# Data pools and splash frames
scp -O "$REPO/files/usr/share/norypt-ghost/tac_pool.json" "$HOST:/usr/share/norypt-ghost/tac_pool.json"
scp -O "$REPO/files/usr/share/norypt-ghost/oui_pool.json" "$HOST:/usr/share/norypt-ghost/oui_pool.json"
ssh "$HOST" 'mkdir -p /usr/share/norypt-ghost/screens'
scp -O "$REPO/files/usr/share/norypt-ghost/screens/"*.rgb565 "$HOST:/usr/share/norypt-ghost/screens/"

# LuCI Phase 3 — modern LuCI2 JS view
# Remove old Lua/HTM approach if it was previously deployed
ssh "$HOST" 'rm -f /usr/lib/lua/luci/controller/norypt_ghost.lua \
    /usr/lib/lua/luci/view/norypt_ghost/index.htm \
    && rmdir /usr/lib/lua/luci/view/norypt_ghost /usr/lib/lua/luci/view 2>/dev/null; true'

# rpcd exec backend
scp -O "$REPO/files/usr/libexec/norypt-ghost" "$HOST:/usr/libexec/norypt-ghost"
ssh "$HOST" 'chmod +x /usr/libexec/norypt-ghost'

# Menu and ACL registration
scp -O "$REPO/files/usr/share/luci/menu.d/luci-app-norypt-ghost.json" \
    "$HOST:/usr/share/luci/menu.d/luci-app-norypt-ghost.json"
scp -O "$REPO/files/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json" \
    "$HOST:/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json"

# JS view
scp -O "$REPO/files/www/luci-static/resources/view/norypt_ghost.js" \
    "$HOST:/www/luci-static/resources/view/norypt_ghost.js"
# Remove the old hyphen-named file if it was previously deployed
ssh "$HOST" 'rm -f /www/luci-static/resources/view/norypt-ghost.js'

# Reload rpcd so the new ACL is picked up; clear LuCI caches
ssh "$HOST" '/etc/init.d/rpcd reload; rm -f /tmp/luci-indexcache*'

echo ""
echo "==> Deploy complete. Verify with: ssh $HOST norypt-ghost status"
echo "    LuCI page: http://${HOST#*@}:8080 → Services → Norypt Ghost"
