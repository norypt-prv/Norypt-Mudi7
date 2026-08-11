#!/usr/bin/env bash
# Build norypt-ghost_VERSION-Script-BUILDMETHOD.ipk without the OpenWrt SDK.
# ("Script" marks the build path, alongside the SDK workflow's -SDK- assets.)
# Usage: ./build-ipk.sh
# BUILD_METHOD env var controls the suffix: Local (default) | CI | Release
set -e

PKG_NAME=norypt-ghost
PKG_VERSION=1.0.0
BUILD_METHOD="${BUILD_METHOD:-Local}"
ARCH=aarch64_cortex-a53

REPO="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${REPO}/build"
STAGING="${BUILD_DIR}/staging"
CONTROL_DIR="${BUILD_DIR}/control"
OUTPUT="${REPO}/${PKG_NAME}_${PKG_VERSION}-Script-${BUILD_METHOD}.ipk"

# ── Preflight ─────────────────────────────────────────────────────────────────

for _tool in ar tar install file; do
    command -v "$_tool" >/dev/null || { echo "ERROR: '$_tool' not found"; exit 1; }
done

# The touch daemon is a build artifact, never committed — build it on demand
# from src/ so the shipped binary can never drift from the source.
TOUCH_BIN="$REPO/files/usr/bin/norypt-ghost-touch"
if [ ! -f "$TOUCH_BIN" ] || [ "$REPO/src/norypt-ghost-touch.c" -nt "$TOUCH_BIN" ]; then
    echo "==> Touch daemon missing or out of date — building from src/"
    "$REPO/tools/build-touch.sh"
fi

# An unstripped binary ships ~290 KB of debug symbols to the router for nothing.
if file "$TOUCH_BIN" | grep -q 'not stripped'; then
    echo "ERROR: $TOUCH_BIN is unstripped — rebuild with 'gcc -s' or run aarch64 strip on it"
    exit 1
fi

echo "==> Building $(basename "$OUTPUT")"

rm -rf "$BUILD_DIR"
mkdir -p "$STAGING" "$CONTROL_DIR"

# ── Stage files ───────────────────────────────────────────────────────────────

install -d "$STAGING/lib/norypt-ghost"
install -m 0644 "$REPO/files/lib/norypt-ghost/functions.sh"         "$STAGING/lib/norypt-ghost/functions.sh"
install -m 0644 "$REPO/files/lib/norypt-ghost/imei_generate.lua"    "$STAGING/lib/norypt-ghost/imei_generate.lua"
install -m 0644 "$REPO/files/lib/norypt-ghost/luhn.lua"             "$STAGING/lib/norypt-ghost/luhn.lua"
install -m 0644 "$REPO/files/lib/norypt-ghost/profile.sh"           "$STAGING/lib/norypt-ghost/profile.sh"
install -m 0644 "$REPO/files/lib/norypt-ghost/identity.sh"          "$STAGING/lib/norypt-ghost/identity.sh"
install -m 0644 "$REPO/files/lib/norypt-ghost/clean.sh"             "$STAGING/lib/norypt-ghost/clean.sh"
install -m 0644 "$REPO/files/lib/norypt-ghost/seal.sh"              "$STAGING/lib/norypt-ghost/seal.sh"

install -d "$STAGING/usr/bin"
install -m 0755 "$REPO/files/usr/bin/norypt-ghost"                  "$STAGING/usr/bin/norypt-ghost"
install -m 0755 "$REPO/files/usr/bin/norypt-ghost-touch"            "$STAGING/usr/bin/norypt-ghost-touch"

install -d "$STAGING/usr/libexec"
install -m 0755 "$REPO/files/usr/libexec/norypt-ghost"              "$STAGING/usr/libexec/norypt-ghost"

install -d "$STAGING/etc/init.d"
install -m 0755 "$REPO/files/etc/init.d/norypt-ghost-wireless"      "$STAGING/etc/init.d/norypt-ghost-wireless"
install -m 0755 "$REPO/files/etc/init.d/norypt-ghost-sim-swap"      "$STAGING/etc/init.d/norypt-ghost-sim-swap"
install -m 0755 "$REPO/files/etc/init.d/norypt-ghost-clean"         "$STAGING/etc/init.d/norypt-ghost-clean"
install -m 0755 "$REPO/files/etc/init.d/norypt-ghost-touch"         "$STAGING/etc/init.d/norypt-ghost-touch"
install -m 0755 "$REPO/files/etc/init.d/norypt-ghost-ttl"           "$STAGING/etc/init.d/norypt-ghost-ttl"

