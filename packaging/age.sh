#!/usr/bin/env bash
# package.sh — turn an assembled stage tree into a .deb
#
# Usage:
#   ./package.sh <stage-dir> [output-dir]
#
# <stage-dir> must be a fully assembled root filesystem (the result of
# assemble.sh), containing at least:
#   DEBIAN/control
#   opt/deepseek-harness/...
#
# [output-dir] defaults to ./out
#
# The script regenerates DEBIAN/md5sums from the actual tree, so the checksums
# always describe the bytes being packaged. DEBIAN/control is copied in from
# ../packaging/DEBIAN/control if the stage tree does not already have one.
#
# Exit codes:
#   0  .deb produced
#   1  bad usage
#   2  stage tree incomplete
#   3  dpkg-deb failed

set -euo pipefail

die() {
    printf 'error: %s\n' "$1" >&2
    exit "${2:-1}"
}

info() {
    printf '[package] %s\n' "$1"
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONTROL_SRC="$SCRIPT_DIR/../packaging/DEBIAN/control"

# ---------------------------------------------------------------- arguments

if [ $# -lt 1 ]; then
    cat >&2 <<'USAGE'
Usage: package.sh <stage-dir> [output-dir]

Example:
  ./package.sh /tmp/stage ./out
USAGE
    exit 1
fi

STAGE=${1%/}
OUTDIR=${2:-./out}

[ -d "$STAGE" ] || die "not a directory: $STAGE" 1

# ------------------------------------------------------------- sanity checks

[ -d "$STAGE/opt/deepseek-harness" ] \
    || die "stage tree does not contain opt/deepseek-harness" 2

[ -d "$STAGE/DEBIAN" ] || mkdir -p "$STAGE/DEBIAN"

if [ ! -f "$STAGE/DEBIAN/control" ]; then
    [ -f "$CONTROL_SRC" ] \
        || die "no DEBIAN/control in stage tree and no template at $CONTROL_SRC" 2
    cp -f "$CONTROL_SRC" "$STAGE/DEBIAN/control"
    info "control: copied from template"
else
    info "control: using existing file in stage tree"
fi

# Owner must be root:root for dpkg-deb to produce a clean archive.
if [ "$(id -u)" -eq 0 ]; then
    chown -R 0:0 "$STAGE"
else
    info "warning: not running as root; ownership in the .deb will follow the current user"
fi

# ---------------------------------------------------------------- md5sums

info "regenerating DEBIAN/md5sums"

# md5sums covers every regular file under the stage tree except the DEBIAN
# directory itself. Paths are relative to the package root and have no leading
# slash, matching what dpkg expects.
(
    cd "$STAGE"
    find . -path ./DEBIAN -prune -o -type f -print0 \
        | sort -z \
        | xargs -0 -r md5sum \
        > DEBIAN/md5sums
)

COUNT=$(wc -l < "$STAGE/DEBIAN/md5sums")
info "md5sums: $COUNT entries"

# The control file advertises Installed-Size in KB. Keep it honest rather than
# letting it drift away from the actual tree.
INSTALLED_KB=$(du -s --block-size=1024 "$STAGE" 2>/dev/null | cut -f1)
if [ -n "$INSTALLED_KB" ]; then
    info "installed size: ${INSTALLED_KB} KB"
    if grep -q '^Installed-Size:' "$STAGE/DEBIAN/control"; then
        CURRENT=$(grep '^Installed-Size:' "$STAGE/DEBIAN/control" | awk '{print $2}')
        if [ "$CURRENT" != "$INSTALLED_KB" ]; then
            info "control declares $CURRENT KB; updating to $INSTALLED_KB KB"
            sed -i "s/^Installed-Size:.*/Installed-Size: $INSTALLED_KB/" "$STAGE/DEBIAN/control"
        fi
    fi
fi

# ---------------------------------------------------------------- build deb

VERSION=$(grep '^Version:' "$STAGE/DEBIAN/control" | awk '{print $2}')
ARCH=$(grep '^Architecture:' "$STAGE/DEBIAN/control" | awk '{print $2}')
PKG=$(grep '^Package:' "$STAGE/DEBIAN/control" | awk '{print $2}')

[ -n "${VERSION:-}" ] || die "cannot read Version from control" 2
[ -n "${ARCH:-}" ]    || die "cannot read Architecture from control" 2
[ -n "${PKG:-}" ]     || die "cannot read Package from control" 2

mkdir -p "$OUTDIR"
DEB="$OUTDIR/${PKG}_${VERSION}_${ARCH}.deb"

info "building $DEB"

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb not found" 3

if ! dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB"; then
    die "dpkg-deb failed" 3
fi

# ---------------------------------------------------------------- report

info "result:"
ls -l "$DEB" | sed 's/^/  /'
if command -v md5sum >/dev/null 2>&1; then
    md5sum "$DEB" | sed 's/^/  md5    /'
fi
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$DEB" | sed 's/^/  sha256 /'
fi

info "done"