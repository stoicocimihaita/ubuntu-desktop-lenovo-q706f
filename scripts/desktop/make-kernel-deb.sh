#!/usr/bin/env bash
# Package the outputs of a normal kernel build as a local Debian package for the tablet.
#
# Usage: scripts/desktop/make-kernel-deb.sh
#   Env: BUILD=<n>          build counter (default: one more than the newest .deb of this
#                           release already in out/desktop/deb/)
#        BOOT_IMG=<path>    boot image to ship (default: out/desktop/ubuntu-boot.img)
#
# Input (read only, produced by build-kernel.sh / kernel-cycle.sh build):
#   out/desktop/kernel/{Image.gz,sm8250-lenovo-q706f.dtb,config,modules/,build/System.map}
#   out/desktop/ubuntu-boot.img
# Output: out/desktop/deb/linux-q706f-<release>_<release>-<n>_arm64.deb
#
# The package contains
#   /usr/lib/modules/<release>/                      modules (incl. extra/ctn730.ko)
#   /boot/q706f/ubuntu-boot-<release>.img (+.sha256) header-v0 Android boot image
#   /boot/q706f/config-<release>, System.map-<release>
# and maintainer scripts that ONLY run depmod (postinst), refuse to remove the running
# release (prerm) and drop the depmod-generated index files on removal (postrm).
# It never writes a partition, never runs /etc/kernel/postinst.d, initramfs-tools or
# flash-kernel. Writing boot_a stays a separate, explicitly confirmed step
# (q706f-flash-kernel on the tablet, or fastboot from the PC).
# Packages of different releases have different names and paths, so they coexist.
set -euo pipefail
umask 022
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/out/desktop/kernel"
BOOT_IMG="${BOOT_IMG:-$ROOT/out/desktop/ubuntu-boot.img}"
DEBDIR="$ROOT/out/desktop/deb"
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- inputs
R="$(cat "$K/build/include/config/kernel.release" 2>/dev/null)" || die "no kernel.release: run build-kernel.sh"
[[ "$R" =~ ^[0-9][a-z0-9.+-]*$ ]] || die "release '$R' is not usable in a package name"
MODS="$K/modules/lib/modules"
[ "$(ls "$MODS")" = "$R" ] || die "$MODS must hold exactly one release ($R), has: $(ls "$MODS" | tr '\n' ' ')"
for f in Image.gz sm8250-lenovo-q706f.dtb config build/System.map; do
  [ -s "$K/$f" ] || die "missing $K/$f"
done
[ -s "$BOOT_IMG" ] || die "missing $BOOT_IMG"
[ -f "$MODS/$R/extra/ctn730.ko" ] || die "extra/ctn730.ko missing: run 'kernel-cycle.sh build' (it builds the out-of-tree modules)"