install -d "$STAGING/usr/share/norypt-ghost"
install -m 0644 "$REPO/files/usr/share/norypt-ghost/tac_pool.json"  "$STAGING/usr/share/norypt-ghost/tac_pool.json"
install -m 0644 "$REPO/files/usr/share/norypt-ghost/oui_pool.json"  "$STAGING/usr/share/norypt-ghost/oui_pool.json"
install -m 0644 "$REPO/files/usr/share/norypt-ghost/profiles.json"  "$STAGING/usr/share/norypt-ghost/profiles.json"

install -d "$STAGING/usr/share/norypt-ghost/screens"
for _f in "$REPO/files/usr/share/norypt-ghost/screens/"*.rgb565; do
    install -m 0644 "$_f" "$STAGING/usr/share/norypt-ghost/screens/$(basename "$_f")"
done

install -d "$STAGING/usr/share/luci/menu.d"
install -m 0644 "$REPO/files/usr/share/luci/menu.d/luci-app-norypt-ghost.json" \
    "$STAGING/usr/share/luci/menu.d/luci-app-norypt-ghost.json"

install -d "$STAGING/usr/share/rpcd/acl.d"
install -m 0644 "$REPO/files/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json" \
    "$STAGING/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json"

install -d "$STAGING/www/luci-static/resources/view"
install -m 0644 "$REPO/files/www/luci-static/resources/view/norypt_ghost.js" \
    "$STAGING/www/luci-static/resources/view/norypt_ghost.js"

# ── Installed size (kB) ───────────────────────────────────────────────────────

INSTALLED_SIZE=$(du -sk "$STAGING" | awk '{print $1}')

# ── Control file ──────────────────────────────────────────────────────────────

cat > "$CONTROL_DIR/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Depends: luci-base, lua, luabitop
Source: ${PKG_NAME}
License: GPL-2.0-only
Section: utils
Maintainer: Norypt Team
Architecture: ${ARCH}
Installed-Size: ${INSTALLED_SIZE}
Description: Anonymity Enhancements for GL-iNet GL-E5800 Mudi 7
 norypt-ghost enhances anonymity and reduces forensic traceability of the
 GL-iNet GL-E5800 (Mudi 7) 5G mobile Wi-Fi router by randomizing IMEI,
 MAC addresses, SSID, hostname, and Wi-Fi password on every boot or on demand.
EOF

# ── preinst ───────────────────────────────────────────────────────────────────

cat > "$CONTROL_DIR/preinst" <<'PREINST'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

_require_tty() {
    if [ ! -t 0 ]; then
        echo "Non-interactive install — cannot confirm. Re-run 'opkg install' from an SSH shell."
        exit 1
    fi
}

_abort_model() {
    echo ""
    echo "Norypt Ghost is designed for the GL-iNet GL-E5800 (Mudi 7)."
    [ -f /tmp/sysinfo/model ] && echo "Detected device: $(cat /tmp/sysinfo/model)"
    _require_tty
    printf "Continue installation on unsupported device? (y/N): "
    read -r answer
    case "$answer" in [yY]*) ;; *) exit 1 ;; esac
}

_abort_version() {
    echo ""
    echo "Norypt Ghost has been tested on GL-E5800 firmware 4.8.3 and 4.8.5 only."
    [ -f /etc/glversion ] && echo "Detected firmware: $(cat /etc/glversion)"
    echo "Newer firmware versions may have changed the AT interface or UCI layout."
    _require_tty
    printf "Continue installation on untested firmware? (y/N): "
    read -r answer
    case "$answer" in [yY]*) ;; *) exit 1 ;; esac
}

if ! grep -qi "E5800" /tmp/sysinfo/model 2>/dev/null; then
    _abort_model
fi

