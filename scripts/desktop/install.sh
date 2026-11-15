#!/usr/bin/env bash
# Guided installer: Ubuntu 26.04 Desktop (mainline kernel) on the Lenovo Tab P12 Pro
# (TB-Q706F, "q706f"), from a Linux PC, for a tablet with an UNLOCKED bootloader.
#
#   scripts/desktop/install.sh [options] [step...]        default: all steps, in order
#   scripts/desktop/install.sh --rollback [options]       restore boot_a + dtbo_a, slot b
#
# Steps (each one can be run alone, e.g. to resume after a problem):
#   check     host tools and built images                                   no tablet access
#   backup    verify that your own dumps of boot_a and dtbo_a exist         no tablet access
#   slot      WRITES: fastboot erase dtbo_a, fastboot set_active a
#   diag      boots the diagnostic initramfs from RAM (fastboot boot)       nothing written
#   userdata  checks that userdata is ext4; WRITES (formats it) only if it is not,
#             after a separate, loud confirmation - this ERASES ALL ANDROID DATA
#   rootfs    WRITES: copies ubuntu-desktop.img into the userdata filesystem
#   ubuntu    boots Ubuntu from RAM (fastboot boot ubuntu-boot.img)         nothing written
#   flash     WRITES: fastboot flash boot_a ubuntu-boot.img, set_active a
#   post      over ssh: password, Wi-Fi, Bluetooth address, sensors
#
# Options:
#   --dry-run          print every command instead of running it; the tablet is not
#                      contacted at all (not even "fastboot devices")
#   --yes              answer "yes" to harmless questions (continue? run this optional
#                      step?). It NEVER confirms a write to the tablet: those always
#                      need the exact phrase typed on the terminal.
#   --backup-dir DIR   directory with your boot_a.bin and dtbo_a.bin (searched
#                      recursively, e.g. backup/edl-YYYY-MM-DD from scripts/backup-edl.sh).
#                      Default: $BACKUP_DIR, else the newest backup/edl-* in this repo.
#   --i-have-no-backup-and-accept-the-risk
#                      continue without the two dumps (rollback will be impossible)
#   --serial SERIAL    fastboot serial, needed when several devices are attached
#   --rollback         see above; needs the backup, no override
#
# Environment: SSH_HOST (default ubuntu@172.16.42.1), DIAG_IMG, HEXAGONFS, MAIN_REPO.
# Tested host side only with --dry-run and against a simulated initramfs; see README.md.
#
# What this script never touches: persist, modem*, xbl*, abl, super, boot_b, dtbo_b,
# vbmeta*. It never unlocks the bootloader and never sends a second "fastboot boot"
# in a bootloader session where one was already sent.
#
# shellcheck disable=SC2016  # single-quoted snippets are expanded by the shell on the tablet
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/out/desktop"
DIAG_IMG="${DIAG_IMG:-$OUT/testboot.img}"
BOOT_IMG="$OUT/ubuntu-boot.img"
ROOT_IMG="$OUT/ubuntu-desktop.img"
ROOT_IMG_NAME="ubuntu-desktop.img"          # must match q706f.rootimg= in the boot image
TOOLS="$OUT/install-tools"
TABLET_IP="${TABLET_IP:-172.16.42.1}"       # fixed by initramfs-init and q706f-usb-gadget
SSH_HOST="${SSH_HOST:-ubuntu@$TABLET_IP}"
MAIN_REPO="${MAIN_REPO:-$ROOT}"             # holds sources/lenovo-sm8250-q706f-firmware
HEXAGONFS="${HEXAGONFS:-$MAIN_REPO/sources/lenovo-sm8250-q706f-firmware/hexagonfs}"
BACKUP_DIR="${BACKUP_DIR:-}"
SERIAL="${SERIAL:-}"
BOOT_A_MAX=$((0x6000000))                   # partition-size:boot_a on this tablet
EXPECTED_MAX_DL=805306368                   # max-download-size of a fully started ABL
# Dynamic loader call for the e2fsprogs/coreutils binaries pushed into the initramfs.
E2="/e2/ld-linux-aarch64.so.1 --library-path /e2"

DRY=0; YES=0; ROLLBACK=0; NO_BACKUP=0; BOOT_SENT=0; BACKUP_DONE=0
BACKUP_BOOT=""; BACKUP_DTBO=""
STEPS=()

# ---------------------------------------------------------------- output / input

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

tty_read() {  # $1 = prompt; answer in REPLY. Fails when nobody sits at a terminal.
  printf '%s' "$1" >&2
  IFS= read -r REPLY 2>/dev/null </dev/tty \
    || die "no terminal available: confirmations must be typed by a person"
}

ask_yes() {  # harmless yes/no question; --yes and --dry-run answer yes
  if [ "$DRY" = 1 ] || [ "$YES" = 1 ]; then info "$1 -> yes (--yes/--dry-run)"; return 0; fi
  tty_read "$1 [y/N] "
  [ "$REPLY" = y ] || [ "$REPLY" = Y ]
}

pause() {  # wait for the person to do something physical
  if [ "$DRY" = 1 ]; then info "[dry-run] would wait for you: $1"; return 0; fi
  tty_read "$1 - press Enter when done "
}

write_notice() {  # $1 what, $2 where, $3 risk, $4 rollback
  printf '\n'
  printf '  ################  WRITE TO THE TABLET  ################\n'
  printf '  WHAT:      %s\n' "$1"
  printf '  WHERE:     %s\n' "$2"
  printf '  RISK:      %s\n' "$3"
  printf '  ROLLBACK:  %s\n' "$4"
  printf '  #######################################################\n'
}

confirm_write() {  # $1 = exact phrase. Not skipped by --yes.
  if [ "$DRY" = 1 ]; then info "[dry-run] here you would have to type exactly: $1"; return 0; fi
  tty_read "Type '$1' to do it (anything else aborts): "
  [ "$REPLY" = "$1" ] || die "not confirmed; aborted before this write"
}

# ---------------------------------------------------------------- fastboot

