#!/usr/bin/env bash
# Pack the mainline kernel + q706f DTB + bring-up initramfs into a header-v0 boot.img
# (DTB appended to Image.gz). This script writes nothing to the tablet; the image is used
# with `fastboot boot` and, after the owner's explicit OK, flashed to boot_a.
# 7.4-rc3 variant: kernel from out/desktop/kernel-7.4 (build-kernel-7.4.sh), own initramfs
# work dir, so it never touches the 7.3.4 files. busybox / e2fsck.static are shared (read only).
# Output: out/desktop/${OUT_NAME:-ubuntu-boot-7.4rc3-<date>.img}
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
K="$ROOT/out/desktop/kernel-7.4"
W="$ROOT/out/desktop/initramfs-7.4"
RD="$ROOT/out/desktop/initramfs-7.4.cpio.gz"
[ -f "$K/Image.gz" ] || { echo "run scripts/desktop/build-kernel-7.4.sh first"; exit 1; }

# busybox-static (arm64) from the Ubuntu archive, via an arm64 container.
BB="$ROOT/out/desktop/busybox"
if [ ! -x "$BB" ]; then
  docker run --rm --platform linux/arm64 -v "$ROOT/out/desktop:/o" ubuntu:24.04 bash -ec '
    apt-get update -qq >/dev/null && apt-get install -y -qq busybox-static >/dev/null
    cp /bin/busybox /o/busybox'
fi

# Static e2fsck (Ubuntu e2fsck-static) to repair a dirty userdata journal before mounting.
E2=$ROOT/out/desktop/e2fsck.static
if [ ! -x "$E2" ]; then
  docker run --rm --platform linux/arm64 -v "$ROOT/out/desktop:/o" ubuntu:24.04 bash -ec '
    apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends e2fsck-static >/dev/null
    cp /sbin/e2fsck.static /o/e2fsck.static'
fi

rm -rf "$W"; mkdir -p "$W/bin"
cp "$BB" "$W/bin/busybox"
install -m 0755 "$E2" "$W/bin/e2fsck"
install -m 0755 "$ROOT/scripts/desktop/initramfs-init" "$W/init"
mkdir -p "$W/lib"
cp -a "$K/modules/lib/modules" "$W/lib/"
# Firmware the early drivers may ask for (GPU zap, DSPs, touch); harmless if unused.
FW="${MAIN_REPO:-$ROOT}/sources/lenovo-sm8250-q706f-firmware"
mkdir -p "$W/lib/firmware/qcom/sm8250"
cp -a "$FW/sm8250/q706f" "$W/lib/firmware/qcom/sm8250/"
cp -a "$FW"/goodix_*.bin "$W/lib/firmware/"
(cd "$W" && find . | cpio -o -H newc --quiet | gzip -9) > "$RD"

# The rootfs image from userdata (q706f.rootimg=ubuntu-desktop.img) is the default; EXTRA_CMDLINE= (set, empty)
# drops it (bring-up initramfs only).
# clk_ignore_unused pd_ignore_unused are no longer needed (B3af runs without them since
# 14.11.2026); DEBUG_CMDLINE="clk_ignore_unused pd_ignore_unused" brings them back for a test.
CMDLINE="console=tty0 ${DEBUG_CMDLINE:+$DEBUG_CMDLINE }loglevel=7 rdinit=/init ${EXTRA_CMDLINE-q706f.rootimg=ubuntu-desktop.img}"
NAME="${OUT_NAME:-ubuntu-boot-7.4rc3-$(date +%Y%m%d).img}"
# Header v0 with the DTB appended to Image.gz, like pmOS device-lenovo-q706f.
# The Lenovo ABL refuses a mainline DTB passed in the header-v2 dtb field
# (it stays in fastboot after "Booting OKAY").
cat "$K/Image.gz" "$K/sm8250-lenovo-q706f.dtb" > "$K/Image.gz-dtb"
# The kernel is loaded at kernel_offset and must end below ramdisk_offset.
END=$(( 0x00008000 + $(stat -c %s "$K/Image.gz-dtb") ))
[ "$END" -lt $(( 0x01000000 )) ] || { echo "Image.gz+DTB overlaps ramdisk_offset"; exit 1; }
printf 'kernel+dtb ends at 0x%08x, margin to ramdisk_offset: %d bytes\n' "$END" $(( 0x01000000 - END ))
"$ROOT/scripts/dev-shell.sh" mkbootimg \
  --header_version 0 --pagesize 4096 --base 0x00000000 \
  --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
  --tags_offset 0x00000100 \
  --kernel /work/out/desktop/kernel-7.4/Image.gz-dtb \
  --ramdisk /work/out/desktop/initramfs-7.4.cpio.gz \
  --cmdline "$CMDLINE" \
  -o "/work/out/desktop/$NAME"
echo "NOTE: after a failed boot ABL marks the active slot unbootable and switches slots;"
echo "recover with 'fastboot set_active a' (see docs/RECUPERARE.md)."
ls -la "$ROOT/out/desktop/$NAME"
sha256sum "$ROOT/out/desktop/$NAME"
