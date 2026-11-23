"""Parse an SM8250 TZ diag dump (tzdbg_t v9.1, stock Lenovo tz_log.c layout)."""
import struct, sys
d = open(sys.argv[1], "rb").read()
u32 = lambda o: struct.unpack_from("<I", d, o)[0]
magic, ver, ncpu, vmid, boot, reset, intr, ring, rlen, wake = struct.unpack_from("<10I", d, 0)
print(f"magic={magic:#x} ver={ver:#x} cpus={ncpu} ring_off={ring:#x} ring_len={rlen:#x}")
print("reset_info (type, count) per cpu:", [struct.unpack_from("<2I", d, reset + 8 * c) for c in range(8)])
print("boot_info per cpu (wb_entry wb_exit pc_entry pc_exit psci_entry psci_exit):")
for c in range(8):
    print("  cpu", c, struct.unpack_from("<6I", d, boot + 36 * c))  # boot_info64 is 36 bytes? best effort
n = u32(intr)
print("num_interrupts", n)
o = intr + 4
for i in range(min(n, 40)):
    info, avail, spare, num = struct.unpack_from("<HBBI", d, o)
    desc = d[o + 8:o + 24].split(b"\0")[0].decode(errors="replace")
    cnt = struct.unpack_from("<8I", d, o + 24)
    if any(cnt):
        print(f"  int {num:5d} {desc:16s} {cnt}")
    o += 56
print("wakeup HPPIR/AHPPIR:", [struct.unpack_from("<2I", d, wake + 8 * c) for c in range(8)])
wrap, off = struct.unpack_from("<HH", d, ring - 4)
wrap2, off2 = struct.unpack_from("<II", d, ring - 8)
print(f"log_pos v1 wrap={wrap} off={off:#x}; v2 wrap={wrap2} off={off2:#x}")
buf = d[ring:ring + rlen]
text = (buf[off:] + buf[:off]) if wrap else buf[:off]
open(sys.argv[2], "wb").write(text)
print(f"log text {len(text)} bytes -> {sys.argv[2]}")
