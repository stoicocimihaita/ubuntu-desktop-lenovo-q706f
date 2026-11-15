#!/bin/bash
# Set up the SLPI sensors (accelerometer, ambient light, compass) on a running
# q706f Ubuntu desktop rootfs, over ssh.
#
#   hexagonrpcd (Ubuntu archive)  serves the DSP its files over FastRPC
#   libssc (source, pinned)       talks to the Qualcomm Sensor Core over QRTR
#   iio-sensor-proxy 3.9 (source, pinned, built with -Dssc-support=enabled)
#                                 installed next to the archive package in
#                                 /usr/local; a systemd drop-in switches ExecStart
#
# Usage: scripts/desktop/setup-sensors.sh [ssh-host]      (default: q706f-ubuntu)
#   HEXAGONFS=<dir>  directory with dsp/ acdb/ sensors/ socinfo/ for this tablet
#                    (default: hexagonfs/ of the silime firmware clone).
#                    Proprietary; copied at install time, never kept in the repo.
#
# Nothing here touches partitions, the kernel or the boot image, and it does not
# reboot the tablet.
set -euo pipefail

HOST=${1:-q706f-ubuntu}
HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY=$HERE/overlay
PATCH=$HERE/sensors/iio-sensor-proxy-3.9-start-polling-for-early-claims.patch
# Applied on top of $PATCH: lets Mutter learn about the accelerometer (auto-rotation).
PATCH2=$HERE/sensors/iio-sensor-proxy-3.9-broadcast-sensor-presence.patch
HEXAGONFS=${HEXAGONFS:-${MAIN_REPO:-$HERE/../..}/sources/lenovo-sm8250-q706f-firmware/hexagonfs}
FW_DEST=/usr/share/qcom/sm8250/Lenovo/q706f

LIBSSC_URL=https://codeberg.org/DylanVanAssche/libssc.git
LIBSSC_COMMIT=0cf77b93b55752da34dca2dcecc06fca8665184b   # v0.4.4
ISP_URL=https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git
ISP_COMMIT=0085ddf8ecb173a1c5fcf2344aa40e561125354f      # 3.9

OVERLAY_FILES=(
  etc/systemd/system/hexagonrpcd.service.d/q706f.conf
  etc/systemd/system/iio-sensor-proxy.service.d/q706f-ssc.conf
  etc/udev/rules.d/81-libssc-lenovo-q706f.rules
  usr/local/libexec/q706f-wait-ssc
)

for d in dsp/sdsp sensors/config sensors/registry; do
  [ -d "$HEXAGONFS/$d" ] || { echo "missing $HEXAGONFS/$d" >&2; exit 1; }
done
[ -f "$PATCH" ] || { echo "missing $PATCH" >&2; exit 1; }

echo "== [1/5] packages (archive)"
# --no-install-recommends is REQUIRED: hexagonrpcd Recommends droid-juicer, which
# pulls in qcom-phone-utils + qbootctl + initramfs-tools. droid-juicer.service
# ends with ExecStartPost=/usr/sbin/reboot and qbootctl.service rewrites the
# A/B slot flags in the GPT as soon as it is installed.
ssh "$HOST" 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  hexagonrpcd iio-sensor-proxy \
  git ca-certificates meson ninja-build gcc libc6-dev pkg-config \
  libglib2.0-dev libqmi-glib-dev libprotobuf-c-dev protobuf-c-compiler \
  protobuf-compiler python3-dev libgudev-1.0-dev libpolkit-gobject-1-dev \
  systemd-dev libudev-dev >/dev/null
  for p in droid-juicer qbootctl qcom-phone-utils; do
    if dpkg -s $p >/dev/null 2>&1; then echo "ERROR: $p is installed, remove it first" >&2; exit 1; fi
  done'

echo "== [2/5] overlay files"
tar -C "$OVERLAY" --owner=0 --group=0 -cf - "${OVERLAY_FILES[@]}" |
  ssh "$HOST" 'sudo tar -C / -xf - --no-same-owner --no-overwrite-dir'

echo "== [3/5] DSP files -> $FW_DEST"
tar -C "$HEXAGONFS" --owner=0 --group=0 -cf - . |
  ssh "$HOST" "sudo mkdir -p $FW_DEST && sudo tar -C $FW_DEST -xf - --no-same-owner &&
               sudo chown -R root:root /usr/share/qcom && sudo chmod -R a+rX,go-w /usr/share/qcom"

echo "== [4/5] build libssc + iio-sensor-proxy"
scp -q "$PATCH" "$HOST:/tmp/isp-early-claims.patch"
scp -q "$PATCH2" "$HOST:/tmp/isp-broadcast-presence.patch"
ssh "$HOST" "LIBSSC_URL=$LIBSSC_URL LIBSSC_COMMIT=$LIBSSC_COMMIT ISP_URL=$ISP_URL ISP_COMMIT=$ISP_COMMIT bash -s" <<'EOF'
set -euo pipefail
mkdir -p ~/src && cd ~/src

fetch() {  # dir url commit
  [ -d "$1/.git" ] || git clone -q "$2" "$1"
  git -C "$1" fetch -q --tags origin
  git -C "$1" checkout -q -f "$3"
  [ "$(git -C "$1" rev-parse HEAD)" = "$3" ]
}

fetch libssc "$LIBSSC_URL" "$LIBSSC_COMMIT"
rm -rf libssc/build
meson setup libssc/build libssc --prefix=/usr/local --libdir=lib --buildtype=release >/dev/null
ninja -C libssc/build >/dev/null
sudo ninja -C libssc/build install >/dev/null
sudo ldconfig

fetch iio-sensor-proxy "$ISP_URL" "$ISP_COMMIT"
git -C iio-sensor-proxy apply /tmp/isp-early-claims.patch
git -C iio-sensor-proxy apply /tmp/isp-broadcast-presence.patch
rm -rf iio-sensor-proxy/build
meson setup iio-sensor-proxy/build iio-sensor-proxy --prefix=/usr/local \
  --buildtype=release -Dssc-support=enabled >/dev/null
ninja -C iio-sensor-proxy/build src/iio-sensor-proxy >/dev/null
# Only the daemon: D-Bus policy, polkit action, base udev rules and
# monitor-sensor keep coming from the Ubuntu iio-sensor-proxy package.
sudo install -D -m755 iio-sensor-proxy/build/src/iio-sensor-proxy /usr/local/libexec/iio-sensor-proxy
ldd /usr/local/libexec/iio-sensor-proxy | grep -q libssc
EOF

echo "== [5/5] services"
ssh "$HOST" 'set -e
sudo systemctl daemon-reload
sudo udevadm control --reload
sudo udevadm trigger -s misc
sudo udevadm settle
sudo systemctl enable hexagonrpcd.service >/dev/null 2>&1
sudo systemctl restart hexagonrpcd.service
sudo systemctl restart iio-sensor-proxy.service
systemctl is-active hexagonrpcd.service iio-sensor-proxy.service
for s in accelerometer light; do
  timeout 15 /usr/local/bin/ssccli --sensor $s --timeout 3 2>/dev/null | grep -m1 measurement || echo "WARNING: no $s reading"
done
gdbus call --system --dest net.hadess.SensorProxy --object-path /net/hadess/SensorProxy \
  --method org.freedesktop.DBus.Properties.GetAll net.hadess.SensorProxy'
echo "Done. Check in the user session with: monitor-sensor"
