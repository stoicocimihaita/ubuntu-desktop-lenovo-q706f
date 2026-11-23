GStreamer 1.28.9 under /opt/gstreamer-1.28.9 (arm64, Ubuntu 26.04)
===================================================================

Side-by-side test build; the system GStreamer (1.28.2, /usr) is not touched.
Nothing is installed system-wide: unpack the tarball as root into / (it only
contains opt/gstreamer-1.28.9/...), or anywhere else and adjust G below.

    sudo tar -C / -xzf gstreamer-1.28.9-arm64-opt.tar.gz

Remove with: sudo rm -rf /opt/gstreamer-1.28.9 ~/.cache/gstreamer-1.28.9-opt

1. Environment (for ONE shell / ONE app only)
---------------------------------------------

    G=/opt/gstreamer-1.28.9
    export LD_LIBRARY_PATH=$G/lib/aarch64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    export GST_PLUGIN_SYSTEM_PATH_1_0=$G/lib/aarch64-linux-gnu/gstreamer-1.0
    export GST_PLUGIN_SCANNER_1_0=$G/libexec/gstreamer-1.0/gst-plugin-scanner
    export GST_REGISTRY_1_0=$HOME/.cache/gstreamer-1.28.9-opt/registry.aarch64.bin
    unset GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH
    export PATH=$G/bin:$PATH

- LD_LIBRARY_PATH makes every process (also binaries linked against the system
  libgstreamer-1.0.so.0, libgstbase, libgstvideo, libgstgl, libgstapp,
  libgstcodecparsers ...) load the 1.28.9 libraries (same SONAMEs, ABI-compatible
  within 1.x). All libraries of core/base/bad are shipped (incl. libgstwebrtc,
  libgsttranscoder, libgstplay, libgstcodecs, libgstwayland), so nothing of
  GStreamer itself is mixed in from /usr.
- GST_PLUGIN_SYSTEM_PATH_1_0 points ONLY at the /opt plugins, so the 1.28.2
  plugins in /usr/lib/aarch64-linux-gnu/gstreamer-1.0 are not loaded.
  (Consequence: plugins not built here, e.g. pipewire, libcamera, gtk4 sinks, are
  unavailable in this environment.)
- The separate registry file keeps the system registry
  (~/.cache/gstreamer-1.0/registry.aarch64.bin) untouched.

2. Check
--------

    gst-inspect-1.0 --version          # -> GStreamer 1.28.9
    gst-inspect-1.0 v4l2vp9dec         # present only if /dev/video* exposes a VP9 decoder (Iris)
    gst-inspect-1.0 video4linux2       # plugin itself (v4l2src/v4l2sink + probed v4l2*dec/enc)
    gst-inspect-1.0 v4l2h264dec
    gst-inspect-1.0 -b | head          # blacklisted plugins (should be empty)
    gst-inspect-1.0 | grep -E 'v4l2|gl|avdec_(h264|vp9)|vp9dec'

The v4l2*dec elements are registered dynamically by probing /dev/video* at
registry-scan time. If the decoder node appears after the scan, delete the
registry file and run gst-inspect-1.0 again.

Quick decode test (no browser):

    gst-launch-1.0 -v filesrc location=test.webm ! matroskademux ! vp9parse ! \
        v4l2vp9dec ! glimagesink
    GST_DEBUG=v4l2*:5 gst-launch-1.0 playbin3 uri=file://$PWD/test.mp4

3. GNOME Web (epiphany, deb package) on this GStreamer
-------------------------------------------------------

WebKitGTK's WebKitWebProcess (spawned by epiphany) links the system
libgstreamer-1.0.so.0 and inherits the environment above. But by default it
runs inside a bubblewrap sandbox that only bind-mounts selected system paths
(/usr, /etc, ...): /opt is not visible there, so the libraries/plugins would not
be found. For this TEST ONLY disable the sandbox:

    ( G=/opt/gstreamer-1.28.9
      export LD_LIBRARY_PATH=$G/lib/aarch64-linux-gnu
      export GST_PLUGIN_SYSTEM_PATH_1_0=$G/lib/aarch64-linux-gnu/gstreamer-1.0
      export GST_PLUGIN_SCANNER_1_0=$G/libexec/gstreamer-1.0/gst-plugin-scanner
      export GST_REGISTRY_1_0=$HOME/.cache/gstreamer-1.28.9-opt/registry.aarch64.bin
      unset GST_PLUGIN_PATH GST_PLUGIN_PATH_1_0 GST_PLUGIN_SYSTEM_PATH
      export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
      export GST_DEBUG=2,v4l2*:4,webkit*:3 GST_DEBUG_FILE=/tmp/epiphany-gst.log
      epiphany --new-window https://www.youtube.com )

- Close all running epiphany windows first (an already running instance would
  get the URL over D-Bus and keep its old environment). Alternatively run a
  separate instance with --private-instance or --profile=/tmp/eph-gst-test.
- Verify the web process really uses /opt:
      pid=$(pgrep -n WebKitWebProces); grep -m3 gstreamer /proc/$pid/maps
  It must show /opt/gstreamer-1.28.9/lib/... .
- Never leave WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS set for normal browsing.
- A Flatpak epiphany (org.gnome.Epiphany) uses the GNOME runtime's GStreamer and
  cannot be redirected this way; this applies only to the deb package.
- WebKit picks decoders by rank; to force/avoid the V4L2 decoders use e.g.
      export GST_PLUGIN_FEATURE_RANK=v4l2vp9dec:MAX,v4l2h264dec:MAX
  or  export GST_PLUGIN_FEATURE_RANK=v4l2vp9dec:NONE,v4l2h264dec:NONE
