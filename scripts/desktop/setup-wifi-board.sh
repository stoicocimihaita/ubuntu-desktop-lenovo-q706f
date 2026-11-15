#!/usr/bin/env bash
# OPTIONAL: build an ath11k board-2.bin that also carries the Lenovo (stock) Wi-Fi
# board data for the QCA6390, as the entry
#   bus=pci,qmi-chip-id=0,qmi-board-id=255,variant=Lenovo_Q706F
# next to the generic linux-firmware entries, which are all kept.
#
# The driver only asks for that entry when the DT has
#   qcom,calibration-variant = "Lenovo_Q706F";
# (patches/0012-q706f-dts-wifi-calibration-variant.patch.needs-approval). Without
# the DT property the generic entry stays in use, so installing the file alone
# changes nothing.
#
# The stock board data is proprietary: it is read at install time from the owner's
# own stock image / backup and must never be committed.
#
# Usage:
#   setup-wifi-board.sh --stock <modem image | bdwlan.elf> [--base <board-2.bin>]
#                       [--variant NAME] [--out FILE] [--install [ssh-host]]
#
#   --stock    FAT image of the "modem" partition (stock firmware or the EDL backup,
#              the file is image/qca6390/bdwlan.elf in it; needs 7z), or the
#              extracted bdwlan.elf itself. Android's cnss2 loads bdwlan.elf when
#              the chip reports board_id 0xff, which is what ath11k logs here.
#   --base     board-2.bin to extend (plain or .zst). Default: fetched from the
#              tablet (/lib/firmware/ath11k/QCA6390/hw2.0/board-2.bin.zst).
#   --install  copy the result to the tablet as
#              /lib/firmware/updates/ath11k/QCA6390/hw2.0/board-2.bin
#              (searched before the packaged file, survives linux-firmware
#              upgrades). Takes effect at the next boot. To undo: delete it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STOCK= BASE= VARIANT=Lenovo_Q706F OUT="$ROOT/out/desktop/wifi-board/board-2.bin"
INSTALL= HOST=q706f-wifi
FWDIR=ath11k/QCA6390/hw2.0
while [ $# -gt 0 ]; do
  case "$1" in
    --stock) STOCK="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --install) INSTALL=1; shift
      if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then HOST="$1"; shift; fi ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$STOCK" ] && [ -f "$STOCK" ] || { echo "--stock <modem image | bdwlan.elf> is required" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$(dirname "$OUT")"

# 1. stock board data
if [ "$(head -c4 "$STOCK" | od -An -tx1 | tr -d ' ')" = 7f454c46 ]; then
  cp "$STOCK" "$TMP/bdwlan.elf"
else
  command -v 7z >/dev/null || { echo "7z is needed to read the modem image" >&2; exit 1; }
  7z e -y -o"$TMP" "$STOCK" image/qca6390/bdwlan.elf >/dev/null
  [ -s "$TMP/bdwlan.elf" ] || { echo "image/qca6390/bdwlan.elf not found in $STOCK" >&2; exit 1; }
fi

# 2. base board-2.bin
if [ -z "$BASE" ]; then
  ssh "$HOST" "cat /lib/firmware/$FWDIR/board-2.bin.zst" > "$TMP/base.zst"
  BASE="$TMP/base.zst"
fi
if [ "$(head -c4 "$BASE" | od -An -tx1 | tr -d ' ')" = 28b52ffd ]; then
  zstd -dqf "$BASE" -o "$TMP/base.bin"
else
  cp "$BASE" "$TMP/base.bin"
fi

# 3. append (or replace) the variant entry
python3 -I - "$TMP/base.bin" "$TMP/bdwlan.elf" "$VARIANT" "$OUT" <<'PY'
import struct, sys
base, bdf, variant, out = sys.argv[1:5]
MAGIC = b"QCA-ATH11K-BOARD\0"
IE_BOARD, IE_NAME, IE_DATA = 0, 0, 1
pad = lambda b: b + b"\0" * (-len(b) % 4)
ie = lambda t, b: struct.pack("<II", t, len(b)) + pad(b)

d = open(base, "rb").read()
if not d.startswith(MAGIC):
    sys.exit("base file is not an ath11k board-2.bin")
data = open(bdf, "rb").read()
if data[:4] != b"\x7fELF" or not 0x8000 < len(data) < 0x40000:
    sys.exit("stock board data does not look like a QCA6390 bdwlan.elf")
name = "bus=pci,qmi-chip-id=0,qmi-board-id=255,variant=%s" % variant

off = (len(MAGIC) + 3) & ~3
res = bytearray(d[:off])
names, replaced = [], 0
while off < len(d):
    t, l = struct.unpack_from("<II", d, off)
    end = off + 8 + ((l + 3) & ~3)
    if end > len(d):
        sys.exit("base board-2.bin is truncated")
    body, o, mine = d[off + 8:off + 8 + l], 0, False
    while t == IE_BOARD and o + 8 <= len(body):
        st, sl = struct.unpack_from("<II", body, o)
        if st == IE_NAME:
            n = body[o + 8:o + 8 + sl].decode("ascii", "replace")
            names.append(n)
            mine = mine or n == name
        o += 8 + ((sl + 3) & ~3)
    if mine:
        replaced += 1
    else:
        res += d[off:end]
    off = end
generic = "bus=pci,qmi-chip-id=0,qmi-board-id=255"
if generic not in names:
    sys.exit("base board-2.bin has no generic '%s' entry" % generic)
res += ie(IE_BOARD, ie(IE_NAME, name.encode()) + ie(IE_DATA, data))
open(out, "wb").write(res)
print("%s: %d entries kept, '%s' %s (%d bytes of board data)" % (
    out, len(names) - replaced, name, "replaced" if replaced else "added", len(data)))
PY

if [ -n "$INSTALL" ]; then
  echo "Installing on $HOST: /lib/firmware/updates/$FWDIR/board-2.bin (used from the next boot)"
  ssh "$HOST" "sudo install -d /lib/firmware/updates/$FWDIR && sudo sh -c 'cat > /lib/firmware/updates/$FWDIR/board-2.bin.new && mv /lib/firmware/updates/$FWDIR/board-2.bin.new /lib/firmware/updates/$FWDIR/board-2.bin'" < "$OUT"
  echo "Undo: ssh $HOST sudo rm /lib/firmware/updates/$FWDIR/board-2.bin"
else
  echo "Not installed (pass --install). The file is proprietary: do not commit it."
fi