fb() {  # fastboot with serial and timeout; only printed in --dry-run
  printf '+ fastboot %s%s\n' "${SERIAL:+-s $SERIAL }" "$*" >&2
  [ "$DRY" = 1 ] && return 0
  timeout "${FB_TIMEOUT:-30}" fastboot ${SERIAL:+-s "$SERIAL"} "$@"
}

fb_var() {  # value of one bootloader variable; empty when the ABL does not answer
  if [ "$DRY" = 1 ]; then printf '+ fastboot getvar %s\n' "$1" >&2; return 0; fi
  { timeout 10 fastboot ${SERIAL:+-s "$SERIAL"} getvar "$1" 2>&1 || true; } \
    | sed -n "s/^$1: *//p" | head -n1
}

fb_devices() { { fastboot devices 2>/dev/null || true; } | awk '$2 == "fastboot" { print $1 }'; }

wait_fastboot() {  # $1 = timeout in seconds; picks SERIAL when exactly one device
  local t="${1:-120}" n=0 devs count
  if [ "$DRY" = 1 ]; then info "[dry-run] would wait for the tablet in fastboot mode"; return 0; fi
  while :; do
    devs="$(fb_devices)"
    count="$(printf '%s' "$devs" | grep -c . || true)"
    if [ -n "$SERIAL" ]; then
      if printf '%s\n' "$devs" | grep -qx "$SERIAL"; then return 0; fi
    elif [ "$count" = 1 ]; then
      SERIAL="$devs"; return 0
    elif [ "$count" -gt 1 ]; then
      die "more than one device in fastboot mode: pass --serial"
    fi
    n=$((n + 3)); [ "$n" -ge "$t" ] && return 1
    sleep 3
  done
}

need_fastboot() {
  if wait_fastboot 6; then return 0; fi
  cat <<EOF

The tablet is not in fastboot mode. Bring it there, with the USB cable plugged in:
  - from Ubuntu (ssh or terminal):  sudo systemctl reboot --reboot-argument=bootloader
  - from Android with USB debugging: adb reboot bootloader
  - powered off: hold Power + Volume Up (key combination from the postmarketOS wiki)
The screen shows the Lenovo fastboot menu. Waiting up to 5 minutes...
EOF
  wait_fastboot 300 || die "no tablet in fastboot mode"
}

check_device() {
  local product unlocked
  [ "$DRY" = 1 ] && { fb_var product; fb_var unlocked; return 0; }
  product="$(fb_var product)"; unlocked="$(fb_var unlocked)"
  [ "$product" = kona ] || die "bootloader reports product '$product', expected 'kona' (TB-Q706F). Wrong device?"
  [ "$unlocked" = yes ] || die "bootloader is locked (unlocked: '$unlocked'). This script does not unlock it: see docs/RECUPERARE.md (unlocking wipes the tablet)."
}

check_ready() {  # $1 = size in bytes of what will be downloaded
  local v
  v="$(fb_var max-download-size)"
  [ "$DRY" = 1 ] && return 0
  if ! [[ "$v" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]]; then
    die "the bootloader does not answer 'getvar max-download-size' (got '$v'): it is half-initialised.
       Do NOT send boot/flash now. On the tablet choose 'Restart bootloader' (volume keys +
       power), wait 20 s and run this step again."
  fi
  v=$((v))
  [ "$v" -ge "$1" ] || die "max-download-size $v is smaller than the image ($1 bytes)"
  [ "$v" = "$EXPECTED_MAX_DL" ] || warn "max-download-size is $v; the tablet this was developed on reports $EXPECTED_MAX_DL"
}

# The Lenovo ABL is only half initialised when fastboot was entered from Linux
# ("download size more than max allowed", unknown getvar), and after a failed boot the
# next 'boot' resets the tablet. So every step that sends boot/flash/erase first
# restarts the bootloader once and starts a clean session.
fresh_session() {
  say "restarting the bootloader for a clean fastboot session"
  need_fastboot
  fb reboot bootloader || true
  if [ "$DRY" = 0 ]; then
    sleep 10
    wait_fastboot 120 || die "the tablet did not come back to fastboot; use 'Restart bootloader' on its menu and run this step again"
    sleep 15
  fi
  BOOT_SENT=0
  check_device
}

fb_boot() {  # $1 = image. At most one 'boot' per bootloader session.
  [ "$BOOT_SENT" = 0 ] || die "a 'boot' command was already sent in this bootloader session; a second one resets the tablet. Run the step again (it restarts the bootloader first)."
  BOOT_SENT=1
  FB_TIMEOUT=90 fb boot "$1" \
    || info "fastboot reported an error. With this ABL 'Booting FAILED (usb_read failed)' normally means the kernel WAS started; checking the USB network next."
}

# ---------------------------------------------------------------- network to the tablet

tcp_open() { timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null; }

wait_tcp() {  # $1 port, $2 timeout
  local n=0
  while ! tcp_open "$TABLET_IP" "$1"; do
    n=$((n + 3)); [ "$n" -ge "$2" ] && return 1
    sleep 2
  done
}

# Run one command in the initramfs root shell (busybox telnetd on 172.16.42.1:23).
# Prints the command output, returns the remote exit status (255: no answer).
# Output is delimited by marker lines; the markers are typed in a form ("A""B", $?) that
# the echo of the command line cannot match.
tn_run() {  # $1 = seconds without output before giving up, $2 = command (< 900 chars)
  local t="$1" cmd="$2" line rc=255 fd go=0
  if [ "$DRY" = 1 ]; then printf '+ [telnet %s] %s\n' "$TABLET_IP" "$cmd" >&2; return 0; fi
  [ "${#cmd}" -lt 900 ] || die "internal: remote command too long for the busybox line editor"
  tcp_open "$TABLET_IP" 23 || return 255
  exec {fd}<>"/dev/tcp/$TABLET_IP/23"
  sleep 1
  printf 'echo "__Q706F_""GO__"; %s; echo __Q706F_RC_$?__\n' "$cmd" >&"$fd"
  while IFS= read -r -t "$t" -u "$fd" line; do
    line="${line//$'\r'/}"
    # Everything before the GO line is the telnet banner and the echo of the command.
    if [ "$go" = 0 ]; then [ "$line" = __Q706F_GO__ ] && go=1; continue; fi
    if [[ "$line" =~ ^__Q706F_RC_([0-9]+)__$ ]]; then rc="${BASH_REMATCH[1]}"; break; fi
    printf '%s\n' "$line"
  done
  exec {fd}>&-
  return "$rc"
}

