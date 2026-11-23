# Contrast autofocus for the libcamera software ISP (q706f, first version)

Patches on top of libcamera v0.8.0 (`git am` in order). Build with
`REV=<branch with these patches> ALLOW_NO_VBLANK=1 scripts/desktop/libcamera/build-libcamera-upstream.sh`.

- SwStatsCpu: contrast measure (squared horizontal green differences, central quarter) for
  10-bit packed Bayer, on both the line path (CPU debayer) and the whole-frame path (GPU debayer).
- softisp IPA `Af` algorithm: coarse sweep (step 64) from the far end with early stop, fine scan
  (step 16) around the peak, lock; refocus when the contrast stays below 60 % of the locked value
  for 4 statistics frames. Enabled only by an `Af:` entry in the sensor tuning file:

      - Af:
          min: 0
          max: 1023
          coarseStep: 64
          fineStep: 16

- IPA interface `setLensPosition`; the simple pipeline moves the sensor's focus lens (CameraLens).

The PipeWire `spa-libcamera` plugin built for 0.8.0 keeps working (only internal headers changed).
