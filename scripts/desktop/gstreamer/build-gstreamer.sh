#!/bin/bash
# Build GStreamer (core, base, good, bad (minimal), libav) for arm64 as a self-contained
# tree under /opt/gstreamer-$VER, usable side by side with the system GStreamer (1.28.2)
# on the tablet (Ubuntu 26.04 arm64). Purpose: test newer V4L2 stateful decoders (Iris)
# and GL/dmabuf handling with WebKitGTK (GNOME Web) without touching the system.
#
# - Sources: release tarballs from gstreamer.freedesktop.org into out/desktop/dl/,
#   each verified against its published .sha256sum (downloads are data; only built
#   inside the arm64 container).
# - Build: arm64 container (qemu binfmt), image q706f-gst-build:26.04-arm64 (Dockerfile here).
# - Output: out/desktop/gstreamer/gstreamer-$VER-arm64-opt.tar.gz (+ .sha256), containing
#   only opt/gstreamer-$VER/... including README-use.txt.
#
# Usage: scripts/desktop/gstreamer/build-gstreamer.sh   (VER=1.28.9 JOBS=N optional)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/scripts/desktop/gstreamer"
OUT="$ROOT/out/desktop/gstreamer"
DL="$ROOT/out/desktop/dl"
VER="${VER:-1.28.9}"
PREFIX="/opt/gstreamer-$VER"
IMAGE="q706f-gst-build:26.04-arm64"
JOBS="${JOBS:-$(nproc)}"
MODULES="gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav"
BASEURL="https://gstreamer.freedesktop.org/src"

command -v docker >/dev/null || { echo "docker missing" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "qemu-aarch64 binfmt missing" >&2; exit 1; }

# 1. Download + verify.
mkdir -p "$DL" "$OUT"
for m in $MODULES; do
  f="$m-$VER.tar.xz"
  if [ ! -f "$DL/$f" ]; then
    curl -fsSL --proto '=https' -o "$DL/$f.part" "$BASEURL/$m/$f"
    mv "$DL/$f.part" "$DL/$f"
  fi
  [ -f "$DL/$f.sha256sum" ] || curl -fsL --proto '=https' -o "$DL/$f.sha256sum" "$BASEURL/$m/$f.sha256sum"
  want=$(awk '{print $1; exit}' "$DL/$f.sha256sum")
  have=$(sha256sum "$DL/$f" | awk '{print $1}')
  [ "$want" = "$have" ] || { echo "!! sha256 mismatch for $f: $have != $want" >&2; exit 1; }
  echo "== ok $have  $f"
done
( cd "$DL" && sha256sum $(for m in $MODULES; do echo "$m-$VER.tar.xz"; done) ) > "$OUT/SOURCES-$VER.sha256"

# 2. Unpack.
rm -rf "$OUT/src" "$OUT/build" "$OUT/stage"
mkdir -p "$OUT/src"
for m in $MODULES; do tar -C "$OUT/src" -xf "$DL/$m-$VER.tar.xz"; done

# 3. Build-deps image.
docker build --platform linux/arm64 -q -t "$IMAGE" "$HERE" >/dev/null
echo "== image $IMAGE ready"

# 4. Configure/build/install each module in order; later modules find earlier ones via
#    PKG_CONFIG_PATH pointing into $PREFIX.
#    The stage dir is bind-mounted at $PREFIX so that the build installs to the real prefix.
mkdir -p "$OUT/stage$PREFIX"
docker run --rm --platform linux/arm64 \
  -v "$OUT:/out" -v "$HERE:/scripts:ro" -v "$OUT/stage$PREFIX:$PREFIX" \
  -e VER="$VER" -e PREFIX="$PREFIX" -e JOBS="$JOBS" -e MODULES="$MODULES" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$IMAGE" bash /scripts/inner-build.sh

# 5. README + tarball.
install -m 0644 "$HERE/README-use.txt" "$OUT/stage$PREFIX/README-use.txt"
install -m 0644 "$HERE/README-use.txt" "$OUT/README-use.txt"
TAR="$OUT/gstreamer-$VER-arm64-opt.tar.gz"
tar -C "$OUT/stage" --owner=0 --group=0 -czf "$TAR" "${PREFIX#/}"
( cd "$OUT" && sha256sum "$(basename "$TAR")" > "$(basename "$TAR").sha256" )
cat "$TAR.sha256"
echo "== plugins (video-relevant):"
ls "$OUT/stage$PREFIX/lib/aarch64-linux-gnu/gstreamer-1.0/" | grep -E 'v4l2|video4linux2|opengl|libav|vpx|videoparsers|codecalpha|matroska|isomp4|playback|videoconvert|waylandsink' || true
