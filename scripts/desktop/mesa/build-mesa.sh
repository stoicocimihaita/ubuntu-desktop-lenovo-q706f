#!/bin/bash
# Build Mesa (Adreno only: freedreno Gallium + turnip Vulkan, msm KMD, no LLVM) for the
# tablet's Ubuntu 26.04 arm64 userspace, installed as a self-contained tree under
# /opt/mesa-<ver>, to be used side by side with the system Mesa (per application, via env).
#
# - Source: archive.mesa3d.org tarball into out/desktop/dl/mesa/ (data), sha256 checked
#   against the value pinned below (taken from docs.mesa3d.org/relnotes/<ver>.html).
# - Build: arm64 Ubuntu 26.04 container (qemu binfmt), image q706f-mesa-build:26.04-arm64
#   built from the Dockerfile next to this script (base: q706f-libcamera-build:26.04-arm64).
# - Output: out/desktop/mesa/mesa-<ver>-adreno-arm64-opt.tar.gz (only opt/mesa-<ver>/...)
#   + SHA256SUMS; README-use.txt (env snippet) next to it and inside the tarball.
#
# Usage: scripts/desktop/mesa/build-mesa.sh      (JOBS=<n> to limit parallelism)
set -euo pipefail

VER="${VER:-26.3.1}"
SHA256="${SHA256:-4e4e438eac7b840a9383988cbb7c08dad8041da544b9319fc26d319fa7348961}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HERE="$ROOT/scripts/desktop/mesa"
DL="$ROOT/out/desktop/dl/mesa"
OUT="$ROOT/out/desktop/mesa"
PREFIX="/opt/mesa-$VER"
IMAGE="q706f-mesa-build:26.04-arm64"
JOBS="${JOBS:-$(nproc)}"
TARBALL="mesa-$VER.tar.xz"

command -v docker >/dev/null || { echo "docker missing" >&2; exit 1; }
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || { echo "qemu-aarch64 binfmt missing" >&2; exit 1; }

# 1. Build image (cached by docker).
docker build -q --platform linux/arm64 -t "$IMAGE" "$HERE" >/dev/null

# 2. Source.
mkdir -p "$DL" "$OUT"
[ -f "$DL/$TARBALL" ] || curl -sSfL -o "$DL/$TARBALL" "https://archive.mesa3d.org/$TARBALL"
echo "$SHA256  $DL/$TARBALL" | sha256sum -c --quiet || { echo "!! sha256 mismatch" >&2; exit 1; }
echo "== mesa $VER sha256 $SHA256 OK"
# Previous runs may leave root-owned files (container); clean up from inside the container.
docker run --rm --platform linux/arm64 -v "$OUT:/out" "$IMAGE" rm -rf /out/src /out/build /out/stage /out/ninja.log
mkdir -p "$OUT/src"
tar -C "$OUT/src" -xf "$DL/$TARBALL"
SRC="$OUT/src/mesa-$VER"

# Meson wraps: only wayland-protocols is needed (Ubuntu 26.04 has 1.47, Mesa wants >= 1.49;
# build-time XML/headers only). Fetch it here, verify the hash pinned in Mesa's .wrap and
# build with --wrap-mode=nodownload, so the optional freedreno-tools deps (libarchive,
# libxml2) are not pulled from the network.
for w in wayland-protocols; do
  f=$(sed -n 's/^source_filename *= *//p' "$SRC/subprojects/$w.wrap")
  u=$(sed -n 's/^source_url *= *//p' "$SRC/subprojects/$w.wrap")
  h=$(sed -n 's/^source_hash *= *//p' "$SRC/subprojects/$w.wrap")
  [ -f "$DL/$f" ] || curl -sSfL -o "$DL/$f" "$u"
  echo "$h  $DL/$f" | sha256sum -c --quiet || { echo "!! sha256 mismatch: $f" >&2; exit 1; }
  mkdir -p "$SRC/subprojects/packagecache"
  cp "$DL/$f" "$SRC/subprojects/packagecache/"
  echo "== wrap $f sha256 $h OK"
