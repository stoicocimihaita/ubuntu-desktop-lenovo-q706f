#!/usr/bin/env bash
# Interactive hardware self-test for Ubuntu on the Lenovo Tab P12 Pro (q706f).
# Runs on the PC; the owner holds the tablet and answers the questions.
#
#   scripts/desktop/tools/q706f-selftest.sh [--steps abcdefg] [ssh-host]
#
#   ssh-host   default q706f-ubuntu (USB, 172.16.42.1); if USB is not available use
#              q706f-vpn (e.g. a VPN) or q706f-wifi.
#   --steps    run only these steps (letters below); every step also asks before it runs.
#
# Steps (each one can be skipped at its prompt):
#   a  speakers    short left-only, then right-only tone at the CURRENT volume
#   b  microphone  5 s pw-record from "Internal microphones", played back; SoundWire errors
#   c  cameras     cam -l, one capture per camera, copied to out/desktop/selftest/<run>/
#   d  keyboard    pogo keyboard detach/attach: SW_TABLET_MODE and input devices
#   e  pen         15 s of Goodix stylus events: max pressure, tilt X/Y, hover
#   f  charger     wall charger: power_supply values every 5 s for 2 minutes
#   g  rotation    monitor-sensor for 15 s while the tablet is rotated
#
# What the script changes on the tablet: nothing, apart from playing/recording audio,
# capturing camera frames and writing its scratch files in /tmp/q706f-selftest (removed at
# the end). It never changes the volume, never touches UCM or the amplifier mixer controls
# ("Digital PCM Volume" cap, rule R8), never writes to sysfs, never suspends the tablet.
# sudo is used only as "sudo -n dmesg" (read-only) and skipped when it would ask a password.
# Results: a summary table on the terminal and out/desktop/selftest/<run>/summary.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STEPS_ALL="abcdefg"
STEPS="$STEPS_ALL"
HOST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --steps) STEPS="${2:?--steps needs letters, e.g. --steps ab}"; shift 2 ;;
    --steps=*) STEPS="${1#--steps=}"; shift ;;
    -h|--help) sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) HOST="$1"; shift ;;
  esac
done
HOST="${HOST:-q706f-ubuntu}"
RUN="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/out/desktop/selftest/$RUN"
RT=/tmp/q706f-selftest                     # scratch directory on the tablet
SSHO=(-o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o BatchMode=yes)
# User session environment for PipeWire / D-Bus clients started over ssh.
ENVP='export XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus;'

declare -A RES
ORDER=()
result() { RES[$1]="$2|$3"; ORDER+=("$1"); }   # $1 step name, $2 PASS/FAIL/SKIP/INFO/WARN, $3 note

# Remote command with a local timeout. $1 = seconds, $2 = shell snippet (run by bash on the tablet).
r() { local t="$1"; shift; timeout --foreground "$t" ssh "${SSHO[@]}" "$HOST" "$ENVP $*"; }
rh() { local t="$1" h="$2"; shift 2; timeout --foreground "$t" ssh "${SSHO[@]}" "$h" "$ENVP $*"; }

ask() {  # $1 prompt; answer (lower case) in REPLY
  printf '%s ' "$1" >&2
  IFS= read -r REPLY </dev/tty || { echo; echo "no terminal: this test needs a person" >&2; exit 1; }
  REPLY="$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')"
}
want() {  # $1 letter, $2 title. Returns 0 when the step should run.
  case "$STEPS" in *"$1"*) ;; *) return 1 ;; esac
  printf '\n==== (%s) %s\n' "$1" "$2"
  ask "Run this step? [Y/n/q]"
  case "$REPLY" in q) finish; exit 0 ;; n|s|skip) result "$2" SKIP "skipped by the owner"; return 1 ;; esac
  return 0
}
pause() { ask "$1 - press Enter"; }

finish() {
  r 15 "rm -rf $RT" >/dev/null 2>&1 || true
  mkdir -p "$OUT"
  {
    printf '\nq706f self-test %s  host %s  kernel %s\n' "$RUN" "$HOST" "${KREL:-?}"
    printf '%-12s %-5s %s\n' "STEP" "RES" "NOTE"
    printf '%-12s %-5s %s\n' "------------" "-----" "----------------------------------------"
    local k
    for k in "${ORDER[@]}"; do printf '%-12s %-5s %s\n' "$k" "${RES[$k]%%|*}" "${RES[$k]#*|}"; done
  } | tee "$OUT/summary.txt"
  printf '\nfiles: %s\n' "$OUT"
}

