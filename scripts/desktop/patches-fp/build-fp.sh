#!/usr/bin/env bash
# Fingerprint test kernel (stage 0/1): the project kernel (sources/linux-desktop =
# v7.3.4 + scripts/desktop/patches/*.patch) + the series in this directory, built as
# release 7.3.4-fp so its modules install side by side with /usr/lib/modules/7.3.4.
# Same procedure as scripts/desktop/build-kernel.sh + kernel-cycle.sh (ctn730) +
# make-testboot.sh, but only in sources/linux-fp and out/desktop/kernel-fp/.
# Writes nothing to the tablet and nothing to the normal build outputs.
#
# Usage: scripts/desktop/patches-fp/build-fp.sh [prepare|kernel|ctn730|image|all]
#   prepare  recreate sources/linux-fp from sources/linux-desktop + *.patch here (-F0)
#   kernel   config (normal fragments + q706f-fp.config) and build Image.gz, dtbs, modules
#   ctn730   out-of-tree ctn730 module, built from a private copy
#   image    initramfs + header-v0 boot image out/desktop/ubuntu-boot-fp.img
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/scripts/desktop/patches-fp"
SRC="$ROOT/sources/linux-fp"
K="$ROOT/out/desktop/kernel-fp"
LV=-fp
JOBS=8
NAME=ubuntu-boot-fp.img
# The two new modules must not bind on their own during stage 1: they are kept out of
# the initramfs and blacklisted for alias autoloading (an explicit modprobe still works).
FP_MODS="goodix_fp_spi qseecomtee"