done
# Pre-extract wayland-protocols and drop '--strict' from its enum-header generation: the
# 26.04 wayland-scanner (1.24) fails DTD validation on two 1.49 staging XMLs. Mesa does not
# use those enum headers; subprojects are not installed (--skip-subprojects).
WPDIR=$(sed -n 's/^directory *= *//p' "$SRC/subprojects/wayland-protocols.wrap")
tar -C "$SRC/subprojects" -xf "$DL/$WPDIR.tar.xz"
sed -i "/'--strict',/d" "$SRC/subprojects/$WPDIR/include/wayland-protocols/meson.build"

# 3. Configure, build, install into the staging dir.
MESON_OPTS=(
  --wrap-mode=nodownload
  --prefix="$PREFIX" --libdir=lib/aarch64-linux-gnu --buildtype=release
  -Dgallium-drivers=freedreno -Dvulkan-drivers=freedreno -Dfreedreno-kmds=msm
  -Dplatforms=wayland,x11 -Dglx=dri -Degl=enabled -Dgbm=enabled -Dglvnd=enabled
  -Dgles1=enabled -Dgles2=enabled -Dopengl=true
  -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled
  -Dgallium-va=disabled -Dgallium-rusticl=false -Dteflon=false
  -Dvulkan-layers=[] -Dtools=[] -Dvideo-codecs=[] -Dbuild-tests=false
)
printf '%s\n' "${MESON_OPTS[@]}" > "$OUT/meson-options.txt"
docker run --rm --platform linux/arm64 \
  -v "$OUT:/out" -e JOBS="$JOBS" -e VER="$VER" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" "$IMAGE" bash -euc '
    mapfile -t OPTS < /out/meson-options.txt
    set -o pipefail
    trap "chown -R \$HOST_UID:\$HOST_GID /out/src /out/build /out/stage /out/ninja.log 2>/dev/null || true" EXIT
    meson setup /out/build "/out/src/mesa-$VER" "${OPTS[@]}" 2>&1 | tail -n 60
    ninja -C /out/build -j "$JOBS" > /out/ninja.log 2>&1 || {
      grep -E -A20 "^FAILED" /out/ninja.log | head -n 80; exit 1; }
    tail -n 3 /out/ninja.log
    DESTDIR=/out/stage meson install -C /out/build --no-rebuild --skip-subprojects >/dev/null'

S="$OUT/stage$PREFIX"
# Turnip ICD: make library_path absolute (it should already be; enforce it).
for j in "$S"/share/vulkan/icd.d/*.json; do
  sed -i -E "s#\"library_path\": *\"[^\"]*/?(libvulkan_freedreno\.so)\"#\"library_path\": \"$PREFIX/lib/aarch64-linux-gnu/\1\"#" "$j"
  grep -q "\"library_path\": \"$PREFIX/" "$j" || { echo "!! ICD path not absolute: $j" >&2; exit 1; }
done
# glvnd vendor json: absolute library path, so it works even without LD_LIBRARY_PATH.
for j in "$S"/share/glvnd/egl_vendor.d/*.json; do
  sed -i -E "s#\"library_path\" *: *\"(libEGL_mesa\.so\.0)\"#\"library_path\" : \"$PREFIX/lib/aarch64-linux-gnu/\1\"#" "$j"
done

# Copies of the EGL/Vulkan manifests inside the library dir: WebKit's bubblewrap sandbox binds the
# LD_LIBRARY_PATH entries but not $PREFIX/share, so the wrapper points glvnd/the Vulkan loader here.
mkdir -p "$S/lib/aarch64-linux-gnu/manifests"
cp "$S"/share/glvnd/egl_vendor.d/*.json "$S"/share/vulkan/icd.d/*.json "$S/lib/aarch64-linux-gnu/manifests/"

# 4. README + tarball.
sed "s#@PREFIX@#$PREFIX#g; s#@VER@#$VER#g" "$HERE/README-use.txt.in" > "$OUT/README-use.txt"
cp "$OUT/README-use.txt" "$S/README-use.txt"
TAR="$OUT/mesa-$VER-adreno-arm64-opt.tar.gz"
tar -C "$OUT/stage" --owner=0 --group=0 -czf "$TAR" "${PREFIX#/}"
( cd "$OUT" && sha256sum "$(basename "$TAR")" > SHA256SUMS && cat SHA256SUMS )
tar -tvzf "$TAR" | awk '{print $6 ($7 ? " " $7 " " $8 : "")}' | grep -vE '/$|include/' | sed 's/^/  /'