mkdir -p "$OUT"
echo "q706f self-test: host $HOST, results in $OUT"
if ! KREL="$(r 15 'uname -r')"; then
  echo "ERROR: cannot reach $HOST over ssh (key login, 8 s timeout)." >&2
  [ "$HOST" = q706f-ubuntu ] && echo "Hint: without the USB cable try: $0 q706f-vpn" >&2
  exit 1
fi
r 15 "mkdir -p $RT"
echo "kernel $KREL"
if ! r 10 'pw-cli info 0 >/dev/null 2>&1'; then
  echo "WARNING: no PipeWire in the user session (nobody logged in?): audio steps will fail"
fi

# ------------------------------------------------------------------------- (a) speakers
if want a speakers; then
  # 1.5 s, 660 Hz, -14 dBFS, 50 ms fades, 48 kHz S16 stereo, one channel silent.
  r 20 "python3 - $RT" <<'PY'
import math, struct, sys, wave
d = sys.argv[1]; rate = 48000; n = int(rate * 1.5); amp = 0.2 * 32767; fade = int(rate * 0.05)
for side in ("left", "right"):
    w = wave.open("%s/tone-%s.wav" % (d, side), "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    fr = bytearray()
    for i in range(n):
        g = min(1.0, i / fade, (n - 1 - i) / fade)
        s = int(amp * g * math.sin(2 * math.pi * 660 * i / rate))
        fr += struct.pack("<hh", s if side == "left" else 0, s if side == "right" else 0)
    w.writeframes(bytes(fr)); w.close()
PY
  echo "default output and its CURRENT volume (not changed by this script):"
  r 10 'wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -m1 node.description; wpctl get-volume @DEFAULT_AUDIO_SINK@' || true
  echo "Hold the tablet in landscape, screen towards you, as the desktop is shown."
  heard=()
  for side in left right; do
    pause "Playing a short tone on the ${side^^} channel"
    r 15 "timeout 10 pw-play $RT/tone-$side.wav" || echo "(pw-play failed)"
    ask "Where did you hear it? [l]eft / [r]ight / [b]oth / [n]othing:"
    heard+=("${REPLY:0:1}")
  done
  case "${heard[0]}${heard[1]}" in
    lr) result speakers PASS "left->left, right->right" ;;
    rl) result speakers FAIL "channels swapped (left tone heard right)" ;;
    nn) result speakers FAIL "no sound on either channel" ;;
    *)  result speakers FAIL "left tone: ${heard[0]:-?}, right tone: ${heard[1]:-?} (l/r/b/n)" ;;
  esac
fi

# ----------------------------------------------------------------------- (b) microphone
if want b microphone; then
  # wpctl prints object ids; pw-record wants the node name (or serial).
  src="$(r 10 'id=$(wpctl status 2>/dev/null | grep -m1 "Internal microphones" | grep -oE "[0-9]+\." | head -n1 | tr -d .)
    [ -n "$id" ] || exit 0
    n=$(wpctl inspect "$id" 2>/dev/null | sed -n "s/.*node\.name = \"\(.*\)\"/\1/p" | head -n1)
    echo "${n:-$id}"')"
  if [ -z "$src" ]; then
    result microphone FAIL "no 'Internal microphones' source in PipeWire (q706f-audio-settle?)"
  else
    pause "Speak normally towards the tablet for 5 seconds after Enter"
    r 20 "timeout -s INT 5 pw-record --target $src --rate 48000 --channels 2 --format s16 $RT/mic.wav" || true
    lvl="$(r 15 "python3 - $RT/mic.wav" <<'PY'
import math, struct, sys, wave
try:
    w = wave.open(sys.argv[1]); n = w.getnframes(); ch = w.getnchannels()
    data = struct.unpack("<%dh" % (n * ch), w.readframes(n))
except Exception as e:
    print("no-recording"); sys.exit(0)
out = []
for c in range(ch):
    s = data[c::ch]
    rms = math.sqrt(sum(x * x for x in s) / max(1, len(s)))
    out.append("ch%d %.1f dBFS" % (c + 1, 20 * math.log10(max(rms, 1) / 32768)))
