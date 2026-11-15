#!/bin/bash
# Camera AGC check on the tablet (run as root or as ubuntu; captures run as ubuntu).
# For each camera: capture N frames (RGB888, default size), keep the last frame,
# print the last AnalogueGain / ExposureTime metadata, the mean brightness of the last
# frame and whether the IPA ran isolated; write a 640px-wide JPEG per camera.
# Usage: camtest.sh <outdir> [frames]
set -u
OUT="${1:?outdir}"; N="${2:-60}"
mkdir -p "$OUT"; chmod 777 "$OUT"
U="sudo -u ubuntu env XDG_RUNTIME_DIR=/run/user/1000"
[ "$(id -u)" = 1000 ] && U="env XDG_RUNTIME_DIR=/run/user/1000"
for c in 1 2 3; do
  rm -f "$OUT/c$c.bin"
  timeout 180 $U cam -c "$c" --capture="$N" -s pixelformat=RGB888 --metadata \
    --file="$OUT/c$c.bin" >"$OUT/c$c.log" 2>&1
  rc=$?
  geo=$(grep -oE '[0-9]+x[0-9]+-RGB888' "$OUT/c$c.log" | tail -1)
  w=${geo%%x*}; h=${geo#*x}; h=${h%%-*}
  gain=$(grep -oE 'AnalogueGain = [0-9.]+' "$OUT/c$c.log" | tail -1)
  exp=$(grep -oE 'ExposureTime = [0-9]+' "$OUT/c$c.log" | tail -1)
  iso=$(grep -ciE 'isolat|signature' "$OUT/c$c.log")
  mean=$(python3 -I -c '
import sys
d=open(sys.argv[1],"rb").read(); w,h=int(sys.argv[2]),int(sys.argv[3])
stride=len(d)//h
s=0
for y in range(0,h,8):
    row=d[y*stride:y*stride+w*3]
    s+=sum(row[0::7*3])+sum(row[1::7*3])+sum(row[2::7*3])
n=len(range(0,h,8))*len(range(0,w,7))*3
print("%.1f size=%d stride=%d"%(s/n,len(d),stride))' "$OUT/c$c.bin" "$w" "$h" 2>&1)
  ffmpeg -loglevel error -y -f rawvideo -pixel_format bgr24 -video_size "${w}x${h}" \
    -i "$OUT/c$c.bin" -vf scale=640:-2 -frames:v 1 "$OUT/c$c.jpg" 2>>"$OUT/c$c.log"
  echo "cam$c rc=$rc $geo $gain $exp mean=$mean isolated/signature-lines=$iso"
done
