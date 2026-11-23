# q706f kernel on Linux 7.4-rc3 (experimental port, 22.11.2026)

Build only, not booted yet. The 7.3.4 flow (`build-kernel.sh`, `patches/`,
`sources/linux-desktop`, `out/desktop/kernel/`) is untouched; the 7.4 flow uses its own paths.

## Source

- `https://git.kernel.org/torvalds/t/linux-7.4-rc3.tar.gz` (tag v7.4-rc3, Makefile `7.4.0-rc3`)
- sha256 `95c0eb4a051dd09983d6b7887bdd9d323559fccda163c627d398c0547b89f961`
  (generated tag tarball fetched 22.11.2026; there is no signed checksum list for -rc tarballs).
  Stored as `out/desktop/dl/linux-7.4-rc3.tar.gz` and pinned in `build-kernel-7.4.sh`.
- Extracted and patched tree: `sources/linux-desktop-7.4rc3` (recreated by the build script).
  The git tree used for the refresh (one commit per patch): `sources/linux-desktop-7.4rc3-port`.

## Files

| What | Where |
|---|---|
| Patch series (37 patches, `patch -p1 -F0`, name order) | `scripts/desktop/patches-7.4/` (+ `README`) |
| Kernel build (+ out-of-tree modules, depmod, modules tarball) | `scripts/desktop/build-kernel-7.4.sh` |
| Boot image (header v0, DTB appended to Image.gz, margin check) | `scripts/desktop/make-testboot-7.4.sh` |
| Config fragment for 7.4 | `scripts/desktop/q706f-7.4-renames.config` |
| Output | `out/desktop/kernel-7.4/`, `out/desktop/ubuntu-boot-7.4rc3-<date>.img`, `out/desktop/modules-7.4rc3-<date>.tgz` |

    scripts/desktop/build-kernel-7.4.sh
    EXTRA_CMDLINE="q706f.rootimg=ubuntu-desktop.img" scripts/desktop/make-testboot-7.4.sh

## Patches

Not carried, already in v7.4-rc3 (their reverse applies cleanly):

- 0001 PCI: qcom: honor iommu-cells (5121d76cb9dd, v7.4-rc1)
- 0201 ufs-qcom: enable only lane clocks (f07317a8d57f, v7.4-rc1)
- 0202 sm8250 GCC GDSCs as subdomains of RPMh CX (389a0144c511, v7.4-rc1)
- Also in v7.4-rc3: the ath11k IRQ balance fix e56c9d429ba0, together with the regression it
  fixes (f7a74e131d3f). Neither is in 7.3.4.

Content changed (each has a "7.4-rc3 port:" paragraph in its header):

