#!/usr/bin/env bash
# Install the GJS OSK on-screen keyboard (GNOME Shell extension, third-party code from
# extensions.gnome.org) for the tablet user and apply the q706f settings. Run on the PC.
# The extension is not part of the rootfs image: installing it is the owner's choice.
# Usage: scripts/desktop/setup-gjs-osk.sh [ssh-host]      (default: q706f-ubuntu)
# The GNOME session is restarted once (open windows close) so the shell sees the extension.
set -euo pipefail
TABLET="${1:-q706f-ubuntu}"
UUID=gjsosk@vishram1123.com
# Version 53 (GNOME 45-50), as served by extensions.gnome.org on 2026-11-13.
URL="https://extensions.gnome.org/download-extension/$UUID.shell-extension.zip?version_tag=74269"
SHA256=38578bfb54880c8fec13e24783406d4c77ad047b5bc205b7a5814dc631231b6d
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fsSL "$URL" -o "$T/gjsosk.zip"
echo "$SHA256  $T/gjsosk.zip" | sha256sum -c - >/dev/null
scp -q "$T/gjsosk.zip" "$TABLET:/tmp/gjsosk.zip"
ssh "$TABLET" '
  set -e
  export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
  UUID=gjsosk@vishram1123.com
  E=$HOME/.local/share/gnome-shell/extensions/$UUID
  if [ ! -d "$E" ]; then
    gnome-extensions install --force /tmp/gjsosk.zip
    sync; sudo systemctl restart gdm3
    for i in $(seq 30); do sleep 2; gnome-extensions info $UUID >/dev/null 2>&1 && break; done
  fi
  S="gsettings --schemadir $E/schemas set org.gnome.shell.extensions.gjsosk"
  $S layout-landscape 5          # Compact US
  $S layout-portrait 8           # Mobile
  $S landscape-width-percent 100
  $S landscape-height-percent 42
  $S portrait-height-percent 32
  $S outer-spacing-px 8
  $S font-size-px 20
  $S round-key-corners true
  $S enable-drag false
  $S enable-key-repeat true
  $S play-sound false
  # Only one keyboard: GNOME'"'"'s own stays off (osk-button@q706f hides its panel button).
  gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false
  gnome-extensions enable $UUID
  gnome-extensions info $UUID | grep -E "Version|State"
'
