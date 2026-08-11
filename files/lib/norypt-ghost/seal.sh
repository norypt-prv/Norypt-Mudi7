#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Norypt Ghost — factory-state sealing. openssl if present, else plain fallback.

_seal_tool() { command -v openssl 2>/dev/null; }

SEAL_AVAILABLE() { [ -n "$(_seal_tool)" ]; }

# SEAL_ENCRYPT <plaintext-file> <passphrase> -> base64 blob on stdout.
SEAL_ENCRYPT() {
    local f="$1" pass="$2"
    SEAL_AVAILABLE || { _b64 < "$f"; return; }        # plain fallback: base64 only
    openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -a \
        -in "$f" -pass "pass:${pass}" 2>/dev/null
}

# SEAL_DECRYPT <blob> <passphrase> -> plaintext on stdout; non-zero on failure.
SEAL_DECRYPT() {
    local blob="$1" pass="$2"
    SEAL_AVAILABLE || { printf '%s' "$blob" | _unb64; return; }
    printf '%s\n' "$blob" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -a \
        -pass "pass:${pass}" 2>/dev/null
}

SEAL_MODE() {
    local want; want="$(uci -q get norypt-ghost.options.factory_mode 2>/dev/null)"
    if [ "$want" = "plain" ]; then echo plain; return; fi
    SEAL_AVAILABLE && echo sealed || echo plain
}

_b64()   { openssl base64 2>/dev/null || busybox base64; }
_unb64() { openssl base64 -d 2>/dev/null || busybox base64 -d; }
