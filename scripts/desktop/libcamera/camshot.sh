#!/bin/bash
# Low-memory camera check on the tablet (run as the desktop user).
# For each camera: capture N frames at 1280x960 RGB888, one file per frame, deleting all
# but the newest as it goes (never more than a few frames on disk: /tmp is RAM), then
# print the last AnalogueGain / ExposureTime metadata and the mean of the last frame and
# write a 640px JPEG.  Usage: camshot.sh <outdir> [frames] [cameras...]
set -u
OUT="${1:?outdir}"; N="${2:-40}"; shift 2 2>/dev/null || shift $#
CAMS="${*:-1 2 3}"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p "$OUT"
for c in $CAMS; do
  rm -f "$OUT"/c$c-*.raw
  # Keep the directory small while cam runs.
  ( while sleep 1; do ls -1t "$OUT"/c$c-*.raw 2>/dev/null | tail -n +3 | xargs -r rm -f; done ) &
  pruner=$!
  timeout 120 cam -c "$c" --capture="$N" -s width=1280,height=960,pixelformat=RGB888 \
    --metadata --file="$OUT/c$c-#.raw" >"$OUT/c$c.log" 2>&1
  rc=$?
  kill $pruner 2>/dev/null; wait $pruner 2>/dev/null
  last=$(ls -1t "$OUT"/c$c-*.raw 2>/dev/null | head -1)
  ls -1t "$OUT"/c$c-*.raw 2>/dev/null | tail -n +2 | xargs -r rm -f
  w=1280; h=960
  # q706f wiring: CCI0 bus0 0x36 = ov13b10 (main rear), CCI0 bus1 0x2d = s5k5e9 (second
  # rear), CCI1 bus0 0x36 = ov8856 (front). The cam index order changes between boots.
  path=$(grep -oE "Using camera [^ ]+" "$OUT/c$c.log" | head -1 | cut -d" " -f3)
  case "$path" in
    *cci@ac4f000/i2c-bus@0/camera@36*) sensor=ov13b10-rear-main ;;
    *cci@ac4f000/i2c-bus@1/camera@2d*) sensor=s5k5e9-rear-2 ;;
    *cci@ac50000/i2c-bus@0/camera@36*) sensor=ov8856-front ;;
    *) sensor="unknown:$path" ;;
  esac
  geo="$sensor"
  gain=$(grep -oE 'AnalogueGain = [0-9.]+' "$OUT/c$c.log" | tail -1)
  exp=$(grep -oE 'ExposureTime = [0-9]+' "$OUT/c$c.log" | tail -1)
  helper=$(grep -c 'Failed to create camera sensor helper' "$OUT/c$c.log")
  iso=$(grep -ciE 'isolat|signature' "$OUT/c$c.log")
  mean=n/a
  if [ -n "$last" ] && [ -n "$geo" ]; then
    mean=$(python3 -I -c '
import sys
f,w,h=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
d=open(f,"rb").read(); bpp=len(d)//(w*h); s=n=0
for y in range(0,h,8):
    row=d[y*w*bpp:(y+1)*w*bpp]
    for c in range(3): v=row[c::bpp*7]; s+=sum(v); n+=len(v)
print("%.1f"%(s/n))' "$last" "$w" "$h" 2>&1)
    bpp=$(( $(stat -c %s "$last") / (w*h) )); pf=bgr24; [ "$bpp" = 4 ] && pf=bgr0
    ffmpeg -loglevel error -y -f rawvideo -pixel_format $pf -video_size "${w}x${h}" \
      -i "$last" -vf scale=640:-2 -frames:v 1 "$OUT/c$c.jpg" 2>>"$OUT/c$c.log"
    rm -f "$last"
  fi
  echo "cam$c rc=$rc $geo $gain $exp mean=$mean no-helper-lines=$helper isolated/signature-lines=$iso"
done