print("%.1f s, RMS " % (n / max(1, w.getframerate())) + ", ".join(out))
PY
)"
    echo "recording: ${lvl:-none}"
    r 15 "cat $RT/mic.wav" > "$OUT/mic.wav" 2>/dev/null || true
    pause "Playing the recording back"
    r 15 "timeout 10 pw-play $RT/mic.wav" || echo "(pw-play failed)"
    ask "Did you hear your voice clearly? [y/n]"
    ok="$REPLY"
    sw="$(r 15 'd=$(sudo -n dmesg 2>/dev/null || dmesg 2>/dev/null) || exit 0; [ -n "$d" ] || exit 0
      e=$(printf "%s\n" "$d" | grep -iE "soundwire|swr|qcom-soundwire" | grep -ciE "error|fail|mismatch|timeout")
      m=$(printf "%s\n" "$d" | grep -ciE "ports mismatch")
      echo "$e errors ($m port mismatch)"')"
    sw="${sw:-n/a (dmesg needs sudo)}"
    case "$ok" in
      y*) result microphone PASS "${lvl:-?}; dmesg SoundWire: $sw" ;;
      *)  result microphone FAIL "owner did not hear it; ${lvl:-no recording}; dmesg SoundWire: $sw" ;;
    esac
  fi
fi

# -------------------------------------------------------------------------- (c) cameras
if want c cameras; then
  list="$(r 30 'timeout 20 cam -l 2>&1')"
  printf '%s\n' "$list" | tee "$OUT/cam-list.txt"
  ids="$(printf '%s\n' "$list" | sed -n 's/^\([0-9][0-9]*\): .*/\1/p')"
  n=0; got=0; notes=""
  for i in $ids; do
    n=$((n + 1))
    # 5 frames so auto-exposure settles; the file has no '#', so the last frame is kept.
    if r 45 "timeout 30 cam -c $i --capture=5 -s role=viewfinder,width=1280,height=720,pixelformat=BGR888 --file=$RT/cam$i.ppm >$RT/cam$i.log 2>&1 && test -s $RT/cam$i.ppm"; then
      r 30 "cat $RT/cam$i.ppm" > "$OUT/cam$i.ppm" && got=$((got + 1)) && notes="$notes cam$i.ppm"
    elif r 45 "timeout 30 cam -c $i --capture=5 --file=$RT/cam$i.raw >$RT/cam$i.log 2>&1 && test -s $RT/cam$i.raw"; then
      r 30 "cat $RT/cam$i.raw" > "$OUT/cam$i.raw" && got=$((got + 1)) && notes="$notes cam$i.raw(native format)"
    else
      notes="$notes cam$i:failed"
    fi
    r 10 "cat $RT/cam$i.log" > "$OUT/cam$i.log" 2>/dev/null || true
  done
  if [ "$n" = 0 ]; then
    result cameras FAIL "cam -l lists no camera"
  else
    echo "Images copied to $OUT (open them on the PC)."
    ask "Do the copied images show a real picture? [y/n/s=not checked]"
    case "$REPLY" in
      y*) st=PASS ;; n*) st=FAIL ;; *) st=INFO ;;
    esac
    [ "$got" = "$n" ] || st=FAIL
    result cameras "$st" "$got/$n captured:$notes"
  fi
fi

# ------------------------------------------------------------------- (d) pogo keyboard
# Prints "t=<s> tablet_mode=<devices> kbd_devices=<n>" whenever something changes, for 60 s.
# Read-only: /proc/bus/input/devices and "evtest --query" (no grab, no events consumed).
KBD_WATCH="$(cat <<'EOF'
sw_devs() {   # event nodes whose switch bitmap has bit 1 (SW_TABLET_MODE)
  awk '/^H: Handlers=/ { h = $0 }
       /^B: SW=/ { x = substr($2, 4); d = substr(x, length(x), 1)
                   if (d ~ /[2367abefABEF]/ && match(h, /event[0-9]+/)) print substr(h, RSTART, RLENGTH) }' \
    /proc/bus/input/devices 2>/dev/null
}
state() {
  s=""
  for e in $(sw_devs); do
    timeout 2 evtest --query "/dev/input/$e" EV_SW SW_TABLET_MODE 2>/dev/null; rc=$?
    case $rc in 10) s="$s$e:1 " ;; 0) s="$s$e:0 " ;; *) s="$s$e:? " ;; esac
  done
  k=$(grep -ciE '^N: Name=.*(keyboard dock|17EF:6127)' /proc/bus/input/devices)
  echo "tablet_mode=${s:-none} kbd_devices=$k"
}
t0=$(date +%s); end=$((t0 + 60)); last=""
while [ "$(date +%s)" -lt "$end" ]; do
  cur=$(state)
  if [ "$cur" != "$last" ]; then echo "t=$(( $(date +%s) - t0 )) $cur"; last="$cur"; fi
  sleep 1
