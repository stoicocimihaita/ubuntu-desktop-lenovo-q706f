#!/usr/bin/env bash
# Backup of the q706f Ubuntu root filesystem (/userdata/ubuntu-desktop.img) to the PC.
# Runs on the PC. Never writes to the tablet's partitions and never changes the tablet.
#
#   scripts/desktop/tools/q706f-backup-rootimg.sh [--dry-run] [--user-only] [--tar] [ssh-host]
#
#   ssh-host     default q706f-ubuntu (USB); q706f-vpn / q706f-wifi also work (slower).
#   --dry-run    only check the tablet (read-only) and print the commands that would run.
#   --user-only  back up /home/<user> only, without sudo (when sudo asks for a password).
#   --tar        use a tar stream instead of rsync (automatic when rsync is not installed
#                on the tablet; the image does not ship it).
#
# Result: out/desktop/backup-rootfs/<YYYY-MM-DD-HHMM>/ with
#   rootfs/            the file tree (rsync; root-only attributes kept with --fake-super as
#                      user.rsync.* xattrs, because the PC side runs without root)
#   rootfs.tar.zst     instead of rootfs/ with --tar (numeric owners, ACLs, xattrs kept)
#   info/              package list, manual packages, mounts, kernel, /etc/q706f-image
#   rsync.log / tar.log
# A previous rsync backup is used as --link-dest: unchanged files become hard links.
# The backup contains secrets (shadow, ssh host keys, Wi-Fi passwords, keyrings): it stays
# in out/ (not in git), mode 0700, and is never published (rule R9).
#
# Why not a raw copy of the image: the image is the live root filesystem (loop-mounted by
# the initramfs), so copying the .img file while Ubuntu runs gives an inconsistent ext4.
# fsfreeze on / over ssh can hang the session that has to unfreeze it. A file-level copy of
# the running system is consistent per file; files written during the copy (browser
# profiles, dconf, journals) can be caught mid-update: close the apps before running it.
#
# ---------------------------------------------------------------------------------------
# Copie brută a imaginii, consistentă (offline, cu imaginea NEmontată) — pași manuali:
#   Varianta 1, initramfs-ul de diagnostic (nimic nu se scrie pe partiții):
#     1. În Ubuntu: `sudo fstrim -v /` (opțional: copia sparse iese mai mică), apoi oprire
#        curată: `sudo systemctl reboot --reboot-argument=bootloader`.
#     2. Pe PC: `fastboot boot out/desktop/testboot.img` (boot din RAM; vezi
#        docs/RECUPERARE.md pentru capcanele fastboot). Apare shell-ul root: `telnet 172.16.42.1`.
#     3. În acel shell: montează userdata DOAR CITIRE și fără reluarea jurnalului:
#          mkdir -p /data && mount -t ext4 -o ro,noload /dev/sda<N> /data
#        (<N> = partiția cu PARTNAME=userdata: `grep -l userdata /sys/class/block/sda*/uevent`)
#          cat /data/ubuntu-desktop.img | gzip -1 | nc -l -p 9003
#     4. Pe PC:  nc 172.16.42.1 9003 | gunzip -c | dd of=out/desktop/backup-rootfs/<data>/ubuntu-desktop.img \
#                   bs=1M conv=sparse status=progress
#        apoi `e2fsck -fn` pe copie. La final, în shell: `umount /data; reboot -f` (pornește
#        iar de pe boot_a).
#   Varianta 2, din Ubuntu Touch (slotul b): cere `fastboot set_active b` (schimbă fanioanele
#     A/B — permis doar pentru recuperare, cu acordul proprietarului), apoi în UT imaginea nu
#     e montată: `sudo dd if=/userdata/ubuntu-desktop.img bs=1M | gzip -1` prin ssh pe PC.
#     Revenire: `fastboot set_active a`.
#
# Restaurare (în română):
#   - Fișiere izolate (de ex. /etc/ceva sau ~/.config), din copia rsync, de pe PC:
#       rsync -aHAX --numeric-ids --fake-super --rsync-path="sudo rsync" \
#         out/desktop/backup-rootfs/<data>/rootfs/etc/ceva q706f-ubuntu:/etc/ceva
#     (--fake-super pe partea PC-ului citește proprietarul/drepturile salvate în xattr-uri).
#   - Sistemul întreg: se reface o imagine nouă pe PC, în containerul privilegiat (root acolo):
#       rsync -aHAX --numeric-ids --fake-super -M--super <backup>/rootfs/ /stage/   # sau
#       tar --numeric-owner --acls --xattrs --xattrs-include='*' -xpf rootfs.tar.zst -C /stage
#       mke2fs -t ext4 -L ubuntu-desktop -d /stage out/desktop/ubuntu-desktop.img 14G
#     apoi `scripts/desktop/check-rootimg.sh` și copierea pe tabletă cu
#     `scripts/desktop/install.sh rootfs` (scrie în sistemul de fișiere userdata, cu confirmare
#     explicită). Imaginea veche rămâne până la confirmare; copia brută (variantele 1/2) se pune
#     înapoi la fel.
#   - Nimic din acest script nu restaurează automat: restaurarea e mereu o acțiune separată.
# ---------------------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRY=0; USER_ONLY=0; USE_TAR=0; HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --user-only) USER_ONLY=1 ;;
    --tar) USE_TAR=1 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) HOST="$1" ;;
  esac
  shift