tag() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -n1; }   # value of a TAG=value line

need_diag() {
  [ "$DRY" = 1 ] && return 0
  tcp_open "$TABLET_IP" 23 || die "the diagnostic initramfs is not reachable (telnet $TABLET_IP).
       Run the 'diag' step first. If the tablet is in it but the PC has no address on the new
       USB network interface: sudo ip addr add 172.16.42.2/24 dev <usb interface>"
}

# Receive a stream on the tablet: start "<sink>" detached, send the output of the given
# local command to it, wait for the sink to finish and check its exit status.
push_stream() {  # $1 port, $2 seconds to wait for the sink, $3 sink (no single quotes), $4.. producer
  local port="$1" wait="$2" sink="$3" rc="" n=0 out
  shift 3
  tn_run 15 "rm -f /rx.rc; setsid sh -c '$sink; echo \$? > /rx.rc' </dev/null >/dev/null 2>&1 & sleep 1" >/dev/null \
    || die "could not start the receiver on the tablet"
  if [ "$DRY" = 1 ]; then printf '+ %s > /dev/tcp/%s/%s\n' "$*" "$TABLET_IP" "$port" >&2; return 0; fi
  sleep 2
  # One connection only: busybox "nc -l" serves a single client and exits.
  "$@" > "/dev/tcp/$TABLET_IP/$port" || die "sending to $TABLET_IP:$port failed"
  while [ "$n" -lt "$wait" ]; do
    out="$(tn_run 10 'echo "RX_""RC=$(cat /rx.rc 2>/dev/null)"' || true)"
    rc="$(tag RX_RC "$out")"
    [ -n "$rc" ] && break
    sleep 3; n=$((n + 4))
  done
  [ "$rc" = 0 ] || die "the receiver on the tablet failed (status '${rc:-timeout}')"
}

# mke2fs, e2fsck and GNU dd (with their libraries) from the arm64 ubuntu:24.04 image, plus
# the reboot-to-bootloader helper. The initramfs busybox can only create ext2, cannot
# write sparse files and cannot pass a reboot argument.
build_tools() {
  [ -s "$TOOLS/tools.tar" ] && return 0
  if [ "$DRY" = 1 ]; then info "[dry-run] would build $TOOLS/tools.tar (docker, arm64 ubuntu:24.04 + cross gcc)"; return 0; fi
  say "building the helper bundle for the initramfs ($TOOLS)"
  rm -rf "$TOOLS"; mkdir -p "$TOOLS/bundle"
  docker run --rm --platform linux/arm64 -v "$TOOLS/bundle:/o" ubuntu:24.04 bash -euc '
    for f in /usr/sbin/mke2fs /usr/sbin/e2fsck /usr/bin/dd; do
      cp -L "$f" /o/
      ldd "$f" | awk "\$2 == \"=>\" && \$3 ~ /^\\// { print \$3 }" | xargs -r cp -L -t /o
    done
    cp -L /lib/ld-linux-aarch64.so.1 /o/
    cp /etc/mke2fs.conf /o/
    chown -R '"$(id -u):$(id -g)"' /o'
  "$ROOT/scripts/dev-shell.sh" aarch64-linux-gnu-gcc -static -nostdlib -ffreestanding -O2 \
    -o /work/out/desktop/install-tools/bundle/reboot-to /work/scripts/desktop/tools/reboot-to.c
  for f in mke2fs e2fsck dd ld-linux-aarch64.so.1 mke2fs.conf reboot-to; do
    [ -s "$TOOLS/bundle/$f" ] || die "helper bundle incomplete: $f missing"
  done
  tar -C "$TOOLS/bundle" -cf "$TOOLS/tools.tar" .
}

push_tools() {
  local out
  build_tools
  if [ "$DRY" = 0 ]; then
    out="$(tn_run 10 'test -x /e2/mke2fs && test -x /e2/dd && test -x /e2/reboot-to && echo "TOOLS_""OK=1"' || true)"
    [ "$(tag TOOLS_OK "$out")" = 1 ] && return 0
  fi
  say "copying the helper bundle into the initramfs (RAM only, /e2)"
  tn_run 10 'mkdir -p /e2' >/dev/null || die "cannot create /e2 in the initramfs"
  push_stream 9001 60 "nc -l -p 9001 | tar -xf - -C /e2" cat "$TOOLS/tools.tar"
}

send_rootimg() {
  if command -v pv >/dev/null 2>&1; then pv -pterb "$ROOT_IMG" | gzip -1 -c; else gzip -1 -c "$ROOT_IMG"; fi
}

# Shell snippet for the initramfs: D=/dev/<userdata partition> (same lookup as initramfs-init).
FIND_UD='D=; for u in /sys/class/block/*/uevent; do grep -q "^PARTNAME=userdata\$" $u && D=/dev/$(basename $(dirname $u)); done'

# ---------------------------------------------------------------- backup gate

