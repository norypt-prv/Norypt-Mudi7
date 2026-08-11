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
