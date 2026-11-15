#!/usr/bin/env bash
# Optional: give the tablet the Windows-11-like GNOME look used on the owner's PC
# (Dash to Panel + ArcMenu + Win11 GTK/shell/icon themes + wallpaper).
# The themes, icons, extensions and wallpaper are third-party works and are NOT in this
# repository: they are copied from a machine that already has them installed (SRC, default
# this host's home directory). Only the panel/menu settings live in win11-look/*.dconf.
# Usage: scripts/desktop/setup-win11-look.sh [ssh-host]      (default: q706f-ubuntu)
# Undo on the tablet: dconf load / < ~/dconf-before-win11.ini, then log out and in.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${1:-q706f-ubuntu}"
SRC="${SRC:-$HOME}"
ITEMS=(
  .local/share/gnome-shell/extensions/dash-to-panel@jderose9.github.com
  .local/share/gnome-shell/extensions/arcmenu@arcmenu.com
  .themes/Win11-round-Dark .themes/Win11-Modern
  .icons/Win11-blue .icons/Win11-blue-dark
  .local/share/windows11-interface
)
for i in "${ITEMS[@]}"; do [ -e "$SRC/$i" ] || { echo "missing on the source machine: $SRC/$i"; exit 1; }; done
tar -C "$SRC" -cf - "${ITEMS[@]}" | ssh "$HOST" 'cd ~ && tar -xf -'
tar -C "$HERE/win11-look" -cf - dash-to-panel.dconf arcmenu.dconf | ssh "$HOST" 'cd /tmp && tar -xf -'
ssh "$HOST" '
  set -e
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends gnome-shell-extensions dmz-cursor-theme >/dev/null
  export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
  [ -f ~/dconf-before-win11.ini ] || dconf dump / > ~/dconf-before-win11.ini
  # Dash to Panel keys its per-monitor settings by "<vendor>-<serial>" of the display.
  MON=$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
        --method org.gnome.Mutter.DisplayConfig.GetCurrentState | python3 -c "
import re,sys
m=re.search(r\"\(\(\x27[^\x27]*\x27, \x27([^\x27]*)\x27, \x27[^\x27]*\x27, \x27([^\x27]*)\x27\)\", sys.stdin.read())
print(m.group(1)+\"-\"+m.group(2))")
  sed "s#@MONITOR@#$MON#g" /tmp/dash-to-panel.dconf | dconf load /org/gnome/shell/extensions/dash-to-panel/
  sed "s#/home/ubuntu#$HOME#g" /tmp/arcmenu.dconf | dconf load /org/gnome/shell/extensions/arcmenu/
  gsettings set org.gnome.desktop.interface gtk-theme Win11-round-Dark
  gsettings set org.gnome.desktop.interface icon-theme Win11-blue-dark
  gsettings set org.gnome.desktop.interface cursor-theme DMZ-White
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  gsettings set org.gnome.desktop.interface accent-color blue
  gsettings set org.gnome.desktop.wm.preferences button-layout ":minimize,maximize,close"
  W="file://$HOME/.local/share/windows11-interface/windows11-blue.jpg"
  gsettings set org.gnome.desktop.background picture-uri "$W"
  gsettings set org.gnome.desktop.background picture-uri-dark "$W"
  dconf write /org/gnome/shell/extensions/user-theme/name "\"Win11-Modern\""
  gsettings set org.gnome.shell disabled-extensions "[\"ubuntu-dock@ubuntu.com\"]"
  gsettings set org.gnome.shell enabled-extensions "[\"ding@rastersoft.com\", \"tiling-assistant@ubuntu.com\", \"web-search-provider@ubuntu.com\", \"osk-button@q706f\", \"ubuntu-appindicators@ubuntu.com\", \"user-theme@gnome-shell-extensions.gcampax.github.com\", \"dash-to-panel@jderose9.github.com\", \"arcmenu@arcmenu.com\"]"
  echo "done: log out and in (or restart gdm) for the new extensions to load"'
