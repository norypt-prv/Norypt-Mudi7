#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — full-identity stage/apply engine.
# shellcheck source=/dev/null
. /lib/norypt-ghost/functions.sh   # also pulls profile.sh

_PENDING=/etc/norypt-ghost.identity-pending

# Pick a coherent identity and write its wireless/system half to UCI now;
# stage the IMEIs and a regen flag for the post-reboot apply.
IDENTITY_STAGE() {
    local region default_region id imei1 imei2 iface
    default_region="$(uci -q get norypt-ghost.options.default_region 2>/dev/null)"
    case "$default_region" in EU|NA) ;; *) default_region=NA ;; esac
    region="$(_mcc_region "$(READ_MCC)" "$default_region")"

    id="$(_profile_pick "$region")" || { echo "no profile for region $region" >&2; return 1; }
    _profile_derive "$id" || { echo "profile derive failed for $id" >&2; return 1; }

    # Wireless BSSIDs — all AP ifaces share the profile's wifi OUI.
    # shellcheck disable=SC2154
    for iface in wifi2g wifi5g wifi6g guest2g guest5g guest6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && \
            uci set "wireless.${iface}.macaddr=$(MAC_GEN routers "$NG_WIFI_OUI")"
    done
    # STA (upstream) gets the client-class OUI.
    if uci -q get wireless.sta >/dev/null 2>&1; then
        uci set "wireless.sta.macaddr=$(MAC_GEN clients "$NG_CLIENT_OUI")"
    fi
    # SSIDs.
    for iface in wifi2g wifi5g wifi6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.ssid=$NG_SSID"
    done
    for iface in guest2g guest5g guest6g; do
        uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.ssid=$NG_GUEST_SSID"
    done
    # PSKs.
    for iface in wifi2g wifi5g wifi6g;    do uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.key=$NG_PSK"; done
    for iface in guest2g guest5g guest6g; do uci -q get "wireless.${iface}" >/dev/null 2>&1 && uci set "wireless.${iface}.key=$NG_GUEST_PSK"; done
    uci -q set 'wireless.wifi0.random_bssid=0'; uci -q set 'wireless.wifi1.random_bssid=0'; uci -q set 'wireless.wifi2.random_bssid=0'
    uci commit wireless

    # Wired MAC + hostname + upstream DHCP hostname.
    RANDOMIZE_WIRED_MAC "$NG_CLIENT_OUI"
    uci set "system.@system[0].hostname=$NG_HOSTNAME"; uci commit system
    printf '%s' "$NG_HOSTNAME" > /proc/sys/kernel/hostname
    uci -q set "network.wan.hostname=$NG_DHCP_HOSTNAME" 2>/dev/null; uci -q commit network

    # Stage IMEIs (written pre-attach on next boot, profile mode with this TAC).
    imei1="$(_gen_imei 1 profile "$NG_TAC")"
    imei2="$(_gen_imei 2 profile "$NG_TAC")"
    printf 'PROFILE_ID=%s\nSTAGED_IMEI1=%s\nSTAGED_IMEI2=%s\nREGEN_KEYS=1\n' \
        "$id" "$imei1" "$imei2" > "$_PENDING"

    echo "$id"
}

# Post-reboot completion (invoked by norypt-ghost-sim-swap S25).
IDENTITY_APPLY_BOOT() {
    [ -f "$_PENDING" ] || return 0
    local PROFILE_ID="" STAGED_IMEI1="" STAGED_IMEI2="" REGEN_KEYS=0
    . "$_PENDING"; rm -f "$_PENDING"

    MODEM_RF_DISABLE
    if [ -n "$STAGED_IMEI1" ] && [ -n "$STAGED_IMEI2" ]; then
        SET_IMEIS "$STAGED_IMEI1" "$STAGED_IMEI2" || { logger -t norypt-ghost "identity: IMEI write failed"; _screen_splash error; return 1; }
    fi
    [ "$REGEN_KEYS" = "1" ] && IDENTITY_REGEN_KEYS
    RAT_LOCK_APPLY
    _at AT+CFUN=1 >/dev/null 2>&1
    date '+%Y-%m-%d %H:%M (new-identity)' > /tmp/norypt-ghost.last_imei_rotate
    logger -t norypt-ghost "identity applied: profile=$PROFILE_ID"
    # shellcheck disable=SC1010
    _screen_splash done
}

# Regenerate SSH host keys and the LuCI TLS cert — both are permanent device IDs.
IDENTITY_REGEN_KEYS() {
    rm -f /etc/dropbear/dropbear_*_host_key 2>/dev/null
    /etc/init.d/dropbear restart 2>/dev/null
    if [ -x /etc/init.d/uhttpd ]; then
        rm -f /etc/uhttpd.crt /etc/uhttpd.key 2>/dev/null
        [ -x /usr/sbin/px5g ] && px5g selfsigned -der \
            -keyout /etc/uhttpd.key -out /etc/uhttpd.crt \
            -subj "/C=US/CN=$(cat /proc/sys/kernel/hostname)" 2>/dev/null
        /etc/init.d/uhttpd restart 2>/dev/null
    fi
}
