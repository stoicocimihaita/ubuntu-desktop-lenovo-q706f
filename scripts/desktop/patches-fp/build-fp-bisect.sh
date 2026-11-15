#!/usr/bin/env bash
# Bisection images for the 7.3.4-fp RAM boot that did not come up (14.11.2026).
# Builds three header-v0 images under out/desktop/kernel-fp-bisect/, all release
# 7.3.4-fp so they share the module tree already on the tablet (/usr/lib/modules/7.3.4-fp):
#   fp-A  the stage-1 kernel, DTB and initramfs unchanged (reproduce)
#   fp-B  same kernel and initramfs, DTB without patch 0201 (= the normal 7.3.4 DTB)
#   fp-C  kernel rebuilt with CONFIG_QCOM_QSEECOM off (TEE_QSEECOM goes with it),
#         DTB with 0201, same initramfs
# The q706f DTS already carries ramoops@9e400000 (1 MiB, the stock region) and the
# config has PSTORE_RAM/PSTORE_CONSOLE=y, so every image (and B2 on boot_a) logs to it.
# The cmdline gains "panic=10 reboot=warm" so a panic reboots by itself, warm, which
# keeps the ramoops region; everything else is the stage-1 cmdline.
# Needs out/desktop/kernel-fp/ from build-fp.sh. Writes nothing outside
# out/desktop/kernel-fp-bisect/ and never touches the tablet.
#
# Usage: scripts/desktop/patches-fp/build-fp-bisect.sh [kernelC|pack|all]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
FP="$ROOT/out/desktop/kernel-fp"
OUT="$ROOT/out/desktop/kernel-fp-bisect"
NORMAL_DTB="$ROOT/out/desktop/kernel/sm8250-lenovo-q706f.dtb"
JOBS=8
CMDLINE="console=tty0 clk_ignore_unused pd_ignore_unused loglevel=7 rdinit=/init q706f.rootimg=ubuntu-desktop.img modprobe.blacklist=goodix_fp_spi,qseecomtee panic=10 reboot=warm"

do_kernelC() {
  [ -f "$FP/build/.config" ] || { echo "run build-fp.sh first"; exit 1; }
  mkdir -p "$OUT/C"
  # Start from a copy of the stage-1 build so only what QCOM_QSEECOM touches recompiles.
  rm -rf "$OUT/C/build"
  cp -a "$FP/build" "$OUT/C/build"
  "$ROOT/scripts/dev-shell.sh" bash -euc "
    cd /work/sources/linux-fp
    B=/work/out/desktop/kernel-fp-bisect/C/build
    M=\"make -j$JOBS ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION=-fp O=\$B\"
    scripts/config --file \$B/.config -d QCOM_QSEECOM -d QCOM_QSEECOM_UEFISECAPP -d TEE_QSEECOM
    \$M olddefconfig >/dev/null
    if grep -E '^CONFIG_(QCOM_QSEECOM|TEE_QSEECOM)=' \$B/.config; then echo 'QSEECOM still on'; exit 1; fi
    rm -f \$B/arch/arm64/boot/Image.gz
    \$M Image.gz > \$B/build-C.log 2>&1 || { grep -E 'error|undefined' \$B/build-C.log | head -20; exit 1; }
    cp \$B/arch/arm64/boot/Image.gz /work/out/desktop/kernel-fp-bisect/C/
    cp \$B/.config /work/out/desktop/kernel-fp-bisect/C/config
    cat \$B/include/config/kernel.release
  "
  diff "$FP/config" "$OUT/C/config" > "$OUT/C/config.diff" || true
  cat "$OUT/C/config.diff"
}

pack() { # name Image.gz dtb
  local name=$1 kern=$2 dtb=$3 d="$OUT/$1"
  mkdir -p "$d"
  cat "$kern" "$dtb" > "$d/Image.gz-dtb"
  cp "$dtb" "$d/sm8250-lenovo-q706f.dtb"
  local end=$(( 0x00008000 + $(stat -c %s "$d/Image.gz-dtb") ))
  [ "$end" -lt $(( 0x01000000 )) ] || { echo "$name: Image.gz+DTB overlaps ramdisk_offset"; exit 1; }
  printf '%s: kernel+dtb ends at 0x%08x, margin %d bytes\n' "$name" "$end" $(( 0x01000000 - end ))
  "$ROOT/scripts/dev-shell.sh" mkbootimg \
    --header_version 0 --pagesize 4096 --base 0x00000000 \
    --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --kernel "/work/out/desktop/kernel-fp-bisect/$name/Image.gz-dtb" \
    --ramdisk /work/out/desktop/kernel-fp/initramfs.cpio.gz \
    --cmdline "$CMDLINE" \
    -o "/work/out/desktop/kernel-fp-bisect/ubuntu-boot-$name.img"
}

do_pack() {
  [ -f "$OUT/C/Image.gz" ] || { echo "build kernel C first"; exit 1; }
  pack fp-A "$FP/Image.gz" "$FP/sm8250-lenovo-q706f.dtb"
  pack fp-B "$FP/Image.gz" "$NORMAL_DTB"
  pack fp-C "$OUT/C/Image.gz" "$FP/sm8250-lenovo-q706f.dtb"
  (cd "$OUT" && sha256sum ubuntu-boot-fp-A.img ubuntu-boot-fp-B.img ubuntu-boot-fp-C.img) | tee "$OUT/SHA256SUMS"
}

STAGES=("$@"); [ ${#STAGES[@]} -eq 0 ] && STAGES=(all)
for s in "${STAGES[@]}"; do
  if [ "$s" = all ]; then do_kernelC; do_pack; else "do_$s"; fi
done