find_backup() {  # sets BACKUP_BOOT / BACKUP_DTBO; returns 1 when something is missing or wrong
  local f magic ok=0 sums
  if [ -z "$BACKUP_DIR" ]; then
    BACKUP_DIR="$(find "$ROOT/backup" -maxdepth 1 -type d -name 'edl-*' 2>/dev/null | sort | tail -n1)"
  fi
  if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then
    warn "no backup directory (use --backup-dir DIR)"; return 1
  fi
  BACKUP_BOOT="$(find "$BACKUP_DIR" -type f -name boot_a.bin | head -n1)"
  BACKUP_DTBO="$(find "$BACKUP_DIR" -type f -name dtbo_a.bin | head -n1)"
  for f in boot_a dtbo_a; do
    case "$f" in boot_a) [ -s "$BACKUP_BOOT" ] || { warn "boot_a.bin not found in $BACKUP_DIR"; ok=1; } ;;
                 dtbo_a) [ -s "$BACKUP_DTBO" ] || { warn "dtbo_a.bin not found in $BACKUP_DIR"; ok=1; } ;;
    esac
  done
  [ "$ok" = 0 ] || return 1
  magic="$(head -c 8 "$BACKUP_BOOT" | tr -d '\0')"
  [ "$magic" = 'ANDROID!' ] || { warn "$BACKUP_BOOT does not start with the Android boot magic"; ok=1; }
  magic="$(head -c 4 "$BACKUP_DTBO" | od -An -tx1 | tr -d ' \n')"
  [ "$magic" = d7b7ab1e ] || { warn "$BACKUP_DTBO has no DTBO table magic (dumped after the erase?)"; ok=1; }
  sums="$BACKUP_DIR/SHA256SUMS"
  if [ -f "$sums" ]; then
    if (cd "$BACKUP_DIR" && grep -E '/(boot_a|dtbo_a)\.bin$' SHA256SUMS | sha256sum -c --quiet -); then
      info "SHA256SUMS: boot_a.bin and dtbo_a.bin verified"
    else
      warn "checksum mismatch against $sums"; ok=1
    fi
  else
    warn "no SHA256SUMS in $BACKUP_DIR: the dumps could not be verified"
  fi
  return "$ok"
}

step_backup() {
  [ "$BACKUP_DONE" = 0 ] || return 0
  BACKUP_DONE=1
  say "backup check"
  cat <<EOF
   Before anything is written you need YOUR OWN dump of this tablet, taken over Qualcomm
   EDL while it was untouched: scripts/backup-edl.sh (read-only, ~11 GB, every partition
   except userdata; procedure in docs/RECUPERARE.md). It is the only copy of the
   per-device data (persist, modemst1/2, fsg, fsc, devinfo) and the only way back if
   fastboot itself stops working. The stock firmware package does NOT replace it.
   This installer needs at least boot_a.bin and dtbo_a.bin from it for --rollback.
EOF
  if find_backup; then
    info "boot_a: $BACKUP_BOOT"
    info "dtbo_a: $BACKUP_DTBO"
    return 0
  fi
  [ "$ROLLBACK" = 0 ] || die "rollback needs the dumps of boot_a and dtbo_a"
  if [ "$NO_BACKUP" = 1 ]; then
    warn "continuing WITHOUT a backup (--i-have-no-backup-and-accept-the-risk): the stock overlay in dtbo_a cannot be restored afterwards"
    return 0
  fi
  die "no usable backup of boot_a/dtbo_a. Make one with scripts/backup-edl.sh and pass --backup-dir."
}

# ---------------------------------------------------------------- steps

step_check() {
  local f fail=0
  say "host and image check"
  "$ROOT/scripts/desktop/check-host.sh" || { warn "check-host.sh reported missing build prerequisites (needed to build, and for docker in this installer)"; }
  for f in fastboot docker gzip sha256sum timeout; do
    command -v "$f" >/dev/null 2>&1 || { warn "missing on this PC: $f"; fail=1; }
  done
  command -v adb >/dev/null 2>&1 || info "adb not found (only needed to reboot a running Android into fastboot)"
  command -v ssh >/dev/null 2>&1 || info "ssh not found (needed for the 'post' step)"
  for f in "$DIAG_IMG" "$BOOT_IMG" "$ROOT_IMG"; do
    [ -s "$f" ] || { warn "missing image: $f (build it first, see README.md)"; fail=1; }
  done
  [ "$fail" = 0 ] || die "prerequisites missing"
  grep -a -q "q706f.rootimg=$ROOT_IMG_NAME" "$BOOT_IMG" \
    || die "$BOOT_IMG has no q706f.rootimg=$ROOT_IMG_NAME on its command line (build it with kernel-cycle.sh build)"
  if grep -a -q 'q706f.rootimg=' "$DIAG_IMG"; then
    warn "$DIAG_IMG has q706f.rootimg= set; the diagnostic image should be built without EXTRA_CMDLINE"
  fi
  [ "$(stat -c %s "$BOOT_IMG")" -le "$BOOT_A_MAX" ] || die "$BOOT_IMG is larger than boot_a ($BOOT_A_MAX bytes)"
  info "diag   $(sha256sum "$DIAG_IMG" | cut -c1-16)  $(stat -c %s "$DIAG_IMG") bytes  $DIAG_IMG"
  info "boot   $(sha256sum "$BOOT_IMG" | cut -c1-16)  $(stat -c %s "$BOOT_IMG") bytes  $BOOT_IMG"
  info "rootfs $(stat -c %s "$ROOT_IMG") bytes ($(du -h "$ROOT_IMG" | cut -f1) on disk)  $ROOT_IMG"
}

step_slot() {
  local slot
  fresh_session
  slot="$(fb_var current-slot)"
  say "prepare slot a (current slot: ${slot:-?})"
  write_notice \
    "erase the DTBO partition of slot a (stock device-tree overlays)" \
    "partition dtbo_a (24 MiB). dtbo_b, boot_a, boot_b are not touched." \
    "Needed because the Lenovo ABL applies the stock overlay from dtbo onto the DTB of the image it boots; on the mainline DTB that fails and the ABL stays in fastboot after 'Booting OKAY'. Afterwards the stock Android kernel can no longer boot from slot a (on this Virtual A/B tablet slot a has no working Android anyway)." \
    "fastboot flash dtbo_a ${BACKUP_DTBO:-<your backup>/dtbo_a.bin}   (or: $0 --rollback)"
  confirm_write "erase dtbo_a"
  fb erase dtbo_a
  write_notice \
    "make slot a the active boot slot (A/B flags in the GPT)" \
    "slot flags only; no partition content changes" \
    "Until boot_a holds the Ubuntu boot image (step 'flash'), a normal power-on tries slot a, fails, and the ABL falls back to slot b by itself (it marks a 'unbootable'; this installer sets it active again when needed)." \
    "fastboot set_active b"
  confirm_write "set_active a"
  fb set_active a
  info "done: dtbo_a erased, slot a active"
}

