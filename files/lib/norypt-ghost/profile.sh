#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — device-profile catalog: load, select, derive.
# Sourced by functions.sh and the init.d services.

_PROFILES_PATH=/usr/share/norypt-ghost/profiles.json

# Unbiased random integer in [0, $1) from /dev/urandom (rejection sampling).
_rand_below() {
    local n="$1"
    local limit max v
    [ "$n" -gt 0 ] || { echo 0; return; }
    max=65536
    limit=$(( max - (max % n) ))
    while :; do
        v=$(od -An -N2 -tu2 /dev/urandom | tr -d ' ')
        [ "$v" -lt "$limit" ] && { echo $(( v % n )); return; }
    done
}

# Emit $1 random chars from charset $2 ("hex"|"lower"|"digits").
_rand_chars() {
    local count="$1" kind="$2" set i out=""
    case "$kind" in
        hex)    set="0123456789abcdef" ;;
        lower)  set="0123456789abcdefghijklmnopqrstuvwxyz" ;;
        digits) set="0123456789" ;;
    esac
    i=0
    while [ "$i" -lt "$count" ]; do
        out="${out}$(printf '%s' "$set" | cut -c "$(( $(_rand_below ${#set}) + 1 ))")"
        i=$(( i + 1 ))
    done
    printf '%s' "$out"
}

# Replace {Nhex}/{Nlower}/{Ndigits} tokens in $1 with random chars.
_expand_format() {
    local fmt="$1"
    local out="" rest tok n kind
    rest="$fmt"
    while printf '%s' "$rest" | grep -q '{[0-9]\+\(hex\|lower\|digits\)}'; do
        out="${out}${rest%%\{*}"                 # literal before first {
        tok="${rest#*\{}"; tok="${tok%%\}*}"     # e.g. 4hex
        rest="${rest#*\}}"                        # remainder after }
        n="$(printf '%s' "$tok" | tr -dc '0-9')"
        # shellcheck disable=SC2018
        kind="$(printf '%s' "$tok" | tr -dc 'a-z')"
        out="${out}$(_rand_chars "$n" "$kind")"
    done
    printf '%s' "${out}${rest}"
}

# Map an IMSI's MCC (first 3 digits) to a region; $2 = default if unknown.
# NA = North America MCCs (310-316, 302, 330-...); everything in the EU table
# returns EU; else the default.
_mcc_region() {
    local imsi="$1"
    local default="$2"
    local mcc
    mcc="$(printf '%s' "$imsi" | cut -c1-3)"
    case "$mcc" in
        310|311|312|313|314|315|316|302|330|334) echo NA ;;
        2[0-9][0-9]) echo EU ;;     # ITU zone 2 = Europe
        *) echo "$default" ;;
    esac
}

# List "id weight" for profiles in region $1.
_profile_list_region() {
    local region="$1" n i id reg wt
    n="$(jsonfilter -i "$_PROFILES_PATH" -e '@.profiles[*].id' | wc -l)"
    i=0
    while [ "$i" -lt "$n" ]; do
        reg="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].region")"
        if [ "$reg" = "$region" ]; then
            id="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].id")"
            wt="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].weight")"
            echo "$id ${wt:-1}"
        fi
        i=$(( i + 1 ))
    done
}

# Pick one profile id in region $1, weighted. Falls back to any region if empty.
_profile_pick() {
    local region="$1" pool total pick acc id wt
    pool="$(_profile_list_region "$region")"
    [ -n "$pool" ] || pool="$(_profile_list_region NA)$(printf '\n')$(_profile_list_region EU)"
    total=0
    while read -r id wt; do [ -n "$id" ] && total=$(( total + wt )); done <<EOF
$pool
EOF
    [ "$total" -gt 0 ] || return 1
    pick=$(_rand_below "$total"); acc=0
    while read -r id wt; do
        [ -n "$id" ] || continue
        acc=$(( acc + wt ))
        [ "$pick" -lt "$acc" ] && { echo "$id"; return 0; }
    done <<EOF
$pool
EOF
}

# Index of the profile with id $1.
_profile_index() {
    local want="$1" n i id
    n="$(jsonfilter -i "$_PROFILES_PATH" -e '@.profiles[*].id' | wc -l)"
    i=0
    while [ "$i" -lt "$n" ]; do
        id="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$i].id")"
        [ "$id" = "$want" ] && { echo "$i"; return 0; }
        i=$(( i + 1 ))
    done
    return 1
}

# Pick a random element from the jsonfilter array at path $2 of profile index $1.
_profile_pick_array() {
    local idx="$1" path="$2" vals cnt
    vals="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].$path")"
    cnt="$(printf '%s\n' "$vals" | grep -c '.')"
    [ "$cnt" -gt 0 ] || return 1
    printf '%s\n' "$vals" | sed -n "$(( $(_rand_below "$cnt") + 1 ))p"
}

# Derive every identifier for profile id $1 into NG_* shell vars.
_profile_derive() {
    local id="$1" idx
    idx="$(_profile_index "$id")" || return 1
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_VENDOR="$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].vendor")"
    NG_TAC="$(_profile_pick_array "$idx" 'imei_tacs[*].tac')"
    NG_WIFI_OUI="$(_profile_pick_array "$idx" 'wifi_oui[*]')"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_CLIENT_OUI="$(_profile_pick_array "$idx" 'client_oui[*]')"
    NG_SSID="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].ssid_format")")"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_GUEST_SSID="${NG_SSID}-Guest"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_PSK="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].psk_format")")"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_GUEST_PSK="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].psk_format")")"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_HOSTNAME="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].hostname_format")")"
    # shellcheck disable=SC2034  # consumed by callers (identity.sh) as a global
    NG_DHCP_HOSTNAME="$(_expand_format "$(jsonfilter -i "$_PROFILES_PATH" -e "@.profiles[$idx].dhcp_hostname_format")")"
    [ -n "$NG_TAC" ] && [ -n "$NG_WIFI_OUI" ]
}
