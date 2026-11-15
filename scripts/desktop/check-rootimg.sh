#!/usr/bin/env bash
# Offline check of a root image built by make-rootimg.sh. Read-only: e2fsck -fn plus
# debugfs (no loop device, no root, no mount). Nothing here touches the tablet.
# Usage: scripts/desktop/check-rootimg.sh [image]     (default: out/desktop/ubuntu-desktop.img)
# Exit status 0 only when every check passes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG="${1:-$ROOT/out/desktop/ubuntu-desktop.img}"
PATH="$PATH:/usr/sbin:/sbin"
[ -f "$IMG" ] || { echo "no $IMG"; exit 1; }
command -v debugfs >/dev/null && command -v e2fsck >/dev/null || { echo "e2fsprogs (debugfs, e2fsck) needed"; exit 1; }

echo "== e2fsck -fn"
e2fsck -fn "$IMG" 2>&1 | tail -n 3
[ "${PIPESTATUS[0]}" = 0 ] || { echo "FAIL: e2fsck reports errors"; exit 1; }

exec python3 -I - "$IMG" "$ROOT/scripts/desktop" <<'PY'
import hashlib, os, stat, subprocess, sys, tempfile

img, desk = sys.argv[1], sys.argv[2]
overlay = os.path.join(desk, "overlay")
fails = []

