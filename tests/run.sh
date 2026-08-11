#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host test entrypoint for Norypt Ghost. Runs shellcheck, python logic tests,
# the profile validator, and (if lua is present) the Lua unit tests.
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

echo "== shellcheck =="
shellcheck -s sh files/usr/bin/norypt-ghost files/usr/libexec/norypt-ghost \
    files/lib/norypt-ghost/*.sh files/etc/init.d/norypt-ghost-*

echo "== profile validator =="
python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json "$@"

echo "== python logic tests =="
python3 -m unittest discover -s tests -p 'test_*.py' -v

if command -v lua5.1 >/dev/null 2>&1 || command -v lua >/dev/null 2>&1; then
    echo "== lua unit tests =="
    LUA="$(command -v lua5.1 || command -v lua)"
    "$LUA" tests/lua/test_imei_generate.lua
else
    echo "== lua unit tests SKIPPED (no interpreter; runs in CI) =="
fi
echo "All host tests passed."
