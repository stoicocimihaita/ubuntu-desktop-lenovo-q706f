#!/bin/bash
# Build upstream libcamera (git, pinned commit) for the tablet, installed under
# /usr/local so that it does not touch the held Ubuntu 0.7 packages.
#
# - Source: git clone into out/desktop/libcamera-upstream/src (downloaded code is data;
#   nothing from it runs on the host, the build runs in the arm64 container).
# - Build: arm64 Ubuntu 26.04 container (qemu binfmt), image q706f-libcamera-build:26.04-arm64
#   created by build-libcamera.sh (it has libcamera's build-deps incl. EGL/GLES headers).
# - Local change: add-sensor-helpers.py inserts the ov13b10/ov8856/s5k5e9 CameraSensorHelper
#   entries (with exposure margins when upstream supports them).
# - Output: out/desktop/libcamera-upstream/libcamera-<rev>-arm64-usrlocal.tar.gz + SHA256SUMS.
#   The tarball contains only /usr/local/... ; `cam` is renamed to `cam-upstream` so that
#   /usr/bin/cam (0.7) keeps working.
#
# Usage: REV=<commit or tag> scripts/desktop/libcamera/build-libcamera-upstream.sh
#   REV is mandatory (no floating master). It must contain the AGC frame-duration series
#   ("libcamera: pipeline: Set vblank on more platforms", accepted 2026-11-11).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/scripts/desktop/libcamera"
OUT="$ROOT/out/desktop/libcamera-upstream"
REPO="${REPO:-https://gitlab.freedesktop.org/camera/libcamera.git}"
REV="${REV:?set REV=<commit>}"
IMAGE="q706f-libcamera-build:26.04-arm64"
JOBS="${JOBS:-$(nproc)}"

command -v docker >/dev/null || { echo "docker missing" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "qemu-aarch64 binfmt missing" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "$IMAGE missing: run build-libcamera.sh once (it creates the build-deps image)" >&2; exit 1; }

mkdir -p "$OUT"
if [ ! -d "$OUT/src/.git" ]; then
  git clone --no-checkout "$REPO" "$OUT/src"
fi
git -C "$OUT/src" fetch --tags origin
git -C "$OUT/src" checkout -q --detach "$REV"
git -C "$OUT/src" reset -q --hard
git -C "$OUT/src" clean -qfdx
SHORT=$(git -C "$OUT/src" rev-parse --short=12 HEAD)
echo "== libcamera $(git -C "$OUT/src" describe --tags --always) ($SHORT)"

if ! git -C "$OUT/src" log --oneline -F --grep="Set vblank on more platforms" | grep -q .; then
  echo "!! $REV does not contain the VBLANK series (patchwork 28841); refusing" >&2
  exit 1
fi

# Local sensor helpers (prints the resulting diff for review).
python3 -I "$HERE/upstream/add-sensor-helpers.py" "$OUT/src/src/ipa/libipa/camera_sensor_helper.cpp"
git -C "$OUT/src" --no-pager diff --stat

# Which name the SoftISP IPA has in this tree (0.7: "simple"; renamed upstream later).
IPA=$(grep -oE "'(simple|softisp|soft)'" "$OUT/src/meson_options.txt" | head -1 | tr -d "'")
[ -n "$IPA" ] || { echo "cannot find the SoftISP IPA name in meson_options.txt" >&2; exit 1; }
echo "== SoftISP IPA name: $IPA"

rm -rf "$OUT/build" "$OUT/stage"
docker run --rm --platform linux/arm64 \
  -v "$OUT/src:/src" -v "$OUT:/out" -e IPA="$IPA" -e JOBS="$JOBS" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -w /src "$IMAGE" bash -euc '
    meson setup /out/build \
      --prefix=/usr/local --libdir=lib/aarch64-linux-gnu --buildtype=release \
      -Dpipelines=simple -Dipas="$IPA" \
      -Dcam=enabled -Dgstreamer=enabled -Dv4l2=disabled -Dqcam=disabled \
      -Dpycamera=disabled -Dlc-compliance=disabled -Ddocumentation=disabled \
      -Dtest=false -Dtracing=disabled -Dandroid=disabled 2>&1 | tail -n 40
    grep -E "HAVE_DEBAYER_EGL|IPA_CONFIG_DIR" /out/build/config.h
    ninja -C /out/build -j "$JOBS" 2>&1 | tail -n 15
    DESTDIR=/out/stage meson install -C /out/build --no-rebuild >/dev/null
    chown -R "$HOST_UID:$HOST_GID" /out/build /out/stage'

grep -q "HAVE_DEBAYER_EGL 1" "$OUT/build/config.h" || { echo "!! built without GPU debayer" >&2; exit 1; }
mv "$OUT/stage/usr/local/bin/cam" "$OUT/stage/usr/local/bin/cam-upstream"
TAR="$OUT/libcamera-$SHORT-arm64-usrlocal.tar.gz"
tar -C "$OUT/stage" --owner=0 --group=0 -czf "$TAR" usr/local
( cd "$OUT" && sha256sum "$(basename "$TAR")" > SHA256SUMS && cat SHA256SUMS )
tar -tzf "$TAR" | grep -E "\.so\.[0-9]|ipa_.*\.so$|bin/|share/libcamera/ipa/" | sed 's/^/  /'
