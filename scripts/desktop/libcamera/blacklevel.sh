#!/bin/bash
# Dark-frame black level measurement on the tablet (run as the desktop user, lens
# fully covered, room light as usual). For each camera: capture a few RAW frames
# (simple pipeline raw stream, no SoftISP), keep only the last one, and print the
# per-channel mean/median in 10-bit units and the libcamera 16-bit BlackLevel value.
# The RAW frame is deleted afterwards (one full-size packed frame is 10-17 MB in /tmp).
#
# Usage: blacklevel.sh <outdir> [cameras...]      e.g. blacklevel.sh /tmp/bl 1 2 3
# Optional: CAM=/usr/bin/cam (default) or CAM=/usr/local/bin/cam-upstream
set -u
OUT="${1:?outdir}"; shift
CAMS="${*:-1 2 3}"
CAM="${CAM:-/usr/bin/cam}"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$OUT"
for c in $CAMS; do
  rm -f "$OUT"/d$c-*.bin
  timeout 60 "$CAM" -c "$c" --capture=4 -s role=raw --file="$OUT/d$c-#.bin" \
    >"$OUT/d$c.log" 2>&1
  rc=$?
  last=$(ls -1t "$OUT"/d$c-*.bin 2>/dev/null | head -1)
  ls -1t "$OUT"/d$c-*.bin 2>/dev/null | tail -n +2 | xargs -r rm -f
  path=$(grep -oE "Using camera [^ ]+" "$OUT/d$c.log" | head -1 | cut -d" " -f3)
  case "$path" in
    *cci@ac4f000/i2c-bus@0/camera@36*) sensor=ov13b10 ;;
    *cci@ac4f000/i2c-bus@1/camera@2d*) sensor=s5k5e9 ;;
    *cci@ac50000/i2c-bus@0/camera@36*) sensor=ov8856 ;;
    *) sensor="unknown:$path" ;;
  esac
  # Stream line printed by cam, e.g. "0: 4208x3120-SGRBG10_CSI2P/..."
  geo=$(grep -oE '[0-9]+x[0-9]+-S[A-Z]{4}10_CSI2P' "$OUT/d$c.log" | tail -1)
  if [ -z "$last" ] || [ -z "$geo" ]; then
    echo "cam$c $sensor rc=$rc: no RAW frame or unknown format (see $OUT/d$c.log)"
    rm -f "$last"; continue
  fi
  python3 -I - "$last" "$geo" <<'EOF'
import sys, statistics
f, geo = sys.argv[1], sys.argv[2]
wh, fmt = geo.split('-')
w, h = map(int, wh.split('x'))
d = open(f, 'rb').read()
stride = len(d) // h
order = fmt[1:5]                       # e.g. GRBG: (0,0)=G (0,1)=R (1,0)=B (1,1)=G
ch = {}
for y in range(8, h - 8, 16):          # every 16th row pair, skip borders
    for yy in (y, y + 1):
        row = d[yy * stride: yy * stride + w * 5 // 4]
        for g in range(4, len(row) // 5 - 4, 7):   # sample every 7th group of 4 px
            b = row[g * 5: g * 5 + 5]
            for i in range(4):
                v = (b[i] << 2) | ((b[4] >> (2 * i)) & 3)
                x = g * 4 + i
                idx = (yy % 2) * 2 + (x % 2)
                key = f"{idx}{order[idx]}"     # 0..3 = Bayer position, letter = colour
                ch.setdefault(key, []).append(v)
allv = [v for l in ch.values() for v in l]
mean = sum(allv) / len(allv)
parts = ' '.join(f"{k}:{sum(l)/len(l):.1f}/{statistics.median(l)}" for k, l in sorted(ch.items()))
print(f"  {geo} stride={stride} mean10={mean:.2f} median10={statistics.median(allv)} "
      f"blackLevel16={round(mean * 64)} [{parts}]")
EOF
  echo "^ cam$c $sensor rc=$rc"
  rm -f "$last"
done
