#!/usr/bin/env python3
"""List the colour correction matrices (cc13) of a stock CamX tuning binary.

Input: com.qti.tuned.<module>.bin from the stock vendor image (proprietary, stays in
out/desktop/stock-fw/camera/, never in the repo). Heuristic reader of the "QTI Chromatix
Header / Parameter Parser V2.0.0" layout, verified by hand on the q706f modules:

  region header : luxIdx start (f32, 8 B), luxIdx end, gain start, gain end,
                  entry count (u32, 8 B), node id (u32, 8 B)
  cct entry     : cct start (f32, 8 B), cct end (f32, 8 B), c0..c8 (9 x f32, rows R,G,B),
                  k0..k2 (3 x f32) + 8 B  -> 0x48 bytes per entry

Each cc13 instance (one per use case) is printed as groups of entries; for each group the
nearest region header before the instance is listed. Only matrices whose rows sum to ~1
with a dominant diagonal are reported, so a row that does not sum to 1 is shown with a '!'.

Usage: chromatix-ccm.py <tuned.bin> [--all]   (default: first non-identity instance only)
"""
import struct
import sys

data = open(sys.argv[1], 'rb').read()
show_all = '--all' in sys.argv
f32 = lambda o: struct.unpack_from('<f', data, o)[0]
u32 = lambda o: struct.unpack_from('<I', data, o)[0]


def is_ccm(off, tol):
    v = struct.unpack_from('<9f', data, off)
    if any(abs(x) > 5 for x in v):
        return False
    return all(abs(sum(v[3 * r:3 * r + 3]) - 1) < tol and 0.8 < v[4 * r] < 5
               for r in range(3))


def is_entry(off):
    s, e = f32(off - 16), f32(off - 8)
    return 1 <= s < e <= 20000 and s == int(s) and e == int(e)


# Find instance starts: an entry that is a CCM (loose tolerance) and not identity.
offs = [o for o in range(16, len(data) - 36, 4) if is_entry(o) and is_ccm(o, 0.15)]
instances, cur = [], []
for o in offs:
    if cur and o - cur[-1] != 0x48:
        instances.append(cur)
        cur = []
    cur.append(o)
if cur:
    instances.append(cur)
instances = [i for i in instances
             if any(struct.unpack_from('<9f', data, o) != (1, 0, 0, 0, 1, 0, 0, 0, 1) for o in i)]

for inst in instances[:None if show_all else 1]:
    # Region headers: walk back from the first entry over [s,e,gs,ge,count,id] records.
    hdrs, p = [], inst[0] - 16 - 0x30
    while p > 0:
        cnt, nid = u32(p + 0x20), u32(p + 0x28)
        s, e = f32(p), f32(p + 8)
        if 0 < cnt < 32 and 0 < nid < 100000 and 1 <= s <= e <= 2000:
            hdrs.insert(0, (s, e, f32(p + 0x10), f32(p + 0x18), cnt))
            p -= 0x30
            if sum(h[4] for h in hdrs) >= len(inst):
                break
        else:
            break
    print(f'== instance @0x{inst[0]:x}, {len(inst)} entries')
    for h in hdrs:
        print(f'   region luxIdx {h[0]:g}-{h[1]:g} gain {h[2]:g}-{h[3]:g}: {h[4]} entries')
    for o in inst:
        v = struct.unpack_from('<9f', data, o)
        bad = '' if is_ccm(o, 0.03) else ' !'
        print(f'   0x{o:x} cct {f32(o - 16):g}-{f32(o - 8):g}: '
              + ' '.join(f'{x:.4f}' for x in v) + bad)
