#!/usr/bin/env bash
# Copy the pstore (ramoops) records of the previous boot from the tablet to the PC.
# Read-only on the tablet. Works on whichever system ABL started after a failed boot:
#   Ubuntu (slot a, ssh q706f-ubuntu): systemd-pstore moves the records at boot from
#     /sys/fs/pstore to /var/lib/systemd/pstore/<timestamp>/, so both places are read;
#   Ubuntu Touch (slot b, ssh q706f, user phablet): same ramoops region and layout
#     (stock DT ramoops@9e400000, 1 MiB, record/console/ftrace 128 KiB each).
# Must run on the FIRST boot after the failure: the next boot overwrites the console record.
# Usage: scripts/desktop/patches-fp/read-pstore.sh [ssh-host] [label]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HOST="${1:-}"
LABEL="${2:-$(date +%Y%m%d-%H%M%S)}"
if [ -z "$HOST" ]; then
  for h in q706f-ubuntu q706f-wifi q706f; do
    timeout 10 ssh -o BatchMode=yes "$h" true 2>/dev/null && { HOST=$h; break; }
  done
fi
[ -n "$HOST" ] || { echo "tablet not reachable (q706f-ubuntu, q706f-wifi, q706f)"; exit 1; }
DST="$ROOT/out/desktop/kernel-fp-bisect/pstore-$LABEL"
mkdir -p "$DST"
ssh "$HOST" 'sudo sh -c "uname -r; ls -la /sys/fs/pstore /var/lib/systemd/pstore"' > "$DST/listing.txt" 2>&1 || true
ssh "$HOST" 'sudo sh -c "cd / && tar -cf - sys/fs/pstore var/lib/systemd/pstore 2>/dev/null"' > "$DST/pstore.tar" || true
tar -C "$DST" -xf "$DST/pstore.tar" 2>/dev/null || true
echo "host: $HOST -> $DST"
cat "$DST/listing.txt"
# Which kernel wrote each console record (the failed one says 7.3.4-fp).
grep -rah -m1 'Linux version' "$DST" 2>/dev/null | cut -c1-120 || true
f=$(ls -t "$DST"/sys/fs/pstore/console-ramoops* "$DST"/var/lib/systemd/pstore/*/console-ramoops* 2>/dev/null | head -1 || true)
[ -n "$f" ] && { echo "== last 40 lines of $f"; tail -40 "$f"; } || echo "no console-ramoops record"
