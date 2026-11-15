#!/usr/bin/env bash
# Recreate the build host for the q706f Ubuntu Touch port with one command.
# Heavy build tooling lives in the Docker image (scripts/docker/Dockerfile);
# the host only needs device tools, Docker and a few helpers.
# Usage: scripts/setup-host.sh [--host-packages]   (--host-packages needs sudo)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

HOST_PKGS=(
  git git-lfs curl wget rsync python3 cpio lz4 xz-utils zstd unzip
  android-sdk-libsparse-utils mkbootimg abootimg device-tree-compiler
  erofs-utils pmbootstrap repo qdl
)

[ "$(uname -m)" = x86_64 ] || { echo "ERROR: build host must be x86_64"; exit 1; }

if [ "${1:-}" = "--host-packages" ]; then
  sudo apt-get update
  sudo apt-get install -y "${HOST_PKGS[@]}"
fi

command -v docker >/dev/null || { echo "ERROR: docker is required"; exit 1; }
docker build -t ut-q706f-build:22.04 \
  --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$ROOT/scripts/docker"

echo "== summary"
for t in adb fastboot docker git; do
  printf '%-10s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
free -g | awk '/Mem:/{print "RAM available: "$7" GB"}'
df -h --output=avail "$ROOT" | tail -1 | xargs echo "Disk free:"
