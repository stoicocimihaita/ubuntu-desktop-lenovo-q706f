#!/usr/bin/env bash
# Build the q706f kernel on Linux 7.4-rc3: torvalds tag tarball + scripts/desktop/patches-7.4/*.patch.
# Usage: scripts/desktop/build-kernel-7.4.sh
# Separate from the 7.3.4 flow (build-kernel.sh): own source tree, patch dir and output dir,
# so both can be built side by side.
# Source: the git.kernel.org tag tarball (sha256 pinned below) extracted to
#         sources/linux-desktop-7.4rc3 and patched in file-name order with zero fuzz. The tree
#         is recreated whenever the version or any patch changes. Only *.patch is applied.
# Output: out/desktop/kernel-7.4/{Image.gz,sm8250-lenovo-q706f.dtb,modules/,config}
#         + the out-of-tree modules from scripts/desktop/modules/*/ (built in a copy under
#         out/desktop/kernel-7.4/extmod/, so the source dirs stay clean), depmod done
#         + out/desktop/modules-7.4rc3-<date>.tgz (lib/modules/<release>/...).
# Writes nothing to the tablet.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VER=7.4-rc3
TARBALL="linux-$VER.tar.gz"
# git.kernel.org generates tag tarballs on demand; this is the sha256 of the copy fetched on
# 2026-11-22 (no signed checksum list exists for -rc tarballs).
TARBALL_SHA256=95c0eb4a051dd09983d6b7887bdd9d323559fccda163c627d398c0547b89f961
TARBALL_URL="https://git.kernel.org/torvalds/t/$TARBALL"
DL="$ROOT/out/desktop/dl"
SRC="$ROOT/sources/linux-desktop-7.4rc3"
OUT="$ROOT/out/desktop/kernel-7.4"
PATCHES="$ROOT/scripts/desktop/patches-7.4"
FRAGS="q706f-desktop.config q706f-7.3-renames.config q706f-7.3.4-extra.config q706f-7.4-renames.config"

stamp="$VER $(cat "$PATCHES"/*.patch | sha256sum | cut -c1-16)"
if [ "$(cat "$SRC/.rev" 2>/dev/null)" != "$stamp" ]; then
  mkdir -p "$DL"
  if [ ! -f "$DL/$TARBALL" ]; then
    curl -fL -o "$DL/$TARBALL.part" "$TARBALL_URL"
    echo "$TARBALL_SHA256  $DL/$TARBALL.part" | sha256sum -c - >/dev/null \
      || { rm -f "$DL/$TARBALL.part"; echo "sha256 mismatch for $TARBALL" >&2; exit 1; }
    mv "$DL/$TARBALL.part" "$DL/$TARBALL"
  fi
  echo "$TARBALL_SHA256  $DL/$TARBALL" | sha256sum -c - >/dev/null \
    || { echo "sha256 mismatch for $DL/$TARBALL: delete it to download again" >&2; exit 1; }
  rm -rf "$SRC"; mkdir -p "$SRC"
  tar -C "$SRC" --strip-components=1 -xzf "$DL/$TARBALL"
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
  cd /work/sources/linux-desktop-7.4rc3
  D=/work/scripts/desktop
  O=/work/out/desktop/kernel-7.4
  B=$O/build
  FRAGS="'"$FRAGS"'"
  # LOCALVERSION= (set, empty): never append "+", the release is exactly the version.
  M="make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= O=$B"
  cp $D/config-pmos-q706f-6.11 $B/.config
  $M olddefconfig >/dev/null
  scripts/kconfig/merge_config.sh -m -O $B $B/.config $(for f in $FRAGS; do echo $D/$f; done) >/dev/null
  $M olddefconfig >/dev/null
  # Every option the fragments ask for must survive olddefconfig (a missing dependency drops it silently).
  miss=$(for f in $FRAGS; do cat $D/$f; done |
    grep -oE "^CONFIG_[A-Z0-9_]+=[ym]" | cut -d= -f1 | while read -r k; do
      grep -qE "^$k=[ym]" $B/.config || echo "$k"; done)
  [ -z "$miss" ] || { echo "config options dropped by olddefconfig (missing dependency?):" $miss >&2; exit 1; }
  rm -f $B/arch/arm64/boot/Image.gz
  # No pipe here: a compile error must stop the script.
  $M Image.gz dtbs modules > $B/build.log 2>&1 || { grep -E "error|undefined" $B/build.log | head -20; exit 1; }
  test -f $B/arch/arm64/boot/Image.gz
  cp $B/arch/arm64/boot/Image.gz $O/
  cp $B/arch/arm64/boot/dts/qcom/sm8250-lenovo-q706f.dtb $O/
  cp $B/.config $O/config
  rm -rf $O/modules
  $M INSTALL_MOD_PATH=$O/modules INSTALL_MOD_STRIP=1 modules_install >/dev/null
  echo "warnings in build.log: $(grep -c "warning:" $B/build.log || true)"
  R=$(cat $B/include/config/kernel.release)
  # Out-of-tree modules, built from a copy so scripts/desktop/modules/ stays untouched.
  for m in $D/modules/*/; do
    [ -f $m/Makefile ] || continue
    n=$(basename $m)
    rm -rf $O/extmod/$n; mkdir -p $O/extmod; cp -r $m $O/extmod/$n
    find $O/extmod/$n \( -name "*.ko" -o -name "*.o" -o -name "*.mod*" -o -name ".*.cmd" \
      -o -name Module.symvers -o -name modules.order \) -delete
    make -s -C /work/sources/linux-desktop-7.4rc3 O=$B ARCH=arm64 \
      CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= M=$O/extmod/$n modules
    mkdir -p $O/modules/lib/modules/$R/extra
    cp $O/extmod/$n/*.ko $O/modules/lib/modules/$R/extra/
    echo "out-of-tree module: $n"
  done
  aarch64-linux-gnu-strip --strip-debug $O/modules/lib/modules/$R/extra/*.ko 2>/dev/null || true
  rm -f $O/modules/lib/modules/$R/build $O/modules/lib/modules/$R/source
  depmod -b $O/modules $R
'
REL=$(cat "$OUT/build/include/config/kernel.release")
TGZ="$ROOT/out/desktop/modules-7.4rc3-$(date +%Y%m%d).tgz"
tar -C "$OUT/modules" --owner=0 --group=0 -czf "$TGZ" "lib/modules/$REL"
echo "kernel $REL (upstream v$VER + $(ls "$PATCHES"/*.patch | wc -l) patches)"
ls -la "$OUT"/Image.gz "$OUT"/sm8250-lenovo-q706f.dtb "$TGZ"
sha256sum "$TGZ"
