#!/usr/bin/env bash
# Build the Ubuntu 26.04 (resolute) arm64 desktop rootfs tree for q706f.
# Runs mmdebstrap in a privileged x86_64 container (foreign maintainer scripts via
# the host's qemu-aarch64 binfmt). Output: out/desktop/rootfs/ (root-owned tree).
# Usage: scripts/desktop/build-rootfs.sh [minimal|desktop]   (default: desktop)
# Env (see docs/REPRODUCERE-ROOTFS.md):
#   BRINGUP=1          development image: password-less sudo, GDM autologin, gnome-shell
#                      --unsafe-mode, unencrypted default keyring. Default 0: none of these.
#   ROOTFS_NAME=name   output tree out/desktop/<name> (default: rootfs)
#   TIMEZONE=Area/City system timezone (default: Europe/Bucharest)
#   USER_PASSWORD=...  initial password of the user "ubuntu" (default: ubuntu)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FLAVOR="${1:-desktop}"
SUITE=resolute
MIRROR=http://ports.ubuntu.com/ubuntu-ports
PKGS="systemd-sysv,udev,dbus,sudo,openssh-server,network-manager,iproute2,iputils-ping,kmod,e2fsprogs,apparmor,locales,ca-certificates,nano,less,linux-firmware,wireless-regdb,bluez,rfkill,dnsmasq-base,zstd,alsa-utils,alsa-ucm-conf,evtest,usbutils,pciutils,i2c-tools,systemd-timesyncd,libinput-tools,iw,avahi-daemon"
[ "$FLAVOR" = desktop ] && PKGS="$PKGS,ubuntu-desktop-minimal,mesa-utils,mesa-vulkan-drivers,pipewire-audio,gnome-terminal,iio-sensor-proxy,epiphany-browser,xournalpp,gnome-screenshot,libcamera-tools,libcamera-ipa,gstreamer1.0-libcamera,pipewire-libcamera,gnome-snapshot,systemd-zram-generator,rtkit,fake-hwclock,gnome-keyring,libsecret-tools,freerdp3-sdl,gnome-connections,libnss-mdns,avahi-utils,curl,gnome-shell-extensions,systemd-oomd,gnome-system-monitor,gnome-software,gnome-software-plugin-flatpak,flatpak,x42-plugins,libspa-0.2-modules-extra,lilv-utils,jq"

BRINGUP="${BRINGUP:-0}"
ROOTFS_NAME="${ROOTFS_NAME:-rootfs}"
case "$BRINGUP" in 0|1) ;; *) echo "BRINGUP must be 0 or 1" >&2; exit 1 ;; esac
case "$ROOTFS_NAME" in ""|.*|*/*) echo "ROOTFS_NAME must be a plain directory name under out/desktop" >&2; exit 1 ;; esac
echo "rootfs: out/desktop/$ROOTFS_NAME  flavor=$FLAVOR  BRINGUP=$BRINGUP"

mkdir -p "$ROOT/out/desktop"
docker run --rm --privileged -v "$ROOT:/work" -e FLAVOR="$FLAVOR" -e BRINGUP="$BRINGUP" \
  -e TIMEZONE="${TIMEZONE:-Europe/Bucharest}" -e USER_PASSWORD="${USER_PASSWORD:-ubuntu}" \
  -e T="/work/out/desktop/$ROOTFS_NAME" ubuntu:24.04 bash -euc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq mmdebstrap arch-test ubuntu-keyring >/dev/null
  rm -rf "$T"
  mmdebstrap --arch=arm64 --variant=apt --mode=root \
    --components=main,restricted,universe,multiverse \
    --include="'"$PKGS"'" \
    --customize-hook="/work/scripts/desktop/rootfs-customize.sh \"\$1\"" \
    '"$SUITE"' "$T" \
    "deb '"$MIRROR $SUITE"' main restricted universe multiverse" \
    "deb '"$MIRROR $SUITE"'-updates main restricted universe multiverse" \
    "deb '"$MIRROR $SUITE"'-security main restricted universe multiverse"
  du -sh "$T"
'
