#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch the ALSA UCM profile of the q706f from silime/ubuntu-lenovo-q706f and apply the
# local q706f changes. Called by make-rootimg.sh; can also be run on its own.
#
# The UCM files were written by chalkin (silime, https://github.com/silime) for
# https://github.com/silime/ubuntu-lenovo-q706f (package alsa-lenovo-q706f). That repository
# declares no licence, so the files are not redistributed here: they are downloaded at a
# pinned commit, checked against known sha256 sums and patched at build time.
#
# Local changes (q706f-HiFi.conf.patch): the speaker level ('Digital PCM Volume' 409 = 0 dB on
# every CS35L45 amp, as stock; the speakers have no protection DSP on mainline, so the overlay's
# PipeWire filter-chain 60-q706f-speaker-headroom.conf must stay in front)
# and the internal microphones as a UCM capture device.
#
# Usage: scripts/desktop/ucm/fetch-ucm.sh [output dir]   (default: out/desktop/ucm)
# Output: <dir>/usr/share/alsa/ucm2/{Lenovo/q706f/HiFi.conf,conf.d/sm8250/Xiaoxin Pad Pro.conf}
# Env:   SILIME_UCM_COMMIT  commit of silime/ubuntu-lenovo-q706f to use. Changing it also
#                           needs new sha256 sums below (and a check that the patch applies).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="${1:-$ROOT/out/desktop/ucm}"
COMMIT="${SILIME_UCM_COMMIT:-925004cd9484f8a44e03fddf5ab3bdb5f970865b}"   # 2024-10-31, latest at export time
BASE="https://raw.githubusercontent.com/silime/ubuntu-lenovo-q706f/$COMMIT/alsa-lenovo-q706f/usr/share/alsa/ucm2"
# sha256 of the upstream files at the pinned commit (verified 2026-11-15)
SHA_HIFI=ce51a9cf066045309eb082b55ec5e101fd2d620bb87aa8e209e19f110eb92652
SHA_CARD=a4e165534f6c8a66893063d91f2334785c235c509460769fad00827c35b7fe9d
PATCH="$HERE/q706f-HiFi.conf.patch"

DL="$OUT.dl"
rm -rf "$DL" "$OUT"
mkdir -p "$DL/Lenovo/q706f" "$DL/conf.d/sm8250"
curl -fsSL -o "$DL/Lenovo/q706f/HiFi.conf" "$BASE/Lenovo/q706f/HiFi.conf"
curl -fsSL -o "$DL/conf.d/sm8250/Xiaoxin Pad Pro.conf" "$BASE/conf.d/sm8250/Xiaoxin%20Pad%20Pro.conf"
if [ "$COMMIT" = 925004cd9484f8a44e03fddf5ab3bdb5f970865b ]; then
  echo "$SHA_HIFI  $DL/Lenovo/q706f/HiFi.conf" | sha256sum -c --quiet -
  echo "$SHA_CARD  $DL/conf.d/sm8250/Xiaoxin Pad Pro.conf" | sha256sum -c --quiet -
else
  echo "WARNING: SILIME_UCM_COMMIT=$COMMIT is not the pinned commit: sha256 not checked" >&2
fi
# -F0: any context mismatch is an error (the speaker level must not be silently changed).
patch -d "$DL" -p1 -F0 -s --no-backup-if-mismatch < "$PATCH"
grep -c "Digital PCM Volume' 409" "$DL/Lenovo/q706f/HiFi.conf" | grep -qx 4 \
  || { echo "ERROR: speaker level missing from the patched HiFi.conf" >&2; exit 1; }

mkdir -p "$OUT/usr/share/alsa"
mv "$DL" "$OUT/usr/share/alsa/ucm2"
echo "UCM: silime/ubuntu-lenovo-q706f@${COMMIT:0:12} + q706f-HiFi.conf.patch -> $OUT"
