#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# debian/build.sh [OUT]: build the Debian package of the committed HEAD in a
# throwaway debian:forky container for this machine's architecture, into OUT
# (default ../libva-v4l2-request-deb). The arm64 package comes from GitHub
# Actions, which runs this on an arm64 machine; ARCH=arm64 on another machine
# emulates arm64 with qemu-user, which is slow. Uncommitted changes are not
# part of the build.
#
# The version is <meson project version>+git<commit date UTC,
# YYYYMMDD.HHMMSS>.g<commit>, so every later commit builds a higher version.
# The container fetches only the Debian build dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH=${ARCH:-$(case $(uname -m) in aarch64) echo arm64 ;; x86_64) echo amd64 ;; *) uname -m ;; esac)}
SUITE=${SUITE:-forky}
OUT=$(mkdir -p "${1:-../libva-v4l2-request-deb}" && cd "${1:-../libva-v4l2-request-deb}" && pwd)
SRC=libva-v4l2-request
PKG=v4l2-request-va-driver
fail() { echo "build.sh: $*" >&2; exit 1; }

[ -z "$(git status --porcelain --untracked-files=no)" ] \
	|| echo "build.sh: uncommitted changes are left out, building HEAD" >&2
up=$(sed -n "s/^ *version: '\([^']*\)',\$/\1/p" meson.build | head -1)
[ -n "$up" ] || fail "no project version in meson.build"
stamp=$(TZ=UTC git log -1 --date=format-local:%Y%m%d.%H%M%S --format=%cd HEAD)
rev=$(git rev-parse --short=7 HEAD)
V=$up+git$stamp.g$rev
echo "$SRC $V for $ARCH"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
S=$W/$SRC-$V
mkdir -p "$S"
git archive HEAD | tar -x -C "$S"

# This build's changelog entry, dated by the commit
branch=$(git rev-parse --abbrev-ref HEAD)
{
	printf '%s (%s) %s; urgency=medium\n\n' "$SRC" "$V" "$SUITE"
	printf '  * Build of %s at %s.\n\n' "$branch" "$(git rev-parse HEAD)"
	printf ' -- %s  %s\n\n' "$(sed -n 's/^Maintainer: //p' debian/control)" "$(git log -1 --format=%cD HEAD)"
	cat debian/changelog
} > "$S/debian/changelog"

docker run --rm --platform "linux/$ARCH" -e SRC="$SRC" -e V="$V" -e HUID="$(id -u)" -e HGID="$(id -g)" \
	-v "$W:/b" -v "$OUT:/out" "debian:$SUITE" sh -c '
set -eu
trap "chown -R \$HUID:\$HGID /out /b" EXIT
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8
apt-get update -qq > /tmp/apt.log 2>&1 || { tail -20 /tmp/apt.log; exit 1; }
apt-get install -y -qq --no-install-recommends build-essential dpkg-dev fakeroot ca-certificates xz-utils >> /tmp/apt.log 2>&1 \
	|| { tail -20 /tmp/apt.log; exit 1; }
cd /b/$SRC-$V
apt-get build-dep -y --arch-only --no-install-recommends ./ >> /tmp/apt.log 2>&1 || { tail -40 /tmp/apt.log; exit 1; }
export DEB_BUILD_OPTIONS="nocheck noautodbgsym parallel=$(nproc)"
dpkg-buildpackage --build=source,any -us -uc > /b/build.log 2>&1 || { tail -80 /b/build.log; exit 1; }
cd /b
cp ${SRC}_$V.dsc ${SRC}_$V.tar.* ${SRC}_$V*.buildinfo *_${V}_*.deb /out/
cp build.log /out/${SRC}_${V}_build.log'

# The driver and the names libva looks up on Mali GPUs, all in the multiarch driver directory
cd "$OUT"
deb=${PKG}_${V}_$ARCH.deb
[ -f "$deb" ] || fail "no $deb"
dpkg-deb -x "$deb" "$W/deb"
set -- "$W"/deb/usr/lib/*/dri/v4l2_request_drv_video.so
[ $# = 1 ] && [ -f "$1" ] && [ ! -L "$1" ] || fail "$deb: no usr/lib/<multiarch>/dri/v4l2_request_drv_video.so"
dri=${1%/*}
for l in panfrost panthor; do
	[ "$(readlink "$dri/${l}_drv_video.so")" = v4l2_request_drv_video.so ] \
		|| fail "$deb: ${l}_drv_video.so is not a link to v4l2_request_drv_video.so"
done
grep -a -q '__vaDriverInit_' "$dri/v4l2_request_drv_video.so" || fail "$deb: no libva driver entry point"
sha256sum -- *_"$V"* > SHA256SUMS."$V"
cp SHA256SUMS."$V" SHA256SUMS
echo "version=$V" > VERSION
cat SHA256SUMS