def ok(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        fails.append(what)

def debugfs(cmds):
    with tempfile.NamedTemporaryFile("w", suffix=".dbgfs") as f:
        f.write("\n".join(cmds) + "\n"); f.flush()
        return subprocess.run(["debugfs", "-f", f.name, img], stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL).stdout

def cat(path):
    return subprocess.run(["debugfs", "-R", 'cat "%s"' % path, img], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL).stdout

# Walk the whole filesystem: one debugfs run per directory level ("ls -p" is parseable).
tree = {"/": (0o40755, 0, 0)}          # path -> (mode, uid, gid)
level = ["/"]
while level:
    out = debugfs(['ls -p "%s"' % d for d in level]).decode("utf-8", "surrogateescape")
    nxt, cur = [], None
    for line in out.split("\n"):
        if line.startswith("debugfs: ls -p "):
            cur = line[len('debugfs: ls -p "'):-1]
            continue
        p = line.split("/")
        if cur is None or len(p) < 7 or not p[1].isdigit():
            continue
        name = "/".join(p[5:-2])
        if name in (".", ".."):
            continue
        path = cur.rstrip("/") + "/" + name
        mode = int(p[2], 8)
        tree[path] = (mode, int(p[3]), int(p[4]))
        if stat.S_ISDIR(mode):
            nxt.append(path)
    level = nxt
print("== %d inodes listed" % len(tree))

def exists(p): return p in tree
def under(prefix): return [p for p in tree if p == prefix or p.startswith(prefix + "/")]

info = dict(l.split("=", 1) for l in cat("/etc/q706f-image").decode().split() if "=" in l)
bringup = info.get("BRINGUP")
ok(bringup in ("0", "1"), "/etc/q706f-image present (BRINGUP=%s, built %s)" % (bringup, info.get("BUILD_DATE")))

print("== ownership and modes")
bad = [p for p, (m, u, g) in tree.items() if (u >= 1000 or g >= 1000) and not (p + "/").startswith("/home/")]
ok(not bad, "nothing outside /home owned by a regular user %s" % bad[:5])
bad = [p for p in under("/home/ubuntu") if tree[p][1] != 1000]
ok(exists("/home/ubuntu") and not bad, "/home/ubuntu entirely owned by uid 1000 %s" % bad[:5])
bad = [p for p, (m, u, g) in tree.items() if p.startswith(("/etc/", "/usr/")) and not stat.S_ISLNK(m)
       and m & 0o002 and not m & stat.S_ISVTX]
ok(not bad, "no world-writable file under /etc or /usr %s" % bad[:5])
bad = [p for p, (m, u, g) in tree.items() if p.startswith(("/usr/local/bin/", "/usr/local/sbin/", "/usr/local/libexec/", "/etc/systemd/", "/etc/udev/",
       "/usr/lib/modules/", "/usr/share/gnome-shell/extensions/osk-button@q706f")) and not stat.S_ISLNK(m) and m & 0o020]
ok(not bad, "device files are not group-writable %s" % bad[:5])
ok(tree.get("/etc", (0,))[0] & 0o7777 == 0o755, "/etc is 0755")

print("== overlay (scripts/desktop/overlay) present and identical")
missing, differ, n = [], [], 0
for d, _, files in os.walk(overlay):
    if "__pycache__" in d:
        continue
    for f in files:
        src = os.path.join(d, f); dst = "/" + os.path.relpath(src, overlay); n += 1
        if not exists(dst):
            missing.append(dst)
        elif os.path.islink(src):
            if not stat.S_ISLNK(tree[dst][0]): differ.append(dst)
        elif hashlib.sha256(open(src, "rb").read()).digest() != hashlib.sha256(cat(dst)).digest():
            differ.append(dst)
ok(not missing and not differ, "%d overlay entries (missing %s, different %s)" % (n, missing, differ))
units = [p for p in tree if ".wants/q706f-" in p]
for u in ("system/multi-user.target.wants/q706f-bt-addr.service", "system/multi-user.target.wants/q706f-pen-dock.service",
          "system/multi-user.target.wants/q706f-tablet-mode.service", "system/multi-user.target.wants/q706f-usb-gadget.service",
          "system/multi-user.target.wants/q706f-ssh-hostkeys.service",
          "user/graphical-session.target.wants/q706f-audio-settle.service",
          "user/graphical-session.target.wants/q706f-screen-keys.service"):
    ok("/etc/systemd/" + u in units, "enabled: " + u)
for u in ("multi-user.target.wants/ssh.service", "multi-user.target.wants/NetworkManager.service",
          "multi-user.target.wants/avahi-daemon.service", "sysinit.target.wants/systemd-timesyncd.service",
          "sysinit.target.wants/fake-hwclock-load.service", "timers.target.wants/fake-hwclock-save.timer",
          "bluetooth.target.wants/bluetooth.service", "display-manager.service"):
    ok(exists("/etc/systemd/system/" + u), "enabled: " + u)
ok(exists("/etc/systemd/zram-generator.conf") and exists("/usr/lib/systemd/system-generators/zram-generator"),
   "zram generator and its config")
ok(exists("/etc/fake-hwclock.data"), "fake-hwclock seeded")
ok(not exists("/usr/bin/onboard"), "onboard not installed")

print("== apt safety (rule R6)")
pins = cat("/etc/apt/preferences.d/90-q706f-forbidden").decode("utf-8", "replace")
pinned = {}
for rec in pins.split("\n\n"):
    f = dict(l.split(":", 1) for l in rec.split("\n") if ":" in l and not l.startswith("#"))
    if f.get("Pin-Priority", "").strip() == "-1":
        for p in f.get("Package", "").split():
            pinned[p] = True
ok(all(p in pinned for p in ("qbootctl", "droid-juicer", "qcom-phone-utils", "flash-kernel", "linux-image-*")),
   "forbidden packages pinned to -1 (preferences.d/90-q706f-forbidden)")
norec = cat("/etc/apt/apt.conf.d/90-q706f-no-recommends").decode("utf-8", "replace")
ok('APT::Install-Recommends "false";' in norec, "APT::Install-Recommends false (apt.conf.d/90-q706f-no-recommends)")
status = cat("/var/lib/dpkg/status").decode("utf-8", "replace")
inst = [l.split(":", 1)[1].strip() for l in status.split("\n") if l.startswith("Package:")]
bad = [p for p in inst if p in ("qbootctl", "droid-juicer", "qcom-phone-utils", "flash-kernel")
       or p.startswith(("linux-image-", "linux-modules-", "grub-"))]
ok(not bad, "no forbidden package installed %s" % bad)

print("== GNOME defaults")
comp = cat("/usr/share/glib-2.0/schemas/gschemas.compiled")
ok(b"osk-button@q706f" in comp and b"q706f-remote-pc.desktop" in comp, "gschema override compiled (extension + launcher in gschemas.compiled)")
ok(exists("/usr/share/gnome-shell/extensions/osk-button@q706f/extension.js"), "osk-button@q706f extension installed")
greeter = cat("/etc/gdm3/greeter.dconf-defaults").decode()
ok("screen-keyboard-enabled=true" in [l.strip() for l in greeter.split("\n")], "on-screen keyboard forced on at the GDM greeter")
ok(exists("/etc/localtime"), "timezone link present")

print("== kernel modules and firmware")
rels = [p.split("/")[4] for p in tree if p.count("/") == 4 and p.startswith("/usr/lib/modules/")]
ok(len(rels) == 1, "one kernel release in /usr/lib/modules: %s" % rels)
if rels:
    base = "/usr/lib/modules/" + rels[0]
    dep = cat(base + "/modules.dep").decode()
    extra = [os.path.basename(p) for p in under(base + "/extra") if p.endswith(".ko")]
    want = [d for d in os.listdir(os.path.join(desk, "modules")) if os.path.exists(os.path.join(desk, "modules", d, "Makefile"))]
    ok(all(w + ".ko" in extra for w in want), "out-of-tree modules present in extra/: %s" % extra)
    ok(extra and all(("extra/%s:" % k) in dep for k in extra), "modules.dep lists extra/*.ko")
    ok(exists(base + "/modules.dep.bin") and exists(base + "/modules.alias.bin"), "depmod indexes present")
    ok(not exists(base + "/build"), "no dangling build link")
    ok(len([p for p in under(base + "/kernel") if ".ko" in p]) > 100, "in-tree modules present")
for f in ("qcom/sm8250/q706f/adsp.mbn", "qcom/sm8250/q706f/cdsp.mbn", "qcom/sm8250/q706f/slpi.mbn",
          "qcom/sm8250/q706f/a650_zap.mbn", "qcom/sm8250/q706f/venus.mbn", "goodix_firmware.bin", "goodix_cfg_group.bin"):
    ok(exists("/usr/lib/firmware/" + f), "firmware " + f)
ok(len(under("/usr/lib/firmware/cirrus")) > 4, "firmware cirrus/ (amplifiers)")
ok(any(p.startswith("/usr/lib/firmware/ath11k/QCA6390") for p in tree), "firmware ath11k/QCA6390 (linux-firmware)")
ok(any(p.startswith("/usr/lib/firmware/qcom/a650_sqe.fw") for p in tree), "firmware qcom/a650_sqe.fw (linux-firmware)")

print("== no secrets or identity data")
ok(not [p for p in tree if p.startswith("/etc/ssh/ssh_host_")], "no ssh host keys")
ok(tree.get("/etc/machine-id") is not None and cat("/etc/machine-id") == b"", "/etc/machine-id empty")
ok(not exists("/etc/q706f-bt-addr") and not exists("/etc/q706f-wifi-addr"), "no Bluetooth / Wi-Fi address files")
ok(not [p for p in tree if p.startswith(("/etc/netplan/90-NM-", "/etc/NetworkManager/system-connections/"))], "no Wi-Fi profiles")
ok(not under("/var/lib/bluetooth")[1:], "no Bluetooth pairings")
ok(not exists("/home/ubuntu/.ssh") and not exists("/root/.ssh/authorized_keys"), "no authorized_keys")
ok(not exists("/home/ubuntu/.config/q706f-remote-pc.conf"), "no remote-PC configuration")
kr = [p for p in under("/home/ubuntu/.local/share/keyrings") if p.endswith(".keyring")]
ok(all(b"[keyring]" in cat(p) and cat(p).count(b"\n[") == 0 for p in kr), "no keyring with stored items %s" % kr)

print("== bring-up switches (image says BRINGUP=%s)" % bringup)
sudoers = [p for p in under("/etc/sudoers.d") if p != "/etc/sudoers.d" and not p.endswith("/README")]
nopasswd = [p for p in sudoers + ["/etc/sudoers"] if any("NOPASSWD" in l and not l.lstrip().startswith("#")
            for l in cat(p).decode("utf-8", "replace").split("\n"))]
autologin = any(l.replace(" ", "").lower().startswith("automaticloginenable=true")
                for l in cat("/etc/gdm3/custom.conf").decode().split("\n"))
unsafe = [p for p in tree if p.endswith("org.gnome.Shell@.service.d/unsafe.conf")] or \
         any(b"unsafe-mode" in cat(p) for p in tree if "org.gnome.Shell@.service" in p and stat.S_ISREG(tree[p][0]))
if bringup == "1":
    ok(nopasswd == ["/etc/sudoers.d/90-bringup"], "password-less sudo present (BRINGUP)")
    ok(autologin, "GDM autologin present (BRINGUP)")
    ok(bool(unsafe), "gnome-shell --unsafe-mode drop-in present (BRINGUP)")
    ok(bool(kr), "unencrypted default keyring present (BRINGUP)")
else:
    ok(not nopasswd, "no password-less sudo %s" % nopasswd)
    ok(not autologin, "no GDM autologin")
    ok(not unsafe, "no gnome-shell --unsafe-mode")
    ok(not kr, "no pre-made keyring")

print("\n%s: %d check(s) failed" % (os.path.basename(img), len(fails)) if fails else "\n%s: all checks passed" % os.path.basename(img))
sys.exit(1 if fails else 0)
PY