done
HOST="${HOST:-q706f-ubuntu}"
BASE="$ROOT/out/desktop/backup-rootfs"
DEST="$BASE/$(date +%F-%H%M)"
SSH_OPTS="-o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o BatchMode=yes"
# Mount points stay (empty); their contents are never copied. -x / --one-file-system also
# keeps every other mounted filesystem (userdata with ubuntu.img, tmpfs, /boot/efi) out.
EXCLUDES=(/proc/ /sys/ /dev/ /run/ /tmp/ /var/tmp/ /mnt/ /media/ /userdata/ /lost+found/
          /var/cache/apt/archives/ /var/lib/apt/lists/ /swapfile)
die() { echo "ERROR: $*" >&2; exit 1; }
run() { printf '+ %s\n' "$*" >&2; [ "$DRY" = 1 ] || "$@"; }
# shellcheck disable=SC2086  # SSH_OPTS is a list of options
rsh() { timeout --foreground "$1" ssh $SSH_OPTS "$HOST" "$2"; }

for t in ssh timeout; do command -v "$t" >/dev/null || die "$t not found on the PC"; done
rsh 15 true || die "cannot reach $HOST (key login). Without USB try: $0 q706f-vpn"

ruser="$(rsh 10 'id -un')"
rootdev="$(rsh 10 'findmnt -no SOURCE,FSTYPE /' || true)"
used="$(rsh 10 'df -h --output=used / | tail -n1' || true)"
echo "tablet: $HOST user $ruser, / = ${rootdev:-?}, used ${used// /}"
rsh 10 'findmnt -no SOURCE / | grep -q "^/dev/loop"' || echo "WARNING: / is not a loop device: is this the q706f image?"

SUDO="sudo -n"
if [ "$USER_ONLY" = 0 ] && ! rsh 10 'sudo -n true' 2>/dev/null; then
  cat >&2 <<EOF
sudo on the tablet asks for a password, so a full backup cannot run unattended over ssh.
Options:
  - $0 --user-only $HOST      (only /home/$ruser, no sudo needed)
  - run it while password-less sudo is still enabled (bring-up tablet), or let the owner
    add a temporary rule for the backup and remove it afterwards.
EOF
  exit 1
fi
if [ "$USE_TAR" = 0 ] && ! rsh 10 'command -v rsync >/dev/null'; then
  echo "rsync is not installed on the tablet: using a tar stream (--tar)."
  echo "(to use rsync later: sudo apt install --no-install-recommends rsync, on the tablet)"
  USE_TAR=1
