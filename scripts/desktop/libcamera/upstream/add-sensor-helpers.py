#!/usr/bin/env python3
"""Insert the q706f CameraSensorHelper entries into an upstream libcamera tree.

Same models as ../0001-libipa-add-ov13b10-ov8856-s5k5e9-sensor-helpers.patch (0.7),
written as an idempotent insertion instead of a context patch, because upstream
camera_sensor_helper.cpp changes often (e.g. the exposure-margin patch, 2026-11).

- A helper that upstream already registers is left alone (and reported).
- exposureMargin_ is set only if the tree has it (patch "ipa: camera_sensor_helper:
  Introduce exposure margin"). Margins = the Linux 7.3.4 drivers:
  ov13b10 height+vblank-8, ov8856 OV8856_EXPOSURE_MAX_MARGIN 6, s5k5e9 vts-2.
- The classes are inserted before the first REGISTER line that follows the
  "ov13858" registration's class, i.e. right after REGISTER_CAMERA_SENSOR_HELPER("ov13858", ...).

Usage: add-sensor-helpers.py <path to src/ipa/libipa/camera_sensor_helper.cpp>
"""
import os
import re
import sys

path = sys.argv[1]
src = open(path).read()
header = open(os.path.join(os.path.dirname(path), 'camera_sensor_helper.h')).read()
has_margin = 'exposureMargin_' in header

HELPERS = {
    'ov8856': dict(cls='Ov8856', black=4096, gain='{ 1, 0, 0, 128 }', margin=6,
                   note='code 128 = 1x, 1/128 steps up to 2047; BLC target 0x4003 = 0x40'),
    'ov13b10': dict(cls='Ov13b10', black=None, gain='{ 1, 0, 0, 128 }', margin=8,
                    note='code 0x80 = 1x, 1/128 steps up to 0x7c0; BLC target not programmed'),
    's5k5e9': dict(cls='S5k5e9', black=None, gain='{ 1, 0, 0, 32 }', margin=2,
                   note='SMIA analogue_gain_code_global, code 32 = 1x (inferred)'),
}

anchor = re.search(r'REGISTER_CAMERA_SENSOR_HELPER\("ov13858",[^\n]*\n', src)
if not anchor:
    sys.exit('anchor REGISTER_CAMERA_SENSOR_HELPER("ov13858", ...) not found')
if 'AnalogueGainLinear' not in src:
    sys.exit('AnalogueGainLinear not found: gain model API changed, update this script')

blocks = []
for model, h in HELPERS.items():
    if f'REGISTER_CAMERA_SENSOR_HELPER("{model}"' in src:
        print(f'{model}: already registered upstream, not added (check its values)')
        continue
    body = [f'\t\t/* q706f, Linux 7.3.4 driver: {h["note"]}. */']
    if h['black'] is not None:
        body.append(f'\t\tblackLevel_ = {h["black"]};')
    body.append(f'\t\tgain_ = AnalogueGainLinear{h["gain"]};')
    if has_margin:
        body.append(f'\t\texposureMargin_ = {h["margin"]};')
    blocks.append(
        f'\nclass CameraSensorHelper{h["cls"]} : public CameraSensorHelper\n'
        '{\npublic:\n'
        f'\tCameraSensorHelper{h["cls"]}()\n\t{{\n' + '\n'.join(body) + '\n\t}\n};\n'
        f'REGISTER_CAMERA_SENSOR_HELPER("{model}", CameraSensorHelper{h["cls"]})\n')
    print(f'{model}: added (exposure margin {"set" if has_margin else "not supported by tree"})')

if blocks:
    src = src[:anchor.end()] + ''.join(blocks) + src[anchor.end():]
    open(path, 'w').write(src)