step_diag() {
  fresh_session
  say "boot the diagnostic initramfs from RAM (nothing is written)"
  [ "$DRY" = 1 ] || [ "$(fb_var current-slot)" = a ] || die "the active slot is not 'a': run the 'slot' step first"
  check_ready "$(stat -c %s "$DIAG_IMG" 2>/dev/null || echo 0)"
  fb_boot "$DIAG_IMG"
  [ "$DRY" = 1 ] && return 0
  info "waiting for the USB network of the initramfs (telnet $TABLET_IP, up to 2 min)"
  if wait_tcp 23 120; then
    info "diagnostic initramfs is up: telnet $TABLET_IP (root shell, no password)"
    return 0
  fi
  if [ -n "$(fb_devices)" ]; then
    die "the tablet is still in fastboot: the ABL did not start the kernel (is dtbo_a erased and slot a active?).
       Do NOT send another boot in this session. Choose 'Restart bootloader' on the tablet, then run 'diag' again."
  fi
  die "no USB network from the tablet. If the PC shows a new USB network interface without an address:
       sudo ip addr add 172.16.42.2/24 dev <interface>, then run the next step.
       If the tablet restarted by itself, the kernel crashed: the ABL has probably marked slot a unbootable
       and switched to slot b. Enter fastboot again and run the 'slot' step (set_active a) before retrying."
}

step_userdata() {
  local out dev blk sectors gib extmagic
  say "userdata filesystem"
  need_diag
  if [ "$DRY" = 1 ]; then
    tn_run 30 "$FIND_UD; blkid \$D"
    info "[dry-run] if userdata is ext4 nothing is written; the destructive branch would be:"
    dev=/dev/sdaNN; blk=""; gib="?"
  else
    out="$(tn_run 30 "$FIND_UD"'; echo "UD_""DEV=$D"; echo "UD_""BLK=$(blkid $D)"; echo "UD_""SEC=$(cat /sys/class/block/${D#/dev/}/size)"; echo "UD_""EXT=$(dd if=$D bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1 | tr -d " \n")"' || true)"
    dev="$(tag UD_DEV "$out")"; blk="$(tag UD_BLK "$out")"; sectors="$(tag UD_SEC "$out")"; extmagic="$(tag UD_EXT "$out")"
    [[ "$dev" =~ ^/dev/[a-z0-9]+$ ]] || die "userdata partition not found in the initramfs (got '$dev')"
    gib=$(( ${sectors:-0} / 2097152 ))
    info "userdata is $dev, ${gib} GiB; blkid: ${blk:-<no known filesystem signature>}; ext magic: ${extmagic:-none}"
    # ext2/3/4 superblock magic (0xEF53 at byte 1080) is the authority: a filesystem that
    # has it is never offered for formatting, whatever blkid or mount say.
    if [ "$extmagic" = 53ef ]; then
      out="$(tn_run 60 "grep -q '^$dev /data ' /proc/mounts || mount -t ext4 -o rw,noatime $dev /data; echo \"UD_\"\"MNT=\$?\"; df -h /data | tail -n1; ls -la /data | head -n 20" || true)"
      printf '%s\n' "$out" | grep -v '^UD_MNT='
      [ "$(tag UD_MNT "$out")" = 0 ] || die "userdata IS an ext filesystem but this kernel cannot mount it (typically an unclean journal left by
       the 4.19 Ubuntu Touch kernel: 'JBD2: Invalid checksum recovering data block'). NOT formatting.
       Boot the other system once and shut it down cleanly, then repeat this step."
      info "userdata is ext4 and mounted: nothing to format, existing files are kept"
      return 0
    fi
  fi
  cat <<EOF

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  userdata is NOT ext4. Stock Android keeps it as encrypted f2fs. The Ubuntu boot image
  loop-mounts $ROOT_IMG_NAME from an ext4 userdata, so userdata must be re-created.

  THIS DESTROYS EVERYTHING ANDROID STORES ON THE TABLET: apps, accounts, photos,
  downloads, settings. It cannot be undone (the partition is discarded).

  Dual boot afterwards: stock Android on slot b will NOT start normally any more - it
  will ask for a factory reset, and accepting that reformats userdata and deletes
  Ubuntu. Dual boot only works with systems that live as files on an ext4 userdata
  (e.g. Ubuntu Touch as ubuntu.img). To go back to Android: --rollback, then factory
  reset from the stock recovery.
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
EOF
  write_notice \
    "create a new, empty ext4 filesystem (mke2fs, label 'userdata')" \
    "partition userdata = $dev (${gib} GiB), the whole partition" \
    "ALL user data on the tablet is erased, permanently. Nothing else is touched." \
    "none for the data. Android itself comes back with a factory reset from the stock recovery."
  confirm_write "ERASE ALL DATA ON USERDATA"
  push_tools
  # orphan_file / metadata_csum_seed are switched off so that the 4.19 Ubuntu Touch
  # kernel can still mount the filesystem.
  out="$(tn_run 900 "grep -q '^$dev ' /proc/mounts && echo \"MK_\"\"FS=busy\" || { MKE2FS_CONFIG=/e2/mke2fs.conf $E2 /e2/mke2fs -q -F -t ext4 -O ^orphan_file,^metadata_csum_seed -L userdata $dev; echo \"MK_\"\"FS=\$?\"; }" || true)"
  [ "$DRY" = 1 ] && { tn_run 60 "mount -t ext4 -o rw,noatime $dev /data"; return 0; }
  printf '%s\n' "$out" | grep -v '^MK_FS=' || true
  [ "$(tag MK_FS "$out")" = 0 ] || die "mke2fs failed (status '$(tag MK_FS "$out")')"
  tn_run 60 "mount -t ext4 -o rw,noatime $dev /data && df -h /data | tail -n1" || die "the new filesystem does not mount"
  info "userdata is now an empty ext4 filesystem"
}

