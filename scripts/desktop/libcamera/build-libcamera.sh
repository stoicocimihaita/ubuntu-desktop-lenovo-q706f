#!/bin/bash
# Rebuild Ubuntu's libcamera source package (arm64) with the q706f patches.
#
# Runs in an arm64 Ubuntu 26.04 container on the x86_64 host (qemu-aarch64 binfmt,
# docker without sudo). The whole source package is rebuilt so that libcamera.so and
# the IPA modules carry the same build-time signing key (otherwise libcamera runs the
# IPA modules isolated).
#
# Output: out/desktop/libcamera/debs/*.deb  (version ${UBUNTU_VER}+q706fN)
# Usage:  scripts/desktop/libcamera/build-libcamera.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/scripts/desktop/libcamera"
OUT="$ROOT/out/desktop/libcamera"
UBUNTU_VER="${UBUNTU_VER:-0.7.0-1ubuntu2}"
LOCAL_SUFFIX="${LOCAL_SUFFIX:-+q706f1}"
IMAGE_BASE="ubuntu:26.04"
IMAGE="q706f-libcamera-build:26.04-arm64"
JOBS="${JOBS:-$(nproc)}"

command -v docker >/dev/null || { echo "docker missing" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "qemu-aarch64 binfmt missing" >&2; exit 1; }

mkdir -p "$OUT/src" "$OUT/build" "$OUT/debs"

# 1. Build-dependency image (cached; delete it with `docker rmi $IMAGE` to refresh).
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "== creating $IMAGE (build-deps, slow under qemu)"
  docker rm -f q706f-libcamera-prep >/dev/null 2>&1 || true
  docker run --platform linux/arm64 --name q706f-libcamera-prep "$IMAGE_BASE" bash -euc '
    export DEBIAN_FRONTEND=noninteractive
    sed -i "s/^Types: deb$/Types: deb deb-src/" /etc/apt/sources.list.d/ubuntu.sources
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends build-essential devscripts dpkg-dev \
      equivs fakeroot quilt ca-certificates >/dev/null
    apt-get build-dep -y -qq --arch-only -P nocheck,nodoc libcamera >/dev/null
    apt-get clean'
  docker commit q706f-libcamera-prep "$IMAGE" >/dev/null
  docker rm q706f-libcamera-prep >/dev/null
fi

# 2. Exact Ubuntu source (kept in out/desktop/libcamera/src; downloaded files are data).
if [ ! -f "$OUT/src/libcamera_${UBUNTU_VER}.dsc" ]; then
  docker run --rm --platform linux/arm64 -v "$OUT/src:/src" -w /src "$IMAGE" bash -euc "
    apt-get update -qq && apt-get source --download-only libcamera=$UBUNTU_VER"
fi

# 3. Unpack, add our patches as quilt patches, bump the version, build arch-only debs.
rm -rf "$OUT/build" && mkdir -p "$OUT/build"
docker run --rm --platform linux/arm64 \
  -v "$OUT/src:/src:ro" -v "$OUT/build:/build" -v "$HERE:/q706f:ro" \
  -e UBUNTU_VER="$UBUNTU_VER" -e LOCAL_SUFFIX="$LOCAL_SUFFIX" -e JOBS="$JOBS" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -w /build "$IMAGE" bash -euc '
    dpkg-source -x "/src/libcamera_${UBUNTU_VER}.dsc" libcamera
    cd libcamera
    for p in /q706f/[0-9][0-9][0-9][0-9]-*.patch; do
      cp "$p" debian/patches/
      echo "$(basename "$p")" >> debian/patches/series
    done
    QUILT_PATCHES=debian/patches quilt push -a --fuzz=0
    QUILT_PATCHES=debian/patches quilt pop -a
    DEBFULLNAME="q706f port" DEBEMAIL="q706f@localhost" \
      dch --newversion "${UBUNTU_VER}${LOCAL_SUFFIX}" --distribution resolute \
      "Add CameraSensorHelper entries for ov13b10, ov8856 and s5k5e9 (Lenovo Tab P12 Pro)."
    export DEB_BUILD_OPTIONS="nocheck nodoc parallel=${JOBS}"
    export DEB_BUILD_PROFILES="nocheck nodoc"
    dpkg-buildpackage -B -uc -us 2>&1 | tail -n 40
    chown -R "$HOST_UID:$HOST_GID" /build'

rm -f "$OUT/debs/"*.deb
cp "$OUT/build/"*.deb "$OUT/debs/"
( cd "$OUT/debs" && sha256sum *.deb > SHA256SUMS && ls -l )
