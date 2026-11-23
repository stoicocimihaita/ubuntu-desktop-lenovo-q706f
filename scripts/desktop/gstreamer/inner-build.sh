#!/bin/bash
# Runs inside q706f-gst-build:26.04-arm64 (called by build-gstreamer.sh).
set -euo pipefail
LIBDIR=lib/aarch64-linux-gnu
export PKG_CONFIG_PATH="$PREFIX/$LIBDIR/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/$LIBDIR"
export PATH="$PREFIX/bin:$PATH"

COMMON="--prefix=$PREFIX --libdir=$LIBDIR --buildtype=release -Db_ndebug=if-release
  --wrap-mode=nodownload -Dauto_features=disabled
  -Ddoc=disabled -Dtests=disabled"

opts() {
  case "$1" in
    gstreamer) echo "-Dintrospection=disabled -Dtools=enabled -Dbenchmarks=disabled
        -Dgst_debug=true -Dcheck=enabled -Dcoretracers=enabled -Dptp-helper=disabled
        -Dlibunwind=enabled -Dlibdw=enabled -Dbash-completion=disabled" ;;
    gst-plugins-base) echo "-Dintrospection=disabled -Dtools=enabled
        -Dgl=enabled -Dgl_api=gles2,opengl -Dgl_platform=egl -Dgl_winsys=wayland,egl,gbm
        -Dgl-graphene=enabled -Dgl-jpeg=enabled -Dgl-png=enabled
        -Dapp=enabled -Dplayback=enabled -Dvideoconvertscale=enabled -Daudioconvert=enabled
        -Daudioresample=enabled -Dvideorate=enabled -Dvolume=enabled -Dtypefind=enabled
        -Dtcp=enabled -Dgio=enabled -Dgio-typefinder=enabled -Doverlaycomposition=enabled
        -Drawparse=enabled -Dsubparse=enabled -Daudiotestsrc=enabled -Dvideotestsrc=enabled
        -Dcompositor=enabled -Dadder=enabled -Daudiomixer=enabled -Ddsd=enabled -Dencoding=enabled
        -Dpbtypes=enabled -Ddrm=enabled
        -Dogg=enabled -Dopus=enabled -Dvorbis=enabled -Dorc=enabled" ;;
    gst-plugins-good) echo "-Dv4l2=enabled -Dv4l2-gudev=enabled -Dv4l2-libv4l2=disabled -Dv4l2-probe=true
        -Dmatroska=enabled -Disomp4=enabled -Dvpx=enabled -Dpulse=enabled -Dautodetect=enabled
        -Daudioparsers=enabled -Did3demux=enabled -Dapetag=enabled -Dwavparse=enabled -Dflv=enabled
        -Drtp=enabled -Drtpmanager=enabled -Dudp=enabled -Dsoup=enabled -Ddeinterlace=enabled
        -Dvideofilter=enabled -Dvideocrop=enabled -Dvideobox=enabled -Dvideomixer=enabled
        -Deffectv=disabled -Dimagefreeze=enabled -Dinterleave=enabled -Dequalizer=enabled
        -Dlevel=enabled -Dmultifile=enabled -Ddebugutils=enabled -Dpng=enabled -Djpeg=enabled
        -Dorc=enabled -Dbz2=enabled -Dqt5=disabled -Dqt6=disabled -Dgtk3=disabled" ;;
    gst-plugins-bad) echo "-Dintrospection=disabled
        -Dv4l2codecs=enabled -Dvideoparsers=enabled -Dcodecalpha=enabled -Dcodectimestamper=enabled
        -Dwayland=enabled -Dkms=enabled -Ddebugutils=enabled -Did3tag=enabled -Dmpegtsdemux=enabled
        -Dautoconvert=enabled -Dvideofilters=enabled -Dgl=enabled -Dva=disabled
        -Dopus=enabled -Dwebrtc=disabled -Ddash=disabled -Dhls=disabled -Dsctp=disabled -Dorc=enabled" ;;
    gst-libav) echo "" ;;
  esac
}

for m in $MODULES; do
  echo "=========== $m"
  src=/out/src/$m-$VER
  b=/out/build/$m
  extra=""
  for o in examples nls; do grep -qE "option\('$o'" "$src/meson.options" && extra="$extra -D$o=disabled"; done
  meson setup "$b" "$src" $COMMON $extra $(opts "$m") 2>&1 | tail -n 60
  ninja -C "$b" -j "$JOBS" 2>&1 | tail -n 5
  meson install -C "$b" --no-rebuild >/dev/null
done
chown -R "$HOST_UID:$HOST_GID" /out/build "$PREFIX"