step_rootfs() {
  local out dev avail need want got
  say "copy $ROOT_IMG_NAME into userdata"
  need_diag
  need=$(( $(stat -c %s "$ROOT_IMG") / 1024 + 1048576 ))
  if [ "$DRY" = 1 ]; then
    tn_run 60 "$FIND_UD; grep -q \"^\$D /data \" /proc/mounts || mount -t ext4 -o rw,noatime \$D /data; df -k /data"
  else
    out="$(tn_run 60 "$FIND_UD"'; grep -q "^$D /data " /proc/mounts || mount -t ext4 -o rw,noatime $D /data; echo "RF_""MNT=$?"; echo "RF_""DEV=$D"; echo "RF_""AVAIL=$(df -k /data | tail -n1 | awk "{print \$4}")"; test -e /data/'"$ROOT_IMG_NAME"' && echo "RF_""OLD=1"; ls -la /data | head -n 20' || true)"
    printf '%s\n' "$out" | grep -v '^RF_' || true
    [ "$(tag RF_MNT "$out")" = 0 ] || die "userdata is not mounted as ext4: run the 'userdata' step"
    dev="$(tag RF_DEV "$out")"; avail="$(tag RF_AVAIL "$out")"
    [[ "$avail" =~ ^[0-9]+$ ]] || die "could not read the free space on userdata"
    [ "$avail" -ge "$need" ] || die "not enough free space on userdata: ${avail} KiB free, ${need} KiB needed"
    if [ "$(tag RF_OLD "$out")" = 1 ]; then
      write_notice \
        "REPLACE the existing /$ROOT_IMG_NAME (an Ubuntu installation is already there)" \
        "file $ROOT_IMG_NAME on userdata ($dev)" \
        "the existing Ubuntu system, its home directory and settings are lost" \
        "none (copy the old image away first if you need it)"
      confirm_write "replace $ROOT_IMG_NAME"
    fi
  fi
  write_notice \
    "copy the root filesystem image ($(du -h "$ROOT_IMG" | cut -f1) of data, $(( $(stat -c %s "$ROOT_IMG") / 1073741824 )) GiB apparent, written sparse)" \
    "file /$ROOT_IMG_NAME inside the ext4 filesystem on userdata. No partition table or raw partition write." \
    "low: other files on userdata (e.g. Ubuntu Touch's ubuntu.img) are not touched" \
    "delete the file"
  confirm_write "write $ROOT_IMG_NAME"
  push_tools
  if [ "$DRY" = 0 ]; then
    info "computing the SHA-256 of the image on the PC..."
    want="$(sha256sum "$ROOT_IMG" | cut -d' ' -f1)"
    info "sha256 $want"
    info "sending (gzip over the USB network); this takes several minutes"
  fi
  push_stream 9000 300 \
    "nc -l -p 9000 | gunzip -c | $E2 /e2/dd of=/data/$ROOT_IMG_NAME.part bs=1M iflag=fullblock conv=sparse status=none" \
    send_rootimg
  if [ "$DRY" = 1 ]; then
    tn_run 1800 "sha256sum /data/$ROOT_IMG_NAME.part"
    tn_run 60 "mv /data/$ROOT_IMG_NAME.part /data/$ROOT_IMG_NAME && sync"
    return 0
  fi
  info "verifying on the tablet..."
  got="$(tn_run 1800 "sha256sum /data/$ROOT_IMG_NAME.part" | grep -oE '^[0-9a-f]{64}' | head -n1 || true)"
  [ "$got" = "$want" ] || die "checksum mismatch (tablet: '${got:-none}'). $ROOT_IMG_NAME.part was left on userdata; the old image, if any, is untouched."
  tn_run 120 "mv /data/$ROOT_IMG_NAME.part /data/$ROOT_IMG_NAME && sync && ls -las /data/$ROOT_IMG_NAME" \
    || die "could not rename the image on the tablet"
  info "image verified and in place"
}

leave_diag() {  # from the diagnostic initramfs back to the bootloader
  [ "$DRY" = 0 ] && ! tcp_open "$TABLET_IP" 23 && return 0
  say "leaving the diagnostic initramfs (unmount userdata, reboot to the bootloader)"
  push_tools
  tn_run 20 "umount /data 2>/dev/null; sync; /e2/reboot-to" >/dev/null || true
  [ "$DRY" = 1 ] || sleep 8
}

step_ubuntu() {
  leave_diag
  fresh_session
  say "boot Ubuntu from RAM (nothing is written to boot_a yet)"
  [ "$DRY" = 1 ] || [ "$(fb_var current-slot)" = a ] || die "the active slot is not 'a': run the 'slot' step first"
  check_ready "$(stat -c %s "$BOOT_IMG" 2>/dev/null || echo 0)"
  fb_boot "$BOOT_IMG"
  [ "$DRY" = 1 ] && return 0
  info "waiting for Ubuntu (ssh on $TABLET_IP, up to 4 min; first boot is slow)"
  if wait_tcp 22 240; then
    info "Ubuntu answers on ssh: ssh $SSH_HOST   (default password: ubuntu)"
    info "If ssh complains about a changed host key: ssh-keygen -R $TABLET_IP"
    ask_yes "Does the tablet screen show the Ubuntu login screen / desktop?" \
      || die "stop here and look at it over ssh before flashing (journalctl -b, dmesg)"
    return 0
  fi
  if tcp_open "$TABLET_IP" 23; then
    die "the initramfs fell back to diagnostics: it could not mount userdata or $ROOT_IMG_NAME.
       Look at the reason: telnet $TABLET_IP, then: dmesg | grep q706f-init"
  fi
  die "Ubuntu did not come up on the USB network. Nothing was flashed. If the tablet restarted by itself the ABL
       has probably switched to slot b: enter fastboot, run the 'slot' step again, then 'ubuntu'."
}

