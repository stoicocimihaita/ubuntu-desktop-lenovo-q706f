#!/usr/bin/env bash
# Bring the tablet in line with the repo after a measurement, with a short summary.
#
# Usage: scripts/desktop/tools/q706f-sync-tablet.sh [stage...]   (default: power pull push)
#   power  summarise the last suspends from /var/log/q706f-sleep-power.log (mA, CXSD)
#   pull   copy tablet-only helpers into the overlay (q706f-drain, q706f-statediff)
#   push   install the overlay files changed by the 2026-11-20 audit and reload them
# Env: TABLET=q706f-ubuntu (ssh host). Never suspends the tablet, never touches partitions.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OV="$ROOT/scripts/desktop/overlay"
TABLET="${TABLET:-q706f-ubuntu}"
STAGES=("$@"); [ ${#STAGES[@]} -eq 0 ] && STAGES=(power pull push)
say() { printf '== %s\n' "$*"; }

# Files touched by the audit fixes (paths relative to the overlay = to /).
PUSH_FILES=(
  usr/lib/systemd/system-sleep/q706f-sleep
  usr/local/libexec/q706f-screen-keys
  usr/local/sbin/q706f-flash-kernel
  usr/local/sbin/q706f-tablet-mode
  etc/systemd/sleep.conf.d/10-q706f-suspend.conf
  etc/systemd/system/q706f-tablet-mode.service
)

do_power() {
  say "suspends on battery (last 8, from /var/log/q706f-sleep-power.log)"
  ssh "$TABLET" 'tail -n 400 /var/log/q706f-sleep-power.log' | awk '
    function v(k,  i){ for(i=1;i<=NF;i++) if(index($i,k"=")==1) return substr($i,length(k)+2); return "" }
    $4=="pre" && v("usb")=="1" { t0=0; next }
    $4=="pre"  { t0=$1; c0=v("charge_uAh"); x0=v("cxsd"); u0=v("usb"); d0=$2" "$3; next }
    $4=="post" && t0 { dt=$1-t0; if (dt>0) {
        mah=(c0-v("charge_uAh"))/1000; n++
        r[n]=sprintf("%s  %6.1f h  %6.0f mAh  %6.1f mA  cxsd %s->%s  usb=%s", d0, dt/3600, mah,
                     mah/(dt/3600), x0, v("cxsd"), u0) }
      t0=0 }
    END { s=(n>8)?n-7:1; for(i=s;i<=n;i++) print "  " r[i]; if(!n) print "  no pre/post pairs" }'
  echo "   reference: ~47 mA all night in CXSD, ~97 mA without CXSD (usb=1 lines are on the charger)"
}

do_pull() {
  say "pull tablet-only helpers into the overlay"
  for f in q706f-drain q706f-statediff; do
    if ssh "$TABLET" "test -f /usr/local/libexec/$f"; then
      ssh "$TABLET" "cat /usr/local/libexec/$f" > "$OV/usr/local/libexec/$f"
      chmod 755 "$OV/usr/local/libexec/$f"; echo "   $f"
    else
      echo "   $f not on the tablet"
    fi
  done
}

do_push() {
  say "install ${#PUSH_FILES[@]} overlay files"
  tar -C "$OV" --owner=0 --group=0 -cf - "${PUSH_FILES[@]}" |
    ssh "$TABLET" 'sudo tar -C / -xf - --no-same-owner --no-overwrite-dir && sudo systemctl daemon-reload'
  # q706f-screen-keys runs as a user unit in the graphical session.
  ssh "$TABLET" 'systemctl --user restart q706f-screen-keys.service 2>/dev/null || true
    systemctl --user is-active q706f-screen-keys.service; sudo systemctl is-active q706f-tablet-mode.service || true'
  ssh "$TABLET" 'sh -n /usr/lib/systemd/system-sleep/q706f-sleep && echo "   sleep hook syntax ok";
    grep -h . /etc/default/q706f-sleep | grep -v "^#" | sed "s/^/   /"'
}

for s in "${STAGES[@]}"; do "do_$s"; done
