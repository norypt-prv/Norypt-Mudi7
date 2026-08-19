#!/usr/bin/env bash
# Build the norypt-ghost-touch evdev daemon for the Mudi 7 (aarch64, static).
#
# The binary is a build artifact and is deliberately NOT committed: a checked-in
# blob silently drifts from src/ and ships unauditable code to the router.
#
# Tries, in order:
#   1. a native aarch64 cross-compiler  (apt install gcc-aarch64-linux-gnu)
#   2. Docker + QEMU binfmt with alpine (musl, smallest output)
#
# Output: files/usr/bin/norypt-ghost-touch  (stripped)
# Usage:  ./tools/build-touch.sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${REPO}/files/usr/bin/norypt-ghost-touch"

# The daemon is now multi-file: the state machine plus the fb/menu/screens/imei/
# fbdev modules it builds on. Keep this list in sync with the Makefile and
# sdk-build.yml compile inputs.
SRCS="$REPO/src/norypt-ghost-touch.c $REPO/src/fb.c $REPO/src/menu.c $REPO/src/screens.c $REPO/src/imei.c $REPO/src/fbdev.c"

mkdir -p "$(dirname "$OUT")"

if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    echo "==> Building with aarch64-linux-gnu-gcc"
    # shellcheck disable=SC2086
    aarch64-linux-gnu-gcc -O2 -s -static -I "$REPO/src" -o "$OUT" $SRCS

elif command -v docker >/dev/null 2>&1; then
    echo "==> Building with Docker (alpine/musl, linux/arm64)"
    docker run --rm --platform linux/arm64 \
        -v "${REPO}/src:/src:ro" -v "$(dirname "$OUT"):/out" \
        alpine:3.20 \
        sh -c 'apk add --no-cache gcc musl-dev linux-headers >/dev/null && \
               gcc -O2 -s -static -I /src -o /out/norypt-ghost-touch \
                   /src/norypt-ghost-touch.c /src/fb.c /src/menu.c \
                   /src/screens.c /src/imei.c /src/fbdev.c'

else
    cat >&2 <<'EOF'
ERROR: no aarch64 toolchain found.

Install one of:
  sudo apt install -y gcc-aarch64-linux-gnu     # Debian/Ubuntu/WSL
  docker + QEMU binfmt                          # any host

Or skip the local build entirely: the OpenWrt SDK path (Makefile) and the
sdk-build.yml CI workflow both compile this daemon from source.
EOF
    exit 1
fi

if file "$OUT" | grep -q 'not stripped'; then
    echo "ERROR: output is unstripped — rebuild with -s" >&2
    exit 1
fi

echo "==> $(basename "$OUT") $(du -h "$OUT" | cut -f1)"
file "$OUT"