step_flash() {
  local sha
  if [ "$DRY" = 1 ] || tcp_open "$TABLET_IP" 22; then
    say "Ubuntu is running: it has to reboot into the bootloader for the flash"
    info "command: ssh -t $SSH_HOST 'sudo systemctl reboot --reboot-argument=bootloader'"
    if ask_yes "Run it now (asks for the ubuntu password)?"; then
      [ "$DRY" = 1 ] || ssh -t "$SSH_HOST" 'sudo systemctl reboot --reboot-argument=bootloader' || true
      [ "$DRY" = 1 ] || sleep 10
    fi
  else
    leave_diag
  fi
  fresh_session
  check_ready "$(stat -c %s "$BOOT_IMG" 2>/dev/null || echo 0)"
  sha="$(sha256sum "$BOOT_IMG" 2>/dev/null | cut -d' ' -f1)"
  say "flash the Ubuntu boot image"
  write_notice \
    "$BOOT_IMG ($(stat -c %s "$BOOT_IMG" 2>/dev/null || echo '?') bytes, sha256 ${sha:-?}): mainline kernel + DTB + initramfs" \
    "partition boot_a (slot a), then 'set_active a'. boot_b, dtbo_b, super and userdata are not touched." \
    "The old content of boot_a is replaced. If this kernel does not boot, the ABL marks slot a unbootable and falls back to slot b; fastboot stays available." \
    "fastboot flash boot_a ${BACKUP_BOOT:-<your backup>/boot_a.bin}   (or: $0 --rollback)"
  confirm_write "flash boot_a"
  FB_TIMEOUT=180 fb flash boot_a "$BOOT_IMG" \
    || die "flash failed. If the message was 'download size more than max allowed' the bootloader was half-initialised: run the 'flash' step again (it restarts the bootloader first). Do not retry by hand in this session."
  fb set_active a
  info "boot_a written, slot a active"
  if ask_yes "Reboot the tablet into Ubuntu now?"; then
    fb reboot
    [ "$DRY" = 1 ] && return 0
    if wait_tcp 22 240; then info "Ubuntu is up from boot_a: ssh $SSH_HOST"; else warn "no ssh on $TABLET_IP after 4 min; look at the tablet"; fi
  fi
}

ssh_t() {  # interactive ssh command (password prompts go to the terminal)
  printf '+ ssh -t %s %s\n' "$SSH_HOST" "$*" >&2
  [ "$DRY" = 1 ] && return 0
  ssh -t "$SSH_HOST" "$@"
}

