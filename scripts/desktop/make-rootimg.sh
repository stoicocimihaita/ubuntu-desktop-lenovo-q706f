#!/usr/bin/env bash
# Assemble out/desktop/ubuntu-desktop.img (ext4, sparse) from out/desktop/rootfs plus
# the current kernel modules, the q706f firmware and the device overlay. Nothing here
# touches the tablet.
#
# The rootfs tree is NOT modified: modules, firmware and overlay are added in an overlayfs
# mounted on top of it inside the build container, so the same tree can be reused and a
# file removed from the overlay never lingers in a later image.
#
# Usage: scripts/desktop/make-rootimg.sh [size, default 14G]
# Env:   ROOTFS_NAME=name  input tree out/desktop/<name>          (default: rootfs)
#        IMG_NAME=file     output image out/desktop/<file>        (default: ubuntu-desktop.img;
#                          must match q706f.rootimg= in the boot image to be bootable)
#        MAIN_REPO=dir     directory that holds sources/lenovo-sm8250-q706f-firmware
#                          (default: the root of this repository)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SIZE="${1:-14G}"
ROOTFS_NAME="${ROOTFS_NAME:-rootfs}"
IMG_NAME="${IMG_NAME:-ubuntu-desktop.img}"
FW="${MAIN_REPO:-$ROOT}/sources/lenovo-sm8250-q706f-firmware"
OUT="$ROOT/out/desktop"
KMOD="$OUT/kernel/modules/lib/modules"
die() { echo "ERROR: $*" >&2; exit 1; }

case "$ROOTFS_NAME$IMG_NAME" in */*) die "ROOTFS_NAME and IMG_NAME are plain names under out/desktop" ;; esac
[ -d "$OUT/$ROOTFS_NAME/etc" ] || die "no out/desktop/$ROOTFS_NAME: run scripts/desktop/build-rootfs.sh first"
[ -d "$KMOD" ] || die "no kernel modules in out/desktop/kernel/modules: run scripts/desktop/kernel-cycle.sh build"
[ "$(ls "$KMOD" | wc -l)" = 1 ] || die "expected exactly one kernel release in $KMOD, found: $(ls "$KMOD" | tr '\n' ' ')"
KREL="$(ls "$KMOD")"
[ -f "$KMOD/$KREL/modules.dep" ] || die "$KMOD/$KREL has no modules.dep (incomplete modules_install)"
# Out-of-tree modules are only built by 'kernel-cycle.sh build' (not by build-kernel.sh).
for m in "$ROOT"/scripts/desktop/modules/*/; do
  [ -f "$m/Makefile" ] || continue
  n="$(basename "$m")"
  [ -f "$KMOD/$KREL/extra/$n.ko" ] || die "out-of-tree module $n.ko is missing from $KMOD/$KREL/extra: run scripts/desktop/kernel-cycle.sh build"
done
for f in sm8250/q706f/adsp.mbn sm8250/q706f/a650_zap.mbn goodix_firmware.bin cirrus; do
  [ -e "$FW/$f" ] || die "firmware not found: $FW/$f (clone silime/lenovo-sm8250-q706f-firmware there or set MAIN_REPO)"
done
BRINGUP="$(sed -n 's/^BRINGUP=//p' "$OUT/$ROOTFS_NAME/etc/q706f-image" 2>/dev/null || true)"
echo "image: out/desktop/$IMG_NAME  from out/desktop/$ROOTFS_NAME  kernel $KREL  BRINGUP=${BRINGUP:-unknown}"
[ -n "$BRINGUP" ] || echo "WARNING: out/desktop/$ROOTFS_NAME has no /etc/q706f-image (built by an older build-rootfs.sh): rebuild it to get the current defaults"
[ "$BRINGUP" != 1 ] || echo "WARNING: BRINGUP=1 rootfs: password-less sudo, autologin and --unsafe-mode are in this image"

# ALSA UCM profile (silime/ubuntu-lenovo-q706f, not redistributed here): downloaded at a
# pinned commit, sha256-checked and patched with the q706f speaker volume cap + microphones.
"$ROOT/scripts/desktop/ucm/fetch-ucm.sh" "$OUT/ucm"

