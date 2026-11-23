# Mesa build environment (arm64, Ubuntu 26.04 "resolute"), derived from the libcamera
# build image created by scripts/desktop/libcamera/build-libcamera.sh.
FROM q706f-libcamera-build:26.04-arm64
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      build-essential pkg-config meson ninja-build \
      python3-mako python3-yaml python3-packaging python3-ply python3-pycparser \
      bison flex glslang-tools xz-utils ca-certificates \
      libdrm-dev libwayland-dev wayland-protocols libwayland-egl-backend-dev \
      libexpat1-dev libzstd-dev zlib1g-dev libelf-dev libudev-dev libdisplay-info-dev \
      libvulkan-dev libglvnd-dev \
      libx11-dev libx11-xcb-dev libxcb1-dev libxcb-dri2-0-dev libxcb-dri3-dev \
      libxcb-present-dev libxcb-sync-dev libxcb-glx0-dev libxcb-randr0-dev libxcb-shm0-dev \
      libxcb-xfixes0-dev libxcb-keysyms1-dev libxrandr-dev libxshmfence-dev libxxf86vm-dev \
      libxfixes-dev libxext-dev libxdamage-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