fi
if [ "$USE_TAR" = 0 ]; then command -v rsync >/dev/null || die "rsync not found on the PC"; fi
if [ "$USE_TAR" = 1 ]; then command -v zstd >/dev/null || die "zstd not found on the PC"; fi

# Source tree and remote privilege.
if [ "$USER_ONLY" = 1 ]; then SRC="/home/$ruser/"; SUDO=""; else SRC="/"; fi

echo "destination: $DEST"
run mkdir -p "$DEST/info"
run chmod 700 "$BASE" "$DEST"

# Metadata for a later rebuild (read-only commands).
if [ "$DRY" = 0 ]; then
  rsh 30 'dpkg --get-selections' > "$DEST/info/dpkg-selections.txt" || true
  rsh 30 'apt-mark showmanual' > "$DEST/info/apt-manual.txt" || true
  rsh 10 'findmnt -R -no TARGET,SOURCE,FSTYPE,OPTIONS /' > "$DEST/info/mounts.txt" || true
  rsh 10 'uname -a; cat /etc/q706f-image 2>/dev/null; cat /etc/os-release' > "$DEST/info/system.txt" || true
fi

rc=0
if [ "$USE_TAR" = 0 ]; then
  PREV="$(find "$BASE" -mindepth 2 -maxdepth 2 -type d -name rootfs 2>/dev/null | sort | tail -n1 || true)"
  ARGS=(-aHAX --numeric-ids --fake-super -x --partial --timeout=120 --info=stats2,progress2
        -e "ssh $SSH_OPTS" --log-file="$DEST/rsync.log")
  [ -n "$SUDO" ] && ARGS+=(--rsync-path="sudo -n rsync")
  [ -n "$PREV" ] && ARGS+=(--link-dest="$PREV") && echo "unchanged files are hard-linked to $PREV"
  if [ "$USER_ONLY" = 0 ]; then for e in "${EXCLUDES[@]}"; do ARGS+=(--exclude="$e*"); done; fi
  if [ "$USER_ONLY" = 0 ]; then ARGS+=(--exclude="/home/*/.cache/"); else ARGS+=(--exclude="/.cache/"); fi
  ARGS+=("$HOST:$SRC" "$DEST/rootfs/")
  run rsync "${ARGS[@]}" || rc=$?
  # 24 = some files vanished during the copy (normal on a running system).
  [ "$rc" = 24 ] && { echo "note: some files vanished while copying (rsync 24), backup is complete otherwise"; rc=0; }
else
  TEX=""
  if [ "$USER_ONLY" = 0 ]; then
    for e in "${EXCLUDES[@]}"; do TEX="$TEX '--exclude=.${e%/}/*'"; done
    TEX="$TEX '--exclude=./home/*/.cache/*'"
  else
    TEX="'--exclude=./.cache/*'"
  fi
  REMOTE="$SUDO tar -C $SRC --one-file-system --numeric-owner --acls --xattrs --xattrs-include='*' --sparse -cpf - $TEX ."
  printf '+ ssh %s "%s" | zstd -T0 -3 > %s\n' "$HOST" "$REMOTE" "$DEST/rootfs.tar.zst" >&2
  if [ "$DRY" = 0 ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$HOST" "$REMOTE" 2> "$DEST/tar.log" | zstd -T0 -3 -q -o "$DEST/rootfs.tar.zst" || rc=$?
    # tar status 1 = "file changed as we read it" on a live system: still a usable archive.
    if [ "$rc" != 0 ] && grep -q 'file changed as we read it' "$DEST/tar.log" && ! grep -qv 'file changed as we read it\|socket ignored' "$DEST/tar.log"; then rc=0; fi
    zstd -tq "$DEST/rootfs.tar.zst" || { echo "zstd test failed"; rc=1; }
  fi
fi

if [ "$DRY" = 1 ]; then echo "dry run: nothing copied"; exit 0; fi
du -sh "$DEST" 2>/dev/null || true
[ "$rc" = 0 ] && echo "backup OK: $DEST" || { echo "backup FAILED (status $rc), see the log in $DEST"; exit "$rc"; }
