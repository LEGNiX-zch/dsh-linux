#!/usr/bin/env bash
# assemble.sh — apply the source patches and rebuild the native addon
#
# This is the script that turns a freshly extracted upstream payload into the
# tree that the .deb is built from. It performs the three modifications
# documented under ../patches/ and nothing else.
#
# Usage:
#   ./assemble.sh <stage-dir> [--no-addon]
#
# <stage-dir> must already contain the extracted upstream payload, i.e. it
# must have opt/deepseek-harness/ underneath it.
#
# Options:
#   --no-addon   skip the native addon rebuild (patches 01 and 02 only)
#
# Exit codes:
#   0  all modifications applied
#   1  bad usage
#   2  payload layout not recognised
#   3  a patch failed to apply
#   4  addon rebuild failed

set -euo pipefail

die() {
    printf 'error: %s\n' "$1" >&2
    exit "${2:-1}"
}

info() {
    printf '[assemble] %s\n' "$1"
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="$SCRIPT_DIR/../patches"

# ---------------------------------------------------------------- arguments

if [ $# -lt 1 ]; then
    cat >&2 <<'USAGE'
Usage: assemble.sh <stage-dir> [--no-addon]

Example:
  ./assemble.sh /tmp/stage
USAGE
    exit 1
fi

STAGE=${1%/}
shift

BUILD_ADDON=1
for arg in "$@"; do
    case "$arg" in
        --no-addon) BUILD_ADDON=0 ;;
        *) die "unknown option: $arg" 1 ;;
    esac
done

[ -d "$STAGE" ] || die "not a directory: $STAGE" 1

# ------------------------------------------------------------- locate payload

RUNTIME="$STAGE/opt/deepseek-harness/runtime/dsh"
MODULES="$RUNTIME/node_modules/@deepseek-ai"

[ -d "$MODULES" ] || die "payload layout not recognised; expected $MODULES" 2

HOST_INDEX="$MODULES/dsh-desktop-host/lib/index.js"
GATEWAY_INDEX="$MODULES/dsh-api-gateway/lib/index.js"

[ -f "$HOST_INDEX" ]    || die "missing $HOST_INDEX"    2
[ -f "$GATEWAY_INDEX" ] || die "missing $GATEWAY_INDEX" 2

# ------------------------------------------------------------- apply patches

# Patches are unified diffs against lib/index.js with -p1 style labels
# (a/lib/index.js, b/lib/index.js), so each is applied from the package that
# owns that file.

info "patch 01: DSH_PORT port fallback"
if patch -p1 -N --dry-run -d "$MODULES/dsh-desktop-host" < "$PATCH_DIR/01-port-fallback.patch" >/dev/null 2>&1; then
    patch -p1 -d "$MODULES/dsh-desktop-host" < "$PATCH_DIR/01-port-fallback.patch"
elif patch -p1 -R --dry-run -d "$MODULES/dsh-desktop-host" < "$PATCH_DIR/01-port-fallback.patch" >/dev/null 2>&1; then
    info "patch 01 already applied; skipping"
else
    die "patch 01 does not apply and is not already applied" 3
fi

info "patch 02: disable WebSocket Ping control frame"
if patch -p1 -N --dry-run -d "$MODULES/dsh-api-gateway" < "$PATCH_DIR/02-disable-ws-ping.patch" >/dev/null 2>&1; then
    patch -p1 -d "$MODULES/dsh-api-gateway" < "$PATCH_DIR/02-disable-ws-ping.patch"
elif patch -p1 -R --dry-run -d "$MODULES/dsh-api-gateway" < "$PATCH_DIR/02-disable-ws-ping.patch" >/dev/null 2>&1; then
    info "patch 02 already applied; skipping"
else
    die "patch 02 does not apply and is not already applied" 3
fi

# ------------------------------------------------------- verify patch results

info "verifying patched sources"

grep -q 'process.env.DSH_PORT' "$HOST_INDEX" \
    || die "patch 01 verification failed: DSH_PORT not present" 3

grep -q 'websocketPingEnabled' "$GATEWAY_INDEX" \
    || die "patch 02 verification failed: websocketPingEnabled not present" 3

# The default must be false, otherwise the Ping frame is still sent.
grep -q 'websocketPingEnabled: z.boolean().default(false)' "$GATEWAY_INDEX" \
    || die "patch 02 verification failed: websocketPingEnabled is not defaulting to false" 3

info "patch 01 ok"
info "patch 02 ok"

# ------------------------------------------------------------------- addon

if [ "$BUILD_ADDON" -eq 1 ]; then
    info "patch 03: rebuilding native addon"
    if ! "$SCRIPT_DIR/build-addon.sh" "$RUNTIME"; then
        die "addon rebuild failed" 4
    fi
else
    info "patch 03 skipped (--no-addon)"
fi

info "assemble complete"