step_post() {
  local ssid addr rc=0
  say "post-install over ssh ($SSH_HOST)"
  if [ "$DRY" = 0 ]; then
    tcp_open "$TABLET_IP" 22 || [ "$SSH_HOST" != "ubuntu@$TABLET_IP" ] || die "Ubuntu is not reachable on $TABLET_IP:22 (USB cable?)"
  fi
  info "The image ships one account: user 'ubuntu', initial password 'ubuntu' (unless built with"
  info "USER_PASSWORD=...), ssh password login enabled. See docs/REPRODUCERE-ROOTFS.md."

  if ask_yes "1/4 Change the password of 'ubuntu' now? (strongly recommended)"; then
    ssh_t passwd || warn "password not changed"
  fi

  # make-rootimg.sh runs depmod (out-of-tree modules such as extra/ctn730.ko, the pen
  # charger, included); this only matters for an image assembled by an older version.
  if ask_yes "    Refresh the kernel module index (sudo depmod -a)?"; then
    ssh_t 'sudo depmod -a' || warn "depmod failed"
  fi

  if ask_yes "2/4 Connect to a Wi-Fi network?"; then
    ssh_t 'sudo nmcli device wifi rescan 2>/dev/null; sleep 3; sudo nmcli --fields SSID,CHAN,SIGNAL,SECURITY device wifi list' || true
    if [ "$DRY" = 1 ]; then
      ssh_t "sudo nmcli --ask device wifi connect '<SSID>'"
    else
      tty_read "Network name (SSID): "; ssid="$REPLY"
      # --ask: the passphrase is typed on the tablet side of the ssh session, never stored here.
      [ -z "$ssid" ] || ssh_t "sudo nmcli --ask device wifi connect $(printf '%q' "$ssid")" || warn "Wi-Fi not connected"
    fi
  fi

  cat <<EOF

   3/4 Bluetooth address. On mainline the controller has no public address (Android keeps
   it in NV storage). Without /etc/q706f-bt-addr a stable address derived from the serial
   number is used. To keep the factory address (needed to share pairings with another OS on
   the tablet) enter it here. Stock Android shows it in Settings > About tablet > Status
   and as: adb shell getprop ro.odm.lenovo.btaddr   (note it BEFORE userdata is erased).
EOF
  if ask_yes "Set the factory Bluetooth address?"; then
    if [ "$DRY" = 1 ]; then
      ssh_t "echo XX:XX:XX:XX:XX:XX | sudo tee /etc/q706f-bt-addr >/dev/null && sudo systemctl restart q706f-bt-addr.service"
    else
      tty_read "Bluetooth address (XX:XX:XX:XX:XX:XX): "; addr="$REPLY"
      if [[ "$addr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        ssh_t "echo $addr | sudo tee /etc/q706f-bt-addr >/dev/null && sudo systemctl restart q706f-bt-addr.service" || warn "address not set"
      else
        warn "not a Bluetooth address; skipped"
      fi
    fi
  fi

  # Same idea for Wi-Fi: without /etc/q706f-wifi-addr, q706f-wifi-addr derives a stable
  # address from the serial number. (Applied by udev at the next boot; per the journal this
  # path has not been verified on the real interface yet.)
  if ask_yes "    Set the factory Wi-Fi MAC address too (getprop ro.odm.lenovo.wifiaddr)?"; then
    if [ "$DRY" = 1 ]; then
      ssh_t "echo XX:XX:XX:XX:XX:XX | sudo install -m 600 /dev/stdin /etc/q706f-wifi-addr"
    else
      tty_read "Wi-Fi address (XX:XX:XX:XX:XX:XX): "; addr="$REPLY"
      if [[ "$addr" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        ssh_t "echo $addr | sudo install -m 600 /dev/stdin /etc/q706f-wifi-addr" || warn "address not set"
      else
        warn "not a MAC address; skipped"
      fi
    fi
  fi

  cat <<EOF

   4/4 Sensors (auto-rotation, ambient light) through the SLPI: setup-sensors.sh installs
   hexagonrpcd from the archive, builds libssc and iio-sensor-proxy from pinned sources ON
   the tablet (needs internet there) and copies the proprietary DSP registry files from
   $HEXAGONFS
   It runs many non-interactive ssh/sudo commands, so it needs an ssh key on the tablet and
   password-less sudo; this step installs /etc/sudoers.d/90-q706f-install and REMOVES it
   again at the end.
EOF
  if ask_yes "Set up the sensors now?"; then
    if [ "$DRY" = 0 ] && [ ! -d "$HEXAGONFS/sensors/registry" ]; then
      warn "missing $HEXAGONFS (set HEXAGONFS=<dir with dsp/ sensors/ ...>); sensors skipped"
    else
      if [ "$DRY" = 1 ] || ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null; then
        info "installing your ssh public key on the tablet (ssh-copy-id)"
        printf '+ ssh-copy-id %s\n' "$SSH_HOST" >&2
        [ "$DRY" = 1 ] || ssh-copy-id "$SSH_HOST" || die "ssh-copy-id failed (do you have a key? ssh-keygen -t ed25519)"
      fi
      ssh_t "echo \"\$USER ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/90-q706f-install >/dev/null && sudo chmod 440 /etc/sudoers.d/90-q706f-install" \
        || die "could not enable temporary password-less sudo"
      printf '+ HEXAGONFS=%s %s %s\n' "$HEXAGONFS" "$ROOT/scripts/desktop/setup-sensors.sh" "$SSH_HOST" >&2
      if [ "$DRY" = 0 ]; then
        HEXAGONFS="$HEXAGONFS" "$ROOT/scripts/desktop/setup-sensors.sh" "$SSH_HOST" || rc=$?
      fi
      printf '+ ssh %s sudo rm -f /etc/sudoers.d/90-q706f-install\n' "$SSH_HOST" >&2
      if [ "$DRY" = 0 ]; then
        ssh "$SSH_HOST" 'sudo rm -f /etc/sudoers.d/90-q706f-install' \
          || warn "REMOVE /etc/sudoers.d/90-q706f-install BY HAND: password-less sudo is still enabled"
      fi
      [ "$rc" = 0 ] || warn "setup-sensors.sh failed (status $rc)"
    fi
  fi

  cat <<EOF

   Still open after this step (see README.md, "Known issues and safety"):
   - ssh password login is enabled and the USB network gadget with ssh is always on;
   - the screen lock is disabled by default (Settings > Privacy & Security > Screen Lock);
   - speakers have no excursion/thermal protection: do not raise the amplifier volume
     above the cap in the UCM profile;
   - suspend (s2idle) is enabled; idle drain while suspended is still high (~150 mA).
     Switch: /etc/systemd/sleep.conf.d/10-q706f-suspend.conf (AllowSuspend=no).
EOF
}

do_rollback() {
  say "ROLLBACK: restore boot_a and dtbo_a from your backup, make slot b active"
  step_backup
  cat <<EOF
   This puts slot a back to what it was before the installation and returns to slot b
   (stock Android or Ubuntu Touch, whatever is there). It does NOT touch userdata: the
   file $ROOT_IMG_NAME stays there, and if userdata was re-created as ext4 for Ubuntu,
   stock Android will ask for a factory reset (which reformats userdata).
EOF
  fresh_session
  check_ready "$(stat -c %s "$BACKUP_BOOT")"
  write_notice \
    "$BACKUP_BOOT ($(stat -c %s "$BACKUP_BOOT") bytes, sha256 $(sha256sum "$BACKUP_BOOT" | cut -c1-16)...)" \
    "partition boot_a" \
    "the Ubuntu boot image in boot_a is replaced; Ubuntu no longer boots by itself" \
    "$0 flash"
  confirm_write "restore boot_a"
  FB_TIMEOUT=180 fb flash boot_a "$BACKUP_BOOT" || die "flash failed; run --rollback again (it restarts the bootloader first)"
  write_notice \
    "$BACKUP_DTBO ($(stat -c %s "$BACKUP_DTBO") bytes, sha256 $(sha256sum "$BACKUP_DTBO" | cut -c1-16)...)" \
    "partition dtbo_a" \
    "with the stock overlay back in dtbo_a the mainline kernel can no longer be booted on slot a" \
    "$0 slot"
  confirm_write "restore dtbo_a"
  FB_TIMEOUT=120 fb flash dtbo_a "$BACKUP_DTBO" || die "flash failed; run --rollback again"
  write_notice \
    "make slot b the active boot slot" \
    "A/B slot flags only" \
    "none known; slot b is where the stock system of this tablet lives" \
    "fastboot set_active a"
  confirm_write "set_active b"
  fb set_active b
  info "rollback done. 'fastboot reboot' starts whatever is installed on slot b."
  info "If even fastboot is gone: EDL restore from the full backup, docs/RECUPERARE.md."
}

# ---------------------------------------------------------------- main

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --yes|-y) YES=1 ;;
    --rollback) ROLLBACK=1 ;;
    --backup-dir) [ $# -ge 2 ] || die "--backup-dir needs a directory"; BACKUP_DIR="$2"; shift ;;
    --backup-dir=*) BACKUP_DIR="${1#*=}" ;;
    --serial) [ $# -ge 2 ] || die "--serial needs a value"; SERIAL="$2"; shift ;;
    --serial=*) SERIAL="${1#*=}" ;;
    --i-have-no-backup-and-accept-the-risk) NO_BACKUP=1 ;;
    -h|--help) usage; exit 0 ;;
    check|backup|slot|diag|userdata|rootfs|ubuntu|flash|post) STEPS+=("$1") ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
  shift
done

[ "$(id -u)" != 0 ] || die "do not run this as root"
[ "$DRY" = 0 ] || say "DRY RUN: commands are printed, nothing is executed on the tablet"

if [ "$ROLLBACK" = 1 ]; then
  [ ${#STEPS[@]} -eq 0 ] || die "--rollback does not take steps"
  command -v fastboot >/dev/null 2>&1 || [ "$DRY" = 1 ] || die "fastboot not found"
  do_rollback
  exit 0
fi

[ ${#STEPS[@]} -gt 0 ] || STEPS=(check backup slot diag userdata rootfs ubuntu flash post)

# Every run that can write to the tablet passes the backup gate first, even when a
# single step was requested.
for s in "${STEPS[@]}"; do
  case "$s" in slot|userdata|rootfs|flash) step_backup ;; esac
done

for s in "${STEPS[@]}"; do
  "step_$s"
done
say "finished: ${STEPS[*]}"