do_prepare() {
  [ "$(cat "$ROOT/sources/linux-desktop/.rev")" = "7.3.4 $(cat "$ROOT"/scripts/desktop/patches/*.patch | sha256sum | cut -c1-16)" ] \
    || { echo "sources/linux-desktop is not the current series; run build-kernel.sh first"; exit 1; }
  rm -rf "$SRC"
  cp -a "$ROOT/sources/linux-desktop" "$SRC"
  for p in "$HERE"/*.patch; do
    patch -d "$SRC" -p1 -s -N -F0 --no-backup-if-mismatch < "$p" \
      || { echo "patch FAILED: $(basename "$p")" >&2; exit 1; }
  done
  if find "$SRC" \( -name '*.rej' -o -name '*.orig' \) | grep -q .; then echo "rejects in $SRC"; exit 1; fi
  echo "$(cat "$SRC/.rev") + patches-fp $(cat "$HERE"/*.patch | sha256sum | cut -c1-16)" > "$SRC/.rev"
}

do_kernel() {
  mkdir -p "$K/build"
  "$ROOT/scripts/dev-shell.sh" bash -euc "
    cd /work/sources/linux-fp
    D=/work/scripts/desktop
    B=/work/out/desktop/kernel-fp/build
    O=/work/out/desktop/kernel-fp
    M=\"make -j$JOBS ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=$LV O=\$B\"
    cp \$D/config-pmos-q706f-6.11 \$B/.config
    \$M olddefconfig >/dev/null
    scripts/kconfig/merge_config.sh -m -O \$B \$B/.config \
      \$D/q706f-desktop.config \$D/q706f-7.3-renames.config \$D/q706f-7.3.4-extra.config \
      \$D/patches-fp/q706f-fp.config >/dev/null
    \$M olddefconfig >/dev/null
    # Every line of the fp fragment must have survived olddefconfig.
    grep -E '^(CONFIG_[A-Z0-9_]+=|# CONFIG_[A-Z0-9_]+ is not set$)' \$D/patches-fp/q706f-fp.config | while read -r l; do
      grep -qxF \"\$l\" \$B/.config || { echo \"config: not set as requested: \$l\"; exit 1; }
    done
    rm -f \$B/arch/arm64/boot/Image.gz
    \$M Image.gz dtbs modules > \$B/build.log 2>&1 || { grep -E 'error|undefined' \$B/build.log | head -20; exit 1; }
    test -f \$B/arch/arm64/boot/Image.gz
    cp \$B/arch/arm64/boot/Image.gz \$O/
    cp \$B/arch/arm64/boot/dts/qcom/sm8250-lenovo-q706f.dtb \$O/
    cp \$B/.config \$O/config
    rm -rf \$O/modules
    \$M INSTALL_MOD_PATH=\$O/modules INSTALL_MOD_STRIP=1 modules_install >/dev/null
    echo \"warnings in build.log: \$(grep -c 'warning:' \$B/build.log || true)\"
  "
  echo "kernel $(cat "$K/build/include/config/kernel.release")"
}

do_ctn730() {
  # Private copy: building in scripts/desktop/modules/ctn730 would overwrite the project's objects.
  rm -rf "$K/ctn730"; mkdir -p "$K/ctn730"
  cp "$ROOT"/scripts/desktop/modules/ctn730/{Makefile,ctn730.c} "$K/ctn730/"
  "$ROOT/scripts/dev-shell.sh" bash -ec "
    make -s -C /work/sources/linux-fp O=/work/out/desktop/kernel-fp/build ARCH=arm64 \
      CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=$LV M=/work/out/desktop/kernel-fp/ctn730 modules
    R=\$(cat /work/out/desktop/kernel-fp/build/include/config/kernel.release)
    mkdir -p /work/out/desktop/kernel-fp/modules/lib/modules/\$R/extra
    cp /work/out/desktop/kernel-fp/ctn730/ctn730.ko /work/out/desktop/kernel-fp/modules/lib/modules/\$R/extra/
    aarch64-linux-gnu-strip --strip-debug /work/out/desktop/kernel-fp/modules/lib/modules/\$R/extra/*.ko
    depmod -b /work/out/desktop/kernel-fp/modules \$R
    modinfo -F vermagic /work/out/desktop/kernel-fp/modules/lib/modules/\$R/extra/ctn730.ko"
}

do_image() {
  [ -f "$K/Image.gz" ] || { echo "build the kernel first"; exit 1; }
  BB="$ROOT/out/desktop/busybox"
  [ -x "$BB" ] || { echo "missing $BB (made by scripts/desktop/make-testboot.sh)"; exit 1; }
  R=$(cat "$K/build/include/config/kernel.release")
  W="$K/initramfs"
  rm -rf "$W"; mkdir -p "$W/bin"
  cp "$BB" "$W/bin/busybox"
  install -m 0755 "$ROOT/scripts/desktop/initramfs-init" "$W/init"
  mkdir -p "$W/lib"
  cp -a "$K/modules/lib/modules" "$W/lib/"
  # The initramfs coldplug loads every module with a matching alias: leave the two
  # fingerprint modules out of it (they stay in the full module tree for the rootfs).
  for m in $FP_MODS; do find "$W/lib/modules" -name "$m.ko*" -delete; done
  "$ROOT/scripts/dev-shell.sh" depmod -b "/work/out/desktop/kernel-fp/initramfs" "$R"
  FW="${MAIN_REPO:-$ROOT}/sources/lenovo-sm8250-q706f-firmware"
  mkdir -p "$W/lib/firmware/qcom/sm8250"
  cp -a "$FW/sm8250/q706f" "$W/lib/firmware/qcom/sm8250/"
  cp -a "$FW"/goodix_*.bin "$W/lib/firmware/"
  (cd "$W" && find . | cpio -o -H newc --quiet | gzip -9) > "$K/initramfs.cpio.gz"

  # Same cmdline as out/desktop/ubuntu-boot.img plus the stage-1 blacklist.
  CMDLINE="console=tty0 clk_ignore_unused pd_ignore_unused loglevel=7 rdinit=/init q706f.rootimg=ubuntu-desktop.img modprobe.blacklist=${FP_MODS// /,}"
  cat "$K/Image.gz" "$K/sm8250-lenovo-q706f.dtb" > "$K/Image.gz-dtb"
  END=$(( 0x00008000 + $(stat -c %s "$K/Image.gz-dtb") ))
  [ "$END" -lt $(( 0x01000000 )) ] || { echo "Image.gz+DTB overlaps ramdisk_offset"; exit 1; }
  printf 'kernel+dtb ends at 0x%08x, margin to ramdisk_offset: %d bytes\n' "$END" $(( 0x01000000 - END ))
  "$ROOT/scripts/dev-shell.sh" mkbootimg \
    --header_version 0 --pagesize 4096 --base 0x00000000 \
    --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --kernel /work/out/desktop/kernel-fp/Image.gz-dtb \
    --ramdisk /work/out/desktop/kernel-fp/initramfs.cpio.gz \
    --cmdline "$CMDLINE" \
    -o "/work/out/desktop/$NAME"
  tar -C "$K/modules/lib/modules" --owner=0 --group=0 -czf "$K/modules-$R.tar.gz" "$R"
  (cd "$ROOT/out/desktop" && sha256sum "$NAME" "kernel-fp/modules-$R.tar.gz" kernel-fp/Image.gz \
     kernel-fp/sm8250-lenovo-q706f.dtb) | tee "$K/SHA256SUMS"
}

STAGES=("$@"); [ ${#STAGES[@]} -eq 0 ] && STAGES=(all)
for s in "${STAGES[@]}"; do
  if [ "$s" = all ]; then do_prepare; do_kernel; do_ctn730; do_image; else "do_$s"; fi
done
