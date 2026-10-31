#!/usr/bin/env bash
# build-addon.sh — rebuild the missing @deepseek-ai/node-addon-system-linux-arm64
#
# See ../patches/03-native-addon-build.md for the full rationale.
#
# Usage:
#   ./build-addon.sh <runtime-dsh-root>
#
# Where <runtime-dsh-root> is the directory that contains node_modules/, i.e.:
#   <extracted-payload>/opt/deepseek-harness/runtime/dsh
#
# Exit codes:
#   0  addon built and verified
#   1  bad usage
#   2  required source or headers missing
#   3  compiler failed
#   4  verification failed

set -euo pipefail

die() {
    printf 'error: %s\n' "$1" >&2
    exit "${2:-1}"
}

info() {
    printf '[build-addon] %s\n' "$1"
}

# ---------------------------------------------------------------- arguments

if [ $# -ne 1 ]; then
    cat >&2 <<'USAGE'
Usage: build-addon.sh <runtime-dsh-root>

Example:
  ./build-addon.sh /tmp/stage/opt/deepseek-harness/runtime/dsh
USAGE
    exit 1
fi

DASH_ROOT=${1%/}

[ -d "$DASH_ROOT" ] || die "not a directory: $DASH_ROOT" 1

NM="$DASH_ROOT/node_modules"
ADDON="$NM/@deepseek-ai/node-addon-system"
OUT="$NM/@deepseek-ai/node-addon-system-linux-arm64"

# ------------------------------------------------------------- preconditions

[ -d "$ADDON" ] \
    || die "addon source package not found: $ADDON" 2

[ -f "$ADDON/src/flock.c" ] \
    || die "flock.c missing: $ADDON/src/flock.c (payload differs from the one this script targets)" 2

# N-API headers ship inside the payload via koffi. Try the nested copy first
# (that is the one actually resolved at runtime), then the hoisted copy.
INCLUDE=""
for candidate in \
    "$NM/@deepseek-ai/dsh-desktop-host/node_modules/koffi/vendor/node-api-headers/include" \
    "$NM/koffi/vendor/node-api-headers/include"
do
    if [ -f "$candidate/node_api.h" ]; then
        INCLUDE="$candidate"
        break
    fi
done

[ -n "$INCLUDE" ] || die "node_api.h not found; looked in koffi vendor dirs under $NM" 2

command -v gcc >/dev/null 2>&1 || die "gcc not found in PATH" 3

# ------------------------------------------------------------------- build

info "source : $ADDON/src/flock.c"
info "headers: $INCLUDE"
info "output : $OUT/bin/{glibc,musl}/system.node"

mkdir -p "$OUT/bin/glibc" "$OUT/bin/musl"

# NAPI_VERSION is pinned so the vendored header set does not need to agree
# with the runtime's default N-API level.
info "compiling..."
if ! gcc -O2 -fPIC -shared \
        -DNAPI_VERSION=8 \
        -I"$INCLUDE" \
        -o "$OUT/bin/glibc/system.node" \
        "$ADDON/src/flock.c"
then
    die "gcc failed" 3
fi

chmod 0755 "$OUT/bin/glibc/system.node"
cp -f "$OUT/bin/glibc/system.node" "$OUT/bin/musl/system.node"
chmod 0644 "$OUT/bin/musl/system.node"

# --------------------------------------------------------------- manifest

# The runtime resolves '<pkg>/package.json' before it requires the binary,
# so this file must exist and must not hide package.json behind exports.
cat > "$OUT/package.json" <<'JSON'
{
  "name": "@deepseek-ai/node-addon-system-linux-arm64",
  "version": "0.1.2",
  "license": "BSD-3-Clause",
  "os": [
    "linux"
  ],
  "cpu": [
    "arm64"
  ],
  "files": [
    "bin"
  ]
}
JSON

# ---------------------------------------------------------- verification

info "verifying..."

[ -f "$OUT/bin/glibc/system.node" ] || die "glibc object not produced" 4
[ -f "$OUT/bin/musl/system.node" ]  || die "musl object not produced"  4

# A .node file must be an ELF shared object. Reject anything else early,
# because dlopen failures are reported late and are hard to trace.
if command -v readelf >/dev/null 2>&1; then
    readelf -h "$OUT/bin/glibc/system.node" >/dev/null 2>&1 \
        || die "glibc object is not a valid ELF file" 4
fi

info "md5:"
md5sum "$OUT/bin/glibc/system.node" "$OUT/bin/musl/system.node" | sed 's/^/  /'

if command -v node >/dev/null 2>&1; then
    info "load test..."
    if node -e "
        const { createRequire } = require('module');
        const req = createRequire('$DASH_ROOT/');
        const mod = req('@deepseek-ai/node-addon-system');
        if (typeof mod.flock !== 'function') {
            console.error('flock export is not a function');
            process.exit(4);
        }
        console.log('flock export type: ' + typeof mod.flock);
    "; then
        info "load test passed"
    else
        die "load test failed" 4
    fi
else
    info "node not in PATH; skipping load test (ELF check already passed)"
fi

info "done"