# The kernel in Image.gz must be the release the modules were built for.
kver="$({ gzip -dc "$K/Image.gz" 2>/dev/null || true; } | grep -a -m1 -o 'Linux version [^ ]*' | cut -d' ' -f3)"
[ "$kver" = "$R" ] || die "Image.gz says release '$kver', modules are '$R'"
for ko in "$MODS/$R"/extra/*.ko; do
  vm="$(modinfo -F vermagic "$ko" 2>/dev/null || true)"
  [ "${vm%% *}" = "$R" ] || die "$(basename "$ko"): vermagic '$vm' does not match $R"
done

# The boot image must be a header-v0 image built from exactly these kernel outputs.
u32() { od -An -t u4 -j "$2" -N 4 "$1" | tr -d ' '; }
[ "$(head -c 8 "$BOOT_IMG")" = "ANDROID!" ] || die "$BOOT_IMG is not an Android boot image"
[ "$(u32 "$BOOT_IMG" 40)" = 0 ] || die "$BOOT_IMG: header version $(u32 "$BOOT_IMG" 40), expected 0"
PAGE="$(u32 "$BOOT_IMG" 36)"; KSZ="$(u32 "$BOOT_IMG" 8)"
[ "$PAGE" = 4096 ] || die "$BOOT_IMG: page size $PAGE, expected 4096"
cmp -s <(tail -c +$((PAGE + 1)) "$BOOT_IMG" | head -c "$KSZ") <(cat "$K/Image.gz" "$K/sm8250-lenovo-q706f.dtb") \
  || die "$BOOT_IMG does not contain out/desktop/kernel/Image.gz + DTB (rebuild it with make-testboot.sh)"
CMDLINE="$(dd if="$BOOT_IMG" bs=1 skip=64 count=512 status=none | tr -d '\0')"
[[ "$CMDLINE" == *q706f.rootimg=* ]] || die "$BOOT_IMG has no q706f.rootimg= on its cmdline (diagnostic image?)"
IMG_SIZE="$(stat -c %s "$BOOT_IMG")"
BOOT_A_MAX=$((0x6000000))   # partition-size:boot_a on this tablet (same as install.sh)
[ "$IMG_SIZE" -lt "$BOOT_A_MAX" ] || die "$BOOT_IMG ($IMG_SIZE bytes) does not fit in boot_a"

# ---------------------------------------------------------------- version
mkdir -p "$DEBDIR"
PKG="linux-q706f-$R"
if [ -z "${BUILD:-}" ]; then
  last="$(ls "$DEBDIR" 2>/dev/null | sed -n "s/^${PKG//./\\.}_${R//./\\.}-\([0-9]\+\)_arm64\.deb$/\1/p" | sort -n | tail -1)"
  BUILD=$(( ${last:-0} + 1 ))
fi
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "BUILD must be a number"
VERSION="$R-$BUILD"
DEB="$DEBDIR/${PKG}_${VERSION}_arm64.deb"
[ -e "$DEB" ] && die "$DEB already exists (set BUILD=)"

# ---------------------------------------------------------------- staging tree
ST="$DEBDIR/.stage-$PKG"
rm -rf "$ST"; mkdir -p "$ST/DEBIAN" "$ST/usr/lib/modules" "$ST/boot/q706f" "$ST/usr/share/doc/$PKG"
# Modules without the build/source symlinks (they point into the PC's build tree) and
# without the index files depmod regenerates on the tablet.
GENERATED='modules.dep modules.dep.bin modules.alias modules.alias.bin modules.softdep modules.weakdep
  modules.symbols modules.symbols.bin modules.builtin.bin modules.builtin.alias.bin modules.devname'
tar -C "$MODS" --exclude="$R/build" --exclude="$R/source" \
  $(for g in $GENERATED; do printf -- '--exclude=%s/%s ' "$R" "$g"; done) -cf - "$R" \
  | tar -C "$ST/usr/lib/modules" -xf -
B="$ST/boot/q706f"
install -m 0644 "$BOOT_IMG" "$B/ubuntu-boot-$R.img"
(cd "$B" && sha256sum "ubuntu-boot-$R.img" > "ubuntu-boot-$R.img.sha256")
install -m 0644 "$K/config" "$B/config-$R"
install -m 0644 "$K/build/System.map" "$B/System.map-$R"
IMG_SHA="$(cut -d' ' -f1 "$B/ubuntu-boot-$R.img.sha256")"
SERIES="$(cat "$ROOT/sources/linux-desktop/.rev" 2>/dev/null || echo unknown)"
D="$ST/usr/share/doc/$PKG"
cat > "$D/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: linux
Source: https://cdn.kernel.org/pub/linux/kernel/ (version and patch series: see README.q706f)

Files: *
Copyright: Linus Torvalds and many others
License: GPL-2.0-only
 On Debian systems the full text is in /usr/share/common-licenses/GPL-2.
EOF
cat > "$D/README.q706f" <<EOF
Kernel $R for the Lenovo Tab P12 Pro (TB-Q706F), built by scripts/desktop/build-kernel.sh
(kernel.org tarball + scripts/desktop/patches; series stamp: $SERIES).
Boot image: /boot/q706f/ubuntu-boot-$R.img  sha256 $IMG_SHA
Installing this package does NOT write any partition. To boot this kernel:
  - from the PC: fastboot boot <image>  (RAM test), then, with the owner's OK,
    fastboot flash boot_a <image>
  - on the tablet: sudo q706f-flash-kernel /boot/q706f/ubuntu-boot-$R.img
    (backs up boot_a first, asks for a typed confirmation)
EOF
printf '%s (%s) unstable; urgency=low\n\n  * Local build %s of kernel %s for q706f.\n\n -- q706f port <q706f-port@localhost>  %s\n' \
  "$PKG" "$VERSION" "$BUILD" "$R" "$(date -R)" | gzip -9n > "$D/changelog.Debian.gz"

# ---------------------------------------------------------------- maintainer scripts
cat > "$ST/DEBIAN/postinst" <<EOF
#!/bin/sh
# Only rebuilds the module index. No initramfs, no flash-kernel, no /etc/kernel hooks,
# no partition writes.
set -e
if [ "\$1" = configure ]; then
  depmod -a $R
fi
exit 0
EOF
cat > "$ST/DEBIAN/prerm" <<EOF
#!/bin/sh
# Refuse to remove the modules of the kernel that is running now (upgrades of the same
# package are allowed). Override, at your own risk: Q706F_REMOVE_RUNNING_KERNEL=yes
set -e
if [ "\$1" = remove ] && [ "\$(uname -r)" = "$R" ] && [ "\${Q706F_REMOVE_RUNNING_KERNEL:-}" != yes ]; then
  echo "$PKG: refusing to remove the RUNNING kernel's modules ($R)." >&2
  echo "Boot another kernel first, or set Q706F_REMOVE_RUNNING_KERNEL=yes." >&2
  exit 1
fi
exit 0
EOF
cat > "$ST/DEBIAN/postrm" <<EOF
#!/bin/sh
# Remove the index files depmod generated (they are not owned by the package).
set -e
if [ "\$1" = remove ] || [ "\$1" = purge ]; then
  for f in $(echo $GENERATED); do rm -f "/usr/lib/modules/$R/\$f"; done
  rmdir --ignore-fail-on-non-empty "/usr/lib/modules/$R" 2>/dev/null || true
fi
exit 0
EOF
cat > "$ST/DEBIAN/preinst" <<EOF
#!/bin/sh
# Warn when the modules of the running kernel are about to be replaced by another build
# of the same release: they belong to the new boot image, not to the kernel in memory.
set -e
if [ "\$1" = upgrade ] && [ "\$(uname -r)" = "$R" ]; then
  echo "$PKG: replacing the modules of the running kernel $R; boot the matching" >&2
  echo "/boot/q706f/ubuntu-boot-$R.img (fastboot boot, or q706f-flash-kernel) soon." >&2
fi
exit 0
EOF
chmod 0755 "$ST/DEBIAN/postinst" "$ST/DEBIAN/prerm" "$ST/DEBIAN/postrm" "$ST/DEBIAN/preinst"

cat > "$ST/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: arm64
Maintainer: q706f port <q706f-port@localhost>
Installed-Size: $(du -sk --exclude=DEBIAN "$ST" | cut -f1)
Depends: kmod
Section: kernel
Priority: optional
Description: Linux kernel $R for the Lenovo Tab P12 Pro (q706f)
 Modules, configuration, System.map and the header-v0 Android boot image
 (kernel + DTB + initramfs) of Linux $R built for the TB-Q706F.
 .
 Installing this package never writes a partition: it only runs depmod.
 The boot image is written to boot_a separately, with q706f-flash-kernel
 (typed confirmation, backup first) or fastboot from a PC.
EOF
(cd "$ST" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z | xargs -0 md5sum) > "$ST/DEBIAN/md5sums"
chmod 0644 "$ST/DEBIAN/control" "$ST/DEBIAN/md5sums"
find "$ST" -type d -exec chmod 0755 {} +
find "$ST" -type f ! -path "$ST/DEBIAN/*" -exec chmod 0644 {} +

# ---------------------------------------------------------------- build
if command -v dpkg-deb >/dev/null; then
  dpkg-deb --root-owner-group -Zxz --build "$ST" "$DEB" >/dev/null
else
  "$ROOT/scripts/dev-shell.sh" dpkg-deb --root-owner-group -Zxz --build \
    "/work/${ST#"$ROOT"/}" "/work/${DEB#"$ROOT"/}" >/dev/null
fi
rm -rf "$ST"
echo "package  $(basename "$DEB")  $(stat -c %s "$DEB") bytes"
echo "kernel   $R; boot image sha256 ${IMG_SHA:0:16}…  ($IMG_SIZE bytes, from ${BOOT_IMG#"$ROOT"/})"
echo "modules  $(dpkg-deb -c "$DEB" | grep -c '\.ko$') .ko files"
echo "install on the tablet: sudo apt install --no-install-recommends ./$(basename "$DEB")   (writes no partition)"
