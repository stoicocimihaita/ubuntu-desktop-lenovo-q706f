#!/usr/bin/env bash
# Build the q706f kernel: upstream Linux stable + scripts/desktop/patches/*.patch.
# Usage: scripts/desktop/build-kernel.sh
# Source: the kernel.org tarball (sha256 pinned) extracted to sources/linux-desktop and
#         patched in file-name order with zero fuzz. The tree is recreated whenever the
#         version or any patch changes. *.needs-approval files are not applied.
# Output: out/desktop/kernel/{Image.gz,sm8250-lenovo-q706f.dtb,modules/,config}
# Writes nothing to the tablet.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VER=7.3.4
TARBALL="linux-$VER.tar.xz"
# As listed in kernel.org's v7.x/sha256sums.asc.
TARBALL_SHA256=b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f
TARBALL_URL="https://cdn.kernel.org/pub/linux/kernel/v7.x/$TARBALL"
DL="$ROOT/out/desktop/dl"
SRC="$ROOT/sources/linux-desktop"
OUT="$ROOT/out/desktop/kernel"
PATCHES="$ROOT/scripts/desktop/patches"

stamp="$VER $(cat "$PATCHES"/*.patch | sha256sum | cut -c1-16)"
if [ "$(cat "$SRC/.rev" 2>/dev/null)" != "$stamp" ]; then
  mkdir -p "$DL"
  if [ ! -f "$DL/$TARBALL" ]; then
    # Download to .part and keep it only when the checksum matches (no truncated tarball left behind).
    curl -fL -o "$DL/$TARBALL.part" "$TARBALL_URL"
    echo "$TARBALL_SHA256  $DL/$TARBALL.part" | sha256sum -c - >/dev/null \
      || { rm -f "$DL/$TARBALL.part"; echo "sha256 mismatch for $TARBALL" >&2; exit 1; }
    mv "$DL/$TARBALL.part" "$DL/$TARBALL"
  fi
  echo "$TARBALL_SHA256  $DL/$TARBALL" | sha256sum -c - >/dev/null \
    || { echo "sha256 mismatch for $DL/$TARBALL: delete it to download again" >&2; exit 1; }
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -C "$SRC" --strip-components=1 -xf "$DL/$TARBALL"
  for p in "$PATCHES"/*.patch; do
    # -F0: the series is exact for this version; any context mismatch is an error.
    patch -d "$SRC" -p1 -s -N -F0 --no-backup-if-mismatch < "$p" \
      || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
  done
  if find "$SRC" \( -name '*.rej' -o -name '*.orig' \) | grep -q .; then
    echo "patch FAILED: rejects left in $SRC" >&2; exit 1
  fi
  echo "$stamp" > "$SRC/.rev"
fi
mkdir -p "$OUT/build"

"$ROOT/scripts/dev-shell.sh" bash -euc '
  cd /work/sources/linux-desktop
  D=/work/scripts/desktop
  B=/work/out/desktop/kernel/build
  # LOCALVERSION= (set, empty): never append "+", the release is exactly the version.
  M="make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= O=$B"
  cp $D/config-pmos-q706f-6.11 $B/.config
  $M olddefconfig >/dev/null
  scripts/kconfig/merge_config.sh -m -O $B $B/.config \
    $D/q706f-desktop.config $D/q706f-7.3-renames.config $D/q706f-7.3.4-extra.config >/dev/null
  $M olddefconfig >/dev/null
  # Every option the fragments ask for must survive olddefconfig (a missing dependency drops it silently).
  miss=$(cat $D/q706f-desktop.config $D/q706f-7.3-renames.config $D/q706f-7.3.4-extra.config |
    grep -oE "^CONFIG_[A-Z0-9_]+=[ym]" | cut -d= -f1 | while read -r k; do
      grep -qE "^$k=[ym]" $B/.config || echo "$k"; done)
  [ -z "$miss" ] || { echo "config options dropped by olddefconfig (missing dependency?):" $miss >&2; exit 1; }
  rm -f $B/arch/arm64/boot/Image.gz
  # No pipe here: a compile error must stop the script.
  $M Image.gz dtbs modules > $B/build.log 2>&1 || { grep -E "error|undefined" $B/build.log | head -20; exit 1; }
  test -f $B/arch/arm64/boot/Image.gz
  cp $B/arch/arm64/boot/Image.gz /work/out/desktop/kernel/
  cp $B/arch/arm64/boot/dts/qcom/sm8250-lenovo-q706f.dtb /work/out/desktop/kernel/
  cp $B/.config /work/out/desktop/kernel/config
  rm -rf /work/out/desktop/kernel/modules
  $M INSTALL_MOD_PATH=/work/out/desktop/kernel/modules INSTALL_MOD_STRIP=1 modules_install >/dev/null
  echo "warnings in build.log: $(grep -c "warning:" $B/build.log || true)"
'
echo "kernel $(cat "$OUT/build/include/config/kernel.release") (upstream v$VER + $(ls "$PATCHES"/*.patch | wc -l) patches)"
ls -la "$OUT"/Image.gz "$OUT"/sm8250-lenovo-q706f.dtb