- **0002** (q706f port): v7.4 has its own `panel-novatek-nt36532.c` (OnePlus Pad 2) under the
  same Kconfig symbol; silime's Xiaomi Pad 6 NT36532 driver and its Kconfig/Makefile lines are
  dropped (q706f doesn't use it). The `SEN_MI2S_TX` q6routing entries are upstream now and
  are dropped. `POWER_SUPPLY_PROP_CHARGING_ENABLED` moves after the new `LOAD_SWITCH` property
  (sysfs attribute table updated to match). s5k5e9: V4L2 subdev pad ops gained a
  `v4l2_subdev_client_info` argument (`set_fmt`, `get_selection`).
- **0127** (CCI reset): `cci_resume_runtime()` now returns `cci_init()`; the reset follows it.
- **0203a** (GMU cxpd link stateless): v7.4 keeps the link in `cx_link` and also links an
  optional `gmu_mx` domain the same way; both links are now stateless (SM8250 has no `gmu_mx`).
- **0203b** (separate DRM device helper): v7.4 replaced `msm_gpu_no_components()` with the
  tristate `msm_separate_gpu_kms_components()` (auto mode). `msm_gpu_use_separate_drm_dev()`
  is built on top of it and keeps v7.4's adreno_probe() condition. No functional change.
- **0203e** (GMU driver): v7.4's `add_gpu_components()` checks `msm_gpu_node_present()`;
  the GMU component is added only together with the GPU node.

Re-diffed only (line offsets, a little fuzz on 0130 and 0203d, content identical): 0014, 0015,
0101, 0102, 0104-0107, 0109-0111, 0113, 0114, 0116, 0118, 0121, 0123, 0125, 0130-0138,
0203c, 0203d, 0204-0206.

Set aside: none. Not ported (not part of the 7.3.4 series either): `*.pending`, `*.debug`,
`*.needs-approval`, `*.rejected`.

## Config

Same base and fragments as 7.3.4 (`config-pmos-q706f-6.11` + `q706f-desktop.config` +
`q706f-7.3-renames.config` + `q706f-7.3.4-extra.config`), plus `q706f-7.4-renames.config`:

- Turns off the clock/interconnect/pinctrl drivers of other SoCs that are now `default ARCH_QCOM`
  (Eliza, Glymur, Hawi, Nord, Kaanapali, Milos, QCS615, QCS8300, SAR2130P, Shikra, SM8750,
  MSM8952). Several interconnect ones would otherwise be built in.
- Lost compared with the 7.3.4 config: `ANDROID_BINDER_IPC` (the C binder driver is gone, only
  the Rust one is left, and that needs `CONFIG_RUST`; the desktop rootfs doesn't use binder);
  `QCOM_TZMEM_MODE_GENERIC` (the choice is gone; generic is still the default). The other
  missing symbols are arch-internal (PER_VMA_LOCK and friends, now unconditional or renamed).
- `IPV6` became bool: olddefconfig warns about `=m` from the old base and sets it to `=y`.
  The same happens for `CRYPTO_LIB_CURVE25519_GENERIC`.
- Every option the fragments ask for survives olddefconfig (the build script checks this).

## Build result (22.11.2026)

- Kernel `7.4.0-rc3`, 0 compiler warnings in build.log; out-of-tree `ctn730` built against it.
- `out/desktop/kernel-7.4/Image.gz` 15 728 626 bytes; kernel+DTB ends at 0x00f2b185, leaving
  872 059 bytes before ramdisk_offset (7.3.4: Image.gz-dtb 15 854 912 bytes).
- `out/desktop/ubuntu-boot-7.4rc3-20261122.img` (cmdline `... q706f.rootimg=ubuntu-desktop.img`)
  sha256 `feb97519fbd225744137ab8b590c01bb653447ebf07d72f5c8eaba9a00af0949`
- `out/desktop/modules-7.4rc3-20261122.tgz` (`lib/modules/7.4.0-rc3/...`, depmod done, ctn730 in
  `extra/`, no build/source links) sha256
  `49b94f9ab54653b727b334f80a8bcda60b335fc0fda5bc69b722c52c114550be`.
  Install side by side with `tar -C / -xzf ...` (GNU tar keeps the `/lib -> usr/lib` symlink,
  so it lands in `/usr/lib/modules/7.4.0-rc3`; 7.3.4's modules are untouched). Install it
  **before** the RAM boot, or Wi-Fi, audio, iris and the cameras won't load.
- DTB compared with 7.3.4 (decompiled, sorted): the only change is in the PCIe nodes. v7.4
  moved `perst-gpios`/`wake-gpios`/`phys` from the controllers into the root port nodes
  (`reset-gpios`), and `wake-gpios` is now active low. Every compatible that had a driver
  in 7.3.4 still has one in 7.4.

## What to check at first boot (RAM boot only)

- **Display / panel** (amsa26zp01, DSI): the panel driver and 0106/0135 are unchanged; the
  drm/msm core changed a lot (separate GPU/KMS auto mode). Check that the image comes up and
  that there is exactly one card with the GPU (`/dev/dri/card*`, `renderD128`).
- **GPU** (0203a-e, the riskiest port): the GMU component bind order on the reworked msm core,
  `dmesg | grep -iE "gmu|adreno|a6xx|sync_state"`, then a GPU workload, and runtime suspend
  (`/sys/kernel/debug/dri/*/gpu` idle, GX GDSC off).
- **iris / venus**: both are built as modules and both match `qcom,sm8250-venus`, as in 7.3.4.
  Upstream changes to iris between 7.3 and 7.4 were not reviewed. Check which driver binds,
  whether the firmware loads, and whether the rootfs blacklist for iris (if one is active)
  still applies.
- **cs35l45**: 0123/0125 applied unchanged; confirm 4 amps probe, no DSP watchdog after
  PipeWire starts, and the UCM cap still applies (rule 8).
- **charger / fuel gauge** (0107, 0110, 0116, 0138; `CHARGING_ENABLED` moved in the
  power_supply enum, so its numeric value changed: userspace that uses the name is fine).
  Check `/sys/class/power_supply/*` and the 9 V PDO negotiation.
- **ath11k** (0121, 0132, 0205): PCIe perst/wake now come from the root port node, with
  active-low wake. Check link up, `unbind_in_suspend` still works, Wi-Fi reconnects after
  s2idle, CXSD count (`qcom_stats`). Only suspend with the owner next to the tablet.
- **ctn730** (out-of-tree module + 0104/0133): module loads, pen charging/detection.
- Cameras: 0127 CCI reset (rewritten for 7.4's runtime-resume), s5k5e9 with the new pad-op
  signature; check all 3 sensors bind.
- Bluetooth, touch/stylus (goodix-berlin 0101/0109/0113/0136), pogo keyboard.
