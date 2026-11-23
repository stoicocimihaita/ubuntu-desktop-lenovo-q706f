# Build-deps image for GStreamer 1.28.x (arm64, Ubuntu 26.04 "resolute" userspace).
# Base: q706f-libcamera-build:26.04-arm64 (created by scripts/desktop/libcamera/build-libcamera.sh).
FROM q706f-libcamera-build:26.04-arm64
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config meson ninja-build python3 flex bison nasm git ca-certificates xz-utils \
      libglib2.0-dev libgudev-1.0-dev libdrm-dev libwayland-dev wayland-protocols \
      libegl-dev libgles-dev libgl-dev libgbm-dev libx11-dev libx11-xcb-dev libxext-dev \
      libvpx-dev libavcodec-dev libavformat-dev libavfilter-dev libavutil-dev libswresample-dev \
      libpulse-dev liborc-0.4-dev liborc-0.4-dev-bin libopus-dev libvorbis-dev libogg-dev \
      libpng-dev libjpeg-dev zlib1g-dev libbz2-dev libxml2-dev libdw-dev libunwind-dev libgmp-dev libgsl-dev \
      libcap-dev libgraphene-1.0-dev libsoup-3.0-dev libva-dev \
    && rm -rf /var/lib/apt/lists/*
