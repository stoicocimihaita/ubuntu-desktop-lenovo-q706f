#!/usr/bin/env bash
# One kernel iteration for q706f Ubuntu: build -> boot image -> modules to the tablet ->
# boot from RAM -> checks. Prints a short summary. NEVER flashes: writing boot_a stays a
# separate, explicitly confirmed step (the command is printed at the end).
#
# Usage: scripts/desktop/kernel-cycle.sh [stage...]      (default: all stages)
#   build    rebuild kernel + out-of-tree modules + ubuntu-boot.img
#   push     copy /usr/lib/modules to the tablet and run depmod
#   ramboot  reboot the tablet to the bootloader and `fastboot boot` the image
#   check    run the standard checks over ssh
# Env: TABLET=q706f-ubuntu (ssh host; q706f-wifi when not on USB), SERIAL=<fastboot serial>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TABLET="${TABLET:-q706f-ubuntu}"
SERIAL="${SERIAL:-}"   # filled in by the ramboot stage when empty
IMG="$ROOT/out/desktop/ubuntu-boot.img"
LOG="$ROOT/out/desktop/kernel-cycle.log"
STAGES=("$@"); [ ${#STAGES[@]} -eq 0 ] && STAGES=(build push ramboot check)
say() { printf '== %s\n' "$*"; }
fb() { timeout "${T:-20}" fastboot ${SERIAL:+-s "$SERIAL"} "$@"; }

do_build() {
  say "build kernel (log: $LOG)"
  "$ROOT/scripts/desktop/build-kernel.sh" > "$LOG" 2>&1 || { tail -20 "$LOG"; exit 1; }
  if grep -qiE "^(patch:|.*FAILED|.*\.rej)" "$LOG"; then grep -iE "FAILED|\.rej" "$LOG" | head; exit 1; fi
  for m in "$ROOT"/scripts/desktop/modules/*/; do
    [ -f "$m/Makefile" ] || continue
    n=$(basename "$m")
    "$ROOT/scripts/dev-shell.sh" bash -ec "
      make -s -C /work/sources/linux-desktop O=/work/out/desktop/kernel/build ARCH=arm64 \
        CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= M=/work/scripts/desktop/modules/$n modules
      R=\$(cat /work/out/desktop/kernel/build/include/config/kernel.release)
      mkdir -p /work/out/desktop/kernel/modules/lib/modules/\$R/extra
      cp /work/scripts/desktop/modules/$n/*.ko /work/out/desktop/kernel/modules/lib/modules/\$R/extra/
      aarch64-linux-gnu-strip --strip-debug /work/out/desktop/kernel/modules/lib/modules/\$R/extra/*.ko
      depmod -b /work/out/desktop/kernel/modules \$R" >> "$LOG" 2>&1
  done
  EXTRA_CMDLINE="q706f.rootimg=ubuntu-desktop.img" OUT_NAME=ubuntu-boot.img \
    "$ROOT/scripts/desktop/make-testboot.sh" >> "$LOG" 2>&1
  say "kernel $(tail -n +1 "$LOG" | grep -m1 '^kernel ' || true)"
  say "image  $(sha256sum "$IMG" | cut -c1-16)  $(stat -c %s "$IMG") bytes"
}

do_push() {
  say "push modules to $TABLET"
  R=$(ls "$ROOT/out/desktop/kernel/modules/lib/modules" | head -1)
  tar -C "$ROOT/out/desktop/kernel/modules/lib/modules" -cf - "$R" | ssh "$TABLET" "sudo sh -ec '
    rm -rf /usr/lib/modules/$R.new; mkdir -p /usr/lib/modules/$R.new
    tar -C /usr/lib/modules/$R.new -xf - --strip-components=1 -m
    chown -R 0:0 /usr/lib/modules/$R.new
    [ -d /usr/lib/modules/$R ] && mv /usr/lib/modules/$R /usr/lib/modules/$R.old
    mv /usr/lib/modules/$R.new /usr/lib/modules/$R; depmod $R; rm -rf /usr/lib/modules/$R.old; sync'"
  say "modules $R installed"
}

do_ramboot() {
  [ -f "$IMG" ] || { echo "no $IMG"; exit 1; }
  say "reboot tablet to bootloader"
  # End a pen wireless-charging session cleanly first (an interrupted one corrupts the pen's NFC tag).
  ssh "$TABLET" 'sudo sh -c "[ -e /sys/class/misc/ctn730/enable ] && echo 0 > /sys/class/misc/ctn730/enable; sleep 2; sync; (sleep 1; systemctl reboot --reboot-argument=bootloader) >/dev/null 2>&1 &"' || true
  until fastboot devices | grep -q fastboot; do sleep 3; done
  [ -n "$SERIAL" ] || SERIAL=$(fastboot devices | awk 'NR==1{print $1}')
  sleep 6
  # After entering from Linux the ABL is only half initialised: always restart it once.
  fb reboot bootloader >/dev/null 2>&1 || true
  sleep 12; until fastboot devices | grep -q "$SERIAL"; do sleep 2; done; sleep 12
  # The ABL sometimes answers only every other command ("GetVar Variable Not found"):
  # require six clean answers in a row before sending anything to it.
  for i in 1 2 3 4 5 6; do
    sleep 2
    fb getvar max-download-size 2>&1 | grep -q 805306368 && fb getvar current-slot 2>&1 | grep -q 'current-slot: a' \
      || { echo "bootloader not ready (fastboot reboot bootloader again, or 'Restart bootloader' on the tablet)"; exit 1; }
  done
  say "slot $(fb getvar current-slot 2>&1 | head -1)"
  T=60 fb boot "$IMG" 2>&1 | tail -1
  say "waiting for the tablet (USB network)"
  until ip -br addr | grep -q 172.16.42; do sleep 3; done
  until timeout 8 ssh q706f-ubuntu true 2>/dev/null; do sleep 3; done
  TABLET=q706f-ubuntu
}

do_check() {
  say "checks on $TABLET"
  ssh "$TABLET" '
    echo "kernel   $(uname -v | cut -c1-40)  slot $(tr " " "\n" < /proc/cmdline | sed -n "s/androidboot.slot_suffix=//p")"
    for i in 1 2 3 4 5 6 7 8 9 10; do s=$(systemctl is-system-running); [ "$s" != starting ] && break; sleep 3; done
    echo "system   $s; failed units: $(systemctl --failed --no-legend | wc -l)"
    echo "lsm      $(cat /sys/kernel/security/lsm)"
    echo "sound    $(head -1 /proc/asound/cards | cut -c1-50)"
    echo "wifi     $(nmcli -t -f DEVICE,STATE dev | grep "^wlp" | head -1)"
    echo "bt       $(bluetoothctl show | grep -c "Powered: yes") powered controller(s)"
    echo "sensors  hexagonrpcd=$(systemctl is-active hexagonrpcd) iio=$(systemctl is-active iio-sensor-proxy)"
    echo "input    $(grep -cE "Goodix Berlin (Capacitive|Stylus)" /proc/bus/input/devices) goodix, dock=$(grep -c "keyboard dock" /proc/bus/input/devices)"
    echo "battery  $(cat /sys/class/power_supply/bq27541-0/status) $(cat /sys/class/power_supply/bq27541-0/capacity)% $(cat /sys/class/power_supply/bq27541-0/voltage_now)uV $(cat /sys/class/power_supply/bq27541-0/current_now)uA max=$(cat /sys/class/power_supply/bq27541-0/voltage_max_design 2>/dev/null)"
    echo "ctn730   $(cat /sys/class/misc/ctn730/version 2>/dev/null || echo absent) $(timeout 3 cat /sys/class/misc/ctn730/status 2>/dev/null)"
    echo "errors   $(sudo dmesg -l err,crit,alert,emerg | wc -l) kernel error lines; deferred: $(sudo cat /sys/kernel/debug/devices_deferred | wc -l)"
    echo "date     $(date "+%F %T")"'
}

for s in "${STAGES[@]}"; do "do_$s"; done
cat <<EOF
== not done by this script (needs the owner's explicit OK each time):
   fastboot ${SERIAL:+-s $SERIAL }reboot bootloader   # from a session entered from Linux
   fastboot ${SERIAL:+-s $SERIAL }flash boot_a $IMG
   rollback: fastboot flash boot_a $ROOT/out/desktop/ubuntu-boot-7.1.img   # last 7.1 image; its modules are still on the tablet
EOF
