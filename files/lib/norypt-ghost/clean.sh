#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — ephemeral state: never persist connected-device history.
# shellcheck source=/dev/null
. /lib/norypt-ghost/functions.sh

# Directories that hold per-client history; tmpfs-mount any that exist.
_CLEAN_DIRS="/etc/oui-tertf /var/lib/nlbwmon /etc/vnstat /var/lib/vnstat"

_is_tmpfs() { mount | grep -q "tmpfs on $1 "; }

CLEAN_APPLY() {
    # 1. System log to RAM only — unset any flash log_file.
    if [ -n "$(uci -q get system.@system[0].log_file 2>/dev/null)" ]; then
        uci -q delete system.@system[0].log_file; uci -q commit system
    fi
    # 2. tmpfs over each present telemetry dir (before its daemon starts).
    local d
    for d in $_CLEAN_DIRS; do
        [ -d "$d" ] || continue
        _is_tmpfs "$d" && continue
        rm -f "$d"/* 2>/dev/null
        mount -t tmpfs tmpfs "$d"
    done
    # 3. dnsmasq: no query log, no persistent cache.
    uci -q set dhcp.@dnsmasq[0].logqueries=0
    uci -q set dhcp.@dnsmasq[0].cachelocal=0
    uci -q commit dhcp
    # 4. DHCP leases to RAM (OpenWrt default is /tmp; enforce if GL redirected it).
    local lf; lf="$(uci -q get dhcp.@dnsmasq[0].leasefile 2>/dev/null)"
    case "$lf" in /tmp/*|"") ;; *) uci -q set dhcp.@dnsmasq[0].leasefile=/tmp/dhcp.leases; uci -q commit dhcp ;; esac
    # 5. Sweep any legacy flash-persisted rotation timestamps. Older builds wrote
    #    these to /etc; the no-log model keeps them in RAM (/tmp) only, so any
    #    /etc copy is a forensic trace of when the identity last changed.
    rm -f /etc/norypt-ghost.last_imei_rotate /etc/norypt-ghost.last_wireless_rotate 2>/dev/null
    logger -t norypt-ghost "clean: telemetry persistence disabled"
}

CLEAN_WIPE() {
    local d
    # shellcheck disable=SC2086
    for d in $_CLEAN_DIRS; do _is_tmpfs "$d" && rm -f "$d"/* 2>/dev/null; done
    rm -f /tmp/dhcp.leases 2>/dev/null
}

CLEAN_STATUS() {
    local _ng_status_fail=0
    if [ -z "$(uci -q get system.@system[0].log_file 2>/dev/null)" ]; then
        echo "  PASS  syslog not persisted to flash"
    else
        echo "  FAIL  syslog log_file set — logs hitting flash"
        _ng_status_fail=1
    fi
    local d
    # shellcheck disable=SC2086
    for d in $_CLEAN_DIRS; do
        [ -d "$d" ] || continue
        if _is_tmpfs "$d"; then
            echo "  PASS  $d is RAM-backed"
        else
            echo "  FAIL  $d on flash"
            _ng_status_fail=1
        fi
    done
    return "$_ng_status_fail"
}
