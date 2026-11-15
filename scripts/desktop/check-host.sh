#!/usr/bin/env bash
# Check that the host can build the Ubuntu Desktop arm64 track. Prints one line per check.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAIN="${MAIN_REPO:-$ROOT}"   # checkout that holds sources/lenovo-sm8250-q706f-firmware
fail=0
ok()  { printf 'OK    %s\n' "$*"; }
bad() { printf 'MISS  %s\n' "$*"; fail=1; }

[ "$(uname -m)" = x86_64 ] && ok "host x86_64" || bad "host is $(uname -m)"
free_gb=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc 0-9)
[ "$free_gb" -ge 60 ] && ok "disk ${free_gb}G free" || bad "disk only ${free_gb}G free (need 60G)"
docker image inspect ut-q706f-build:22.04 >/dev/null 2>&1 && ok "build container" || bad "build container (run scripts/dev-shell.sh true)"
if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && grep -q enabled /proc/sys/fs/binfmt_misc/qemu-aarch64; then
  ok "binfmt qemu-aarch64"
else
  bad "binfmt qemu-aarch64 (sudo apt install qemu-user-binfmt)"
fi
command -v mmdebstrap >/dev/null && ok "mmdebstrap" || bad "mmdebstrap (sudo apt install mmdebstrap)"
{ [ -f "$ROOT/out/desktop/dl/linux-7.3.4.tar.xz" ] || curl -fsI https://cdn.kernel.org/pub/linux/kernel/v7.x/ >/dev/null; } \
  && ok "kernel tarball (cached or kernel.org reachable)" || bad "kernel tarball: no cached copy and kernel.org unreachable"
[ -f "$MAIN/sources/lenovo-sm8250-q706f-firmware/sm8250/q706f/a650_zap.mbn" ] \
  && ok "pmOS firmware clone" || bad "pmOS firmware clone"
exit $fail