done
EOF
)"
if want d keyboard; then
  echo "During the next 60 s: DETACH the pogo keyboard, wait ~5 s, ATTACH it again, wait ~5 s."
  pause "Start with the keyboard attached"
  printf '%s\n' "$KBD_WATCH" | r 75 bash -s | tee "$OUT/keyboard.txt"
  ons="$(grep -c ':1 ' "$OUT/keyboard.txt" || true)"; offs="$(grep -c ':0 ' "$OUT/keyboard.txt" || true)"
  kd="$(sed -n 's/.*kbd_devices=\([0-9]*\).*/\1/p' "$OUT/keyboard.txt" | sort -u | tr '\n' ' ')"
  ask "With the keyboard attached: do typing and the touchpad work? [y/n/s=not tried]"
  typ="$REPLY"
  if [ "$ons" -gt 0 ] && [ "$offs" -gt 0 ]; then st=PASS; else st=FAIL; fi
  case "$typ" in n*) st=FAIL ;; esac
  result keyboard "$st" "SW_TABLET_MODE on-states $ons, off-states $offs; keyboard devices seen: ${kd:-?}; typing/touchpad: ${typ:-?}"
fi

# ---------------------------------------------------------------------------- (e) pen
if want e pen; then
  r 10 'cat /proc/bus/input/devices' > "$OUT/input-devices.txt" 2>/dev/null || true
  ev="$(awk '/^N: Name=/ { n = $0 }
             /^H: Handlers=/ { if (n ~ /Goodix Berlin Stylus/ && match($0, /event[0-9]+/)) { print substr($0, RSTART, RLENGTH); exit } }' \
        "$OUT/input-devices.txt")"
  if [ -z "$ev" ]; then
    result pen FAIL "no 'Goodix Berlin Stylus' input device"
  else
    echo "Device /dev/input/$ev. For 15 s: hover above the screen, touch lightly, press hard,"
    echo "then tilt the pen left/right and towards/away from you while touching."
    pause "Start"
    r 30 "S=''; [ -r /dev/input/$ev ] || S='sudo -n'; timeout -s INT 15 \$S stdbuf -oL evtest /dev/input/$ev" > "$OUT/pen-evtest.txt" 2>&1 || true
    sum="$(awk '
      /^Event: .*\(ABS_PRESSURE\), value/ {v=$NF+0; if (v>mp) mp=v; np++}
      /^Event: .*\(ABS_TILT_X\), value/   {tx[$NF]=1}
      /^Event: .*\(ABS_TILT_Y\), value/   {ty[$NF]=1}
      /^Event: .*\(BTN_TOOL_PEN\), value 1/ {hov++}
      /^Event: .*\(BTN_TOUCH\), value 1/  {tch++}
      /Event code 26 \(ABS_TILT_X\)/ {captx=1}
      END {nx=0; for (k in tx) nx++; ny=0; for (k in ty) ny++;
           printf "%d %d %d %d %d %d %d\n", mp, np, nx, ny, hov, tch, captx}' "$OUT/pen-evtest.txt")"
    read -r mp np nx ny hov tch captx <<<"$sum"
    note="max pressure $mp ($np events), tilt X $nx values, tilt Y $ny values, proximity-in $hov, touches $tch"
    [ "$captx" = 1 ] || note="$note, device has no ABS_TILT_X"
    if [ "$mp" -gt 0 ] && [ "$nx" -gt 1 ] && [ "$ny" -gt 1 ] && [ "$hov" -gt 0 ]; then st=PASS; else st=FAIL; fi
    result pen "$st" "$note"
  fi
fi