if [ -f /etc/glversion ]; then
    GL_VERSION="$(cat /etc/glversion)"
    case "$GL_VERSION" in
        4.8.3|4.8.5)
                echo "Firmware $GL_VERSION confirmed supported." ;;
        4.8.*)  echo "Firmware $GL_VERSION is newer than tested — probably compatible."
                _abort_version ;;
        4.*)    echo "Firmware $GL_VERSION has not been tested with Norypt Ghost."
                _abort_version ;;
        *)      echo "Unrecognised firmware version: $GL_VERSION"
                _abort_version ;;
    esac
fi

# Crypto probe: sealing (Task E2) needs openssl. Non-fatal — factory state
# just stays plain, same as every install before sealing existed.
if ! command -v openssl >/dev/null 2>&1; then
    echo "norypt-ghost: openssl not found — factory state will be stored UNSEALED."
    echo "  To enable passphrase-sealed storage: opkg install openssl-util, then reinstall norypt-ghost."
fi

[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients stop 2>/dev/null
exit 0
PREINST

# ── postinst ──────────────────────────────────────────────────────────────────

cat > "$CONTROL_DIR/postinst" <<'POSTINST'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

for _radio in wifi0 wifi1 wifi2; do
    uci -q set "wireless.${_radio}.random_bssid=0" 2>/dev/null
done
uci -q commit wireless

/etc/init.d/norypt-ghost-clean enable
/etc/init.d/norypt-ghost-wireless enable
/etc/init.d/norypt-ghost-sim-swap enable
/etc/init.d/norypt-ghost-ttl enable

# Touchscreen trigger: respect a preference saved by a previous install
# (LuCI toggle persists it to UCI); default to enabled on fresh installs.
if [ "$(uci -q get norypt-ghost.options.touch_enabled 2>/dev/null)" != "0" ]; then
    /etc/init.d/norypt-ghost-touch enable
    /etc/init.d/norypt-ghost-touch start
fi

/etc/init.d/norypt-ghost-clean start
/etc/init.d/norypt-ghost-ttl start
[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients start 2>/dev/null

# Offer to seal the factory identity (IMEIs/MACs/SSIDs/Wi-Fi keys) behind a
# passphrase before capture runs. Only on first install (no factory section
# yet) and only when crypto is available and factory_mode hasn't opted out.
# Non-interactive installs skip the prompt entirely — factory state stays
# plain, exactly as it did before sealing existed.
if command -v openssl >/dev/null 2>&1 \
    && [ "$(uci -q get norypt-ghost.options.factory_mode 2>/dev/null)" != "plain" ] \
    && ! uci -q get norypt-ghost.factory >/dev/null 2>&1; then
    if [ -t 0 ]; then
        echo "norypt-ghost: factory identity can be sealed behind a passphrase."
        echo "Leave blank to store it in plain UCI, as before."
        _ng_ok=0
        _ng_tries=0
        while [ "$_ng_ok" = "0" ] && [ "$_ng_tries" -lt 3 ]; do
            _ng_tries=$((_ng_tries + 1))
            printf "Passphrase (blank = plain): "
            stty -echo 2>/dev/null; read -r _ng_p1; stty echo 2>/dev/null; echo
            if [ -z "$_ng_p1" ]; then
                echo "norypt-ghost: leaving factory state unsealed."
                _ng_ok=1
            else
                printf "Confirm passphrase: "
                stty -echo 2>/dev/null; read -r _ng_p2; stty echo 2>/dev/null; echo
                if [ "$_ng_p1" = "$_ng_p2" ]; then
                    umask 077
                    printf '%s' "$_ng_p1" > /tmp/norypt-ghost.seal-pass
                    chmod 0600 /tmp/norypt-ghost.seal-pass
                    _ng_ok=1
                else
                    echo "norypt-ghost: passphrases did not match — try again."
                fi
            fi
            unset _ng_p1 _ng_p2
        done
        if [ "$_ng_ok" != "1" ]; then
            echo "norypt-ghost: too many mismatches — leaving factory state unsealed."
        fi
        unset _ng_ok _ng_tries
    else
        echo "norypt-ghost: non-interactive install — factory state will be stored unsealed."
        echo "  Re-run 'norypt-ghost install' from an interactive shell before the factory section exists to seal it."
    fi
fi

/usr/bin/norypt-ghost install

echo "norypt-ghost: installation complete. Rotate identity via: norypt-ghost rotate"
exit 0
POSTINST

# ── prerm ─────────────────────────────────────────────────────────────────────

cat > "$CONTROL_DIR/prerm" <<'PRERM'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

# Stop AND disable here, while the init scripts still exist — opkg deletes
# package files before postrm runs, so doing either there is a no-op.
/etc/init.d/norypt-ghost-touch stop 2>/dev/null
/etc/init.d/norypt-ghost-wireless stop 2>/dev/null
/etc/init.d/norypt-ghost-sim-swap stop 2>/dev/null
/etc/init.d/norypt-ghost-clean stop 2>/dev/null
/etc/init.d/norypt-ghost-ttl stop 2>/dev/null

/etc/init.d/norypt-ghost-touch disable 2>/dev/null
/etc/init.d/norypt-ghost-wireless disable 2>/dev/null
/etc/init.d/norypt-ghost-sim-swap disable 2>/dev/null
/etc/init.d/norypt-ghost-clean disable 2>/dev/null
/etc/init.d/norypt-ghost-ttl disable 2>/dev/null

# Sealed factory state cannot be restored non-interactively (no passphrase
# available here) — say so loudly instead of silently leaving the device on
# its rotated identity. Unsealed devices keep the exact prior behavior.
if [ "$(uci -q get norypt-ghost.factory.sealed 2>/dev/null)" = "1" ]; then
    echo "norypt-ghost: factory state is SEALED — the modem KEEPS its current identity. To restore the original identity, run 'norypt-ghost restore' with your passphrase BEFORE or AFTER removal."
else
    [ -x /usr/bin/norypt-ghost ] && /usr/bin/norypt-ghost restore 2>/dev/null
fi
exit 0
PRERM

# ── postrm ────────────────────────────────────────────────────────────────────

cat > "$CONTROL_DIR/postrm" <<'POSTRM'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0

for _radio in wifi0 wifi1 wifi2; do
    uci -q set "wireless.${_radio}.random_bssid=1" 2>/dev/null
done
uci -q commit wireless

# Services were stopped/disabled in prerm (scripts are deleted by now);
# sweep any rc.d symlinks left behind so nothing dangles.
rm -f /etc/rc.d/S*norypt-ghost* /etc/rc.d/K*norypt-ghost*

rm -f /etc/norypt-ghost.last_imei_rotate \
      /etc/norypt-ghost.last_wireless_rotate \
      /etc/norypt-ghost.sim-swap-pending

echo "norypt-ghost: uninstalled."
exit 0
POSTRM

chmod 0755 "$CONTROL_DIR/preinst" "$CONTROL_DIR/postinst" \
           "$CONTROL_DIR/prerm"   "$CONTROL_DIR/postrm"

# ── Assemble archives ─────────────────────────────────────────────────────────

echo "  Packing data..."
(cd "$STAGING"     && tar czf "$BUILD_DIR/data.tar.gz"    --owner=0 --group=0 .)

echo "  Packing control..."
(cd "$CONTROL_DIR" && tar czf "$BUILD_DIR/control.tar.gz" --owner=0 --group=0 .)

printf '2.0\n' > "$BUILD_DIR/debian-binary"

# ── Build IPK (gzip-compressed tar) ──────────────────────────────────────────
# This opkg uses the classic ipkg format: a gzip-compressed tar containing
# ./debian-binary, ./control.tar.gz, and ./data.tar.gz — NOT a Debian ar archive.

echo "  Creating IPK..."
rm -f "$OUTPUT"
(cd "$BUILD_DIR" && tar czf "$OUTPUT" --owner=0 --group=0 \
    ./debian-binary ./control.tar.gz ./data.tar.gz)

# ── Done ──────────────────────────────────────────────────────────────────────

SIZE=$(du -sh "$OUTPUT" | awk '{print $1}')
echo ""
echo "==> ${OUTPUT} (${SIZE})"
echo ""
echo "Install on device:"
echo "  scp -O '${OUTPUT}' root@192.168.8.1:/tmp/"
echo "  ssh root@192.168.8.1 'opkg install --force-reinstall /tmp/$(basename "$OUTPUT")'"