docker run --rm --privileged -v "$ROOT:/work" -v "$FW:/fw:ro" \
  -e L="/work/out/desktop/$ROOTFS_NAME" -e IMG="/work/out/desktop/$IMG_NAME" -e KREL="$KREL" \
  -e SIZE="$SIZE" -e OWNER="$(id -u):$(id -g)" ubuntu:24.04 bash -euc '
  S="$IMG.stage"; R="$S/root"
  cleanup() { if mountpoint -q "$R"; then umount "$R"; fi; rm -rf "$S"; }
  trap cleanup EXIT
  rm -rf "$S"; mkdir -p "$S/upper" "$S/work" "$R"
  mount -t overlay overlay -o "lowerdir=$L,upperdir=$S/upper,workdir=$S/work" "$R"

  rm -rf "$R"/usr/lib/modules/*
  mkdir -p "$R/usr/lib/modules"
  cp -a /work/out/desktop/kernel/modules/lib/modules/. "$R/usr/lib/modules/"
  rm -f "$R/usr/lib/modules/$KREL/build" "$R/usr/lib/modules/$KREL/source"   # links into the build tree
  mkdir -p "$R/usr/lib/firmware/qcom/sm8250" "$R/usr/lib/firmware/cirrus"
  cp -a /fw/sm8250/q706f "$R/usr/lib/firmware/qcom/sm8250/"
  cp -a /fw/goodix_*.bin "$R/usr/lib/firmware/"
  cp -a /fw/cirrus/. "$R/usr/lib/firmware/cirrus/"
  chown -R 0:0 "$R/usr/lib/modules" "$R/usr/lib/firmware/qcom/sm8250/q706f" "$R/usr/lib/firmware/cirrus" "$R"/usr/lib/firmware/goodix_*.bin
  chmod -R u=rwX,go=rX "$R/usr/lib/modules"

  # Device files kept in the repo (udev rules, services, enabled-unit links).
  # Copy through tar so every overlay file ends up owned by root and not group-writable (the
  # repo files belong to the build user, whose uid equals the first user on the tablet, so
  # root-run scripts would be writable by that user). Existing directories (/etc, /usr, ...)
  # keep their own mode and owner.
  tar -C /work/scripts/desktop/overlay --owner=0 --group=0 --mode=go-w --exclude=__pycache__ -cf - . \
    | tar -C "$R" -xf - --no-same-owner --no-overwrite-dir
  # UCM profile prepared by fetch-ucm.sh (same ownership rules as the overlay).
  tar -C /work/out/desktop/ucm --owner=0 --group=0 --mode=go-w -cf - . \
    | tar -C "$R" -xf - --no-same-owner --no-overwrite-dir
  grep -q "Digital PCM Volume. 350" "$R/usr/share/alsa/ucm2/Lenovo/q706f/HiFi.conf" \
    || { echo "ERROR: UCM speaker volume cap missing"; exit 1; }

  if [ -x "$R/usr/bin/glib-compile-schemas" ]; then
    chroot "$R" glib-compile-schemas /usr/share/glib-2.0/schemas 2> "$S/schemas.err" || { cat "$S/schemas.err"; exit 1; }
    if grep -q 90_q706f "$S/schemas.err"; then
      cat "$S/schemas.err"; echo "ERROR: 90_q706f.gschema.override has a key the installed schemas do not accept"; exit 1
    fi
  fi
  # Every unit the overlay enables through a wants/ link must exist in the image.
  find "$R/etc/systemd/system" "$R/etc/systemd/user" -path "*.wants/q706f-*" -type l | while read -r l; do
    t="$(readlink "$l")"
    case "$t" in /*) t="$R$t" ;; *) t="$(dirname "$l")/$t" ;; esac   # absolute links are relative to the image
    [ -e "$t" ] || { echo "ERROR: dangling enable link ${l#"$R"}"; exit 1; }
  done

  chroot "$R" depmod -a "$KREL"
  if [ -d "$R/usr/lib/modules/$KREL/extra" ]; then
    for ko in "$R/usr/lib/modules/$KREL"/extra/*.ko; do
      grep -q "^extra/$(basename "$ko"):" "$R/usr/lib/modules/$KREL/modules.dep" \
        || { echo "ERROR: $(basename "$ko") is not in modules.dep"; exit 1; }
    done
  fi

  rm -f "$IMG"
  mke2fs -q -t ext4 -L ubuntu-desktop -d "$R" -E lazy_itable_init=1 "$IMG" "$SIZE"
  chown "$OWNER" "$IMG"
'
ls -las "$OUT/$IMG_NAME"