# ------------------------------------------------------------------------ (f) charger
# Read-only sampling of /sys/class/power_supply and the thermal zones, 25 samples 5 s apart.
CHG_SAMPLE="$(cat <<'EOF'
rd() { cat "$1" 2>/dev/null || echo -; }
CHG=""; BAT=""
for p in /sys/class/power_supply/*; do
  [ "$(rd $p/scope)" = Device ] && continue     # pen / Bluetooth device batteries
  case "$(rd $p/type)" in USB|Mains) [ -z "$CHG" ] && CHG=$p ;; Battery) [ -z "$BAT" ] && BAT=$p ;; esac
done
[ -d /sys/class/power_supply/pm8150b-charger ] && CHG=/sys/class/power_supply/pm8150b-charger
[ -d /sys/class/power_supply/bq27541-0 ] && BAT=/sys/class/power_supply/bq27541-0
echo "# charger=${CHG##*/} battery=${BAT##*/} (uA, uV, 0.1 C; zone = hottest thermal zone, m C)"
echo "t,online,usb_type,status,icl_current_max,input_current_limit,chg_current_now,chg_voltage_now,bat_status,capacity,bat_voltage_now,bat_current_now,bat_temp,zone_max"
i=0
while [ $i -le 24 ]; do
  z=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -n1)
  echo "$((i*5)),$(rd $CHG/online),$(rd $CHG/usb_type | tr -d ,),$(rd $CHG/status),$(rd $CHG/current_max),$(rd $CHG/input_current_limit),$(rd $CHG/current_now),$(rd $CHG/voltage_now),$(rd $BAT/status),$(rd $BAT/capacity),$(rd $BAT/voltage_now),$(rd $BAT/current_now),$(rd $BAT/temp),${z:--}"
  i=$((i+1)); [ $i -le 24 ] && sleep 5
done
EOF
)"
if want f charger; then
  ch="$HOST"
  hn="$(ssh -G "$HOST" 2>/dev/null | awk '$1=="hostname"{print $2; exit}')"
  case "$hn" in
    172.16.42.*)
      echo "$HOST goes over the USB cable, which the wall charger replaces."
      ask "ssh host reachable over Wi-Fi for this step (e.g. q706f-vpn, q706f-wifi; empty = skip):"
      ch="$REPLY" ;;
  esac
  if [ -z "$ch" ]; then
    result charger SKIP "no Wi-Fi/VPN ssh host given"
  elif ! rh 15 "$ch" true; then
    result charger FAIL "cannot reach $ch"
  else
    pause "Plug the WALL charger into the tablet now (stay next to the tablet for 2 minutes)"
    printf '%s\n' "$CHG_SAMPLE" | rh 150 "$ch" bash -s | tee "$OUT/charger.csv"
    sum="$(awk -F, '!/^#/ && $1 ~ /^[0-9]+$/ {
        n++; if ($5+0>icl) icl=$5+0; if ($6+0>il) il=$6+0; if ($7+0>ci) ci=$7+0;
        if ($11+0>vb) vb=$11+0; if ($13!="-" && $13+0>tb) tb=$13+0; if ($14+0>zm) zm=$14+0;
        st[$4"/"$9]=1; if ($2=="1") on++ }
      END { s=""; for (k in st) s=s k " ";
        printf "%d|%d|%d|%d|%d|%d|%d|%d|%s\n", n, on, icl, il, ci, vb, tb, zm, s }' "$OUT/charger.csv")"
    IFS='|' read -r n on icl il ci vb tb zm sts <<<"$sum"
    note="$n samples, online $on; ICL max $((icl/1000)) mA (input_current_limit $((il/1000)) mA); charger current max $((ci/1000)) mA; battery max $((vb/1000)) mV, $((tb/10)).$((tb%10)) C; hottest zone $((zm/1000)) C; status: $sts"
    st=INFO
    [ "$on" -gt 0 ] || st=FAIL
    [ "$vb" -le 4260000 ] || { st=FAIL; note="$note; OVER 4.26 V"; }
    [ "$tb" -lt 450 ] || { [ "$st" = FAIL ] || st=WARN; note="$note; battery >= 45 C"; }
    result charger "$st" "$note"
    echo "Unplug the wall charger and reconnect the USB cable if you need USB ssh again."
  fi
fi

# ----------------------------------------------------------------------- (g) rotation
if want g rotation; then
  echo "Rotation lock must be off. For 15 s: turn the tablet to portrait, back to landscape,"
  echo "then upside down."
  pause "Start"
  r 30 'timeout -s INT 15 stdbuf -oL monitor-sensor 2>&1' | tee "$OUT/rotation.txt"
  ors="$(grep -oE 'orientation( changed)?: [a-z-]+' "$OUT/rotation.txt" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
  nor="$(printf '%s' "$ors" | wc -w)"
  ask "Did the screen follow the rotation? [y/n/s=not watched]"
  case "$REPLY" in n*) st=FAIL ;; *) if [ "$nor" -ge 2 ]; then st=PASS; else st=FAIL; fi ;; esac
  grep -q 'Has accelerometer' "$OUT/rotation.txt" || { st=FAIL; ors="no accelerometer reported"; }
  result rotation "$st" "orientations seen: ${ors:-none}; screen followed: ${REPLY:-?}"
fi

finish
