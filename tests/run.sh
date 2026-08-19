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
python3 tests/validate_profiles.py files/usr/share/norypt-ghost/profiles.json --coherence "$@"

echo "== python logic tests =="
python3 -m unittest discover -s tests -p 'test_*.py' -v

if command -v lua5.1 >/dev/null 2>&1 || command -v lua >/dev/null 2>&1; then
    echo "== lua unit tests =="
    LUA="$(command -v lua5.1 || command -v lua)"
    # The test spawns the generator as a child process. Export the interpreter
    # it should use (Ubuntu ships lua5.1, not a plain `lua`), and put the
    # library dir on LUA_PATH — the generator prepends the on-device path
    # /lib/norypt-ghost/?.lua, which does not exist off-device, so without this
    # its `require("luhn")` cannot resolve. The trailing ";;" keeps the
    # interpreter's built-in default path.
    export NG_LUA="$LUA"
    export LUA_PATH="${REPO}/files/lib/norypt-ghost/?.lua;;"
    "$LUA" tests/lua/test_imei_generate.lua
else
    echo "== lua unit tests SKIPPED (no interpreter; runs in CI) =="
fi
echo "== C host tests =="
for t in tests/c/test_*.c; do
    base="$(basename "$t" .c)"
    gcc -Wall -Wextra -I src -o "/tmp/ng_$base" "$t" $(sed -n 's,^// LINK: ,,p' "$t") && "/tmp/ng_$base"
done

echo "All host tests passed."
