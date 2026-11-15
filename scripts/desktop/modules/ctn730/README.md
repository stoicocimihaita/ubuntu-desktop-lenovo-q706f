# ctn730 — NXP CTN730 pen charger (Lenovo Tab P12 Pro, mainline)

Out-of-tree port of Lenovo's GPL driver `drivers/misc/ctn730/ctn730.c` (kernel 4.19,
`android_kernel_lenovo_sm8250`) to mainline Linux (written on 7.1, used on 7.3.4). The CTN730 is the NFC wireless-charging
poller behind the back cover; it detects, identifies and charges the Precision Pen 3.

The chip runs its own firmware. The host resets it, sends `CHG_ENABLE` and then only
receives events (pen detected/lost, charging state, battery level). The wire protocol and
the host state machine are unchanged from the vendor driver.

## Build

```sh
scripts/dev-shell.sh bash -c 'make -C /work/sources/linux-desktop \
    O=/work/out/desktop/kernel/build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    M=/work/scripts/desktop/modules/ctn730 modules'
```

Builds without warnings (also with `W=1`). Result: `ctn730.ko`.

## Load

With the device-tree node (`scripts/desktop/patches/0104-q706f-dts-ctn730.patch`,
`pen-charger@28` on `i2c1`): install the module, it binds by `compatible = "nxp,ctn730"`.

Without a node (bring-up on a running kernel) the GPIOs come from module parameters,
format `"<gpiochip label>,<line offset>"`:

```sh
sudo insmod ctn730.ko debug=1 \
    "enable_gpio=c440000.spmi:pmic@4:gpio@c000,7" \
    "reset_gpio=f100000.pinctrl,6" \
    "irq_gpio=f100000.pinctrl,111"
echo ctn730 0x28 | sudo tee /sys/bus/i2c/devices/i2c-1/new_device

# unload
echo 0x28 | sudo tee /sys/bus/i2c/devices/i2c-1/delete_device
sudo rmmod ctn730
```

(q706f: VEN = PM8150L GPIO8 → offset 7; reset = TLMM 6, active low; IRQ = TLMM 111, level
high; bus = `i2c@984000`. The parameters are ignored when the device has a firmware node.)

Module parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `debug` | 0 | log every frame (`tx`/`rx` lines in dmesg); writable at runtime |
| `enable_on_probe` | 1 | power the chip and start detection at probe |
| `detect_interval_ms` | 500 | detection period sent with `CHG_ENABLE`; writable, used at the next enable |
| `power_supply` | 1 | register `ctn730-pen` in `/sys/class/power_supply` while a pen is docked |
| `allow_firmware_update` | 0 | create the `update_firmware` attribute — see warning below |
| `enable_gpio`, `reset_gpio`, `irq_gpio` | — | bring-up fallback, see above |

Expected log at start (`debug=1`):

```
rx 80 02 01 00       chip booted, download mode
tx 00 01 00          HOST_RESET: start the user application
rx 40 01 00
rx 80 03 00 10 41    initialized, firmware 1041
tx 10 02 f4 01       CHG_ENABLE, detection every 500 ms
rx 50 01 00          -> status "detecting"
```

A pen that asks for charge then produces `rx 92 …` (`CHG_DEVICE_STATE`), `rx 94 …`
(charging state) and `rx 95 …` (battery level).

## Protocol notes

NXP's host interface document is not public. Besides the vendor driver, the sources are
NXP's test application (`github.com/yunomcl/NXPNFCWLC`) and the ChromeOS EC driver
(`driver/nfc/ctn730.c`).

Frame: `[type | instruction] [len] [payload]`, type `00` command, `40` response (first
payload byte = status), `80` event.

| Frame | Meaning |
|---|---|
| `80 02 01 rr` | reset event, download mode (`rr`: 0 intended, 1 firmware corrupted, 2 unrecoverable) |
| `00 01 00` / `80 03 00 vv vv` | HOST_RESET to normal mode / "initialized", firmware version |
| `10 02 lo hi` → `50 01 00` | CHG_ENABLE, detection period in ms |
| `11 00` → `51 01 00`, `91 01 00` | CHG_DISABLE; event `91 01 01` = stopped by over temperature |
| `92 01 xx` | device state: `00` detected (+7 byte UID, len 8), `01` deactivated, `02` lost, `03` WLC version mismatch, `04` docked (listener present, static charge, no session yet), `05` undocked, `06` foreign object, `07` battery full, `08` charge failure, `0a` plain NDEF tag, `fa` listener over temperature |
| `94 01 xx` | charging `00` started, `01` ended (full), `02` stopped |
| `95 …` | battery level in % (`ff` unknown); `15 00` asks for it (`55 02 00 lvl`, status `02` when no pen) |
| `9f …` | optional NDEF records of the listener |
| `8f …` | generic error |
| `06 01 01` / `06 01 02` | BIST: RF field on / off |
| `06 01 04` → `46 0d ss <uid 7> <5 bytes>` | BIST "activate tag and verify WLC_CAP": `00` ok, `20` no tag, `21` tag without a valid WLC capability record (the 5 bytes are then not meaningful) |
| `06 03 09 pp nn` → `46 .. 00 <16*nn bytes>` | BIST: read the pen's tag from page `pp`; `32` = page below 12 refused, `33` = read error |
| `02 01 id` → `42 .. 00 <value>` | READ_PARAMETER (user EEPROM, ids `00`..`46`); `01 …` would write one — never sent |
| `08 01 id` / `07 02 id val` | read / write session (volatile) parameter; id 0 = battery level events |
| `0c 01 tag` → `4c .. 00 tag len <value>` | DUMP_STATUS, tags 0..7 (1 = firmware version) |

The chip sleeps between detection pings and then NAKs its I2C address; the access wakes
it and a resend about 10 ms later is accepted.

A healthy sequence with a pen (from another Lenovo tablet with the same chip):
`92 00 <uid>` → host `11 00` → `92 01`, `91 00` → RF on, read address, RF off →
`10 02 f4 01` → `92 04` (repeated) → `92 00 <uid>` → `94 00` → `95 <level>`.

## sysfs interface (`/sys/class/misc/ctn730/`)

Same names and formats as the vendor driver, so earlier experiments can be repeated.

| Attribute | | |
|---|---|---|
| `enable` | rw | 1 = VEN high + detection, 0 = chip off |
| `status` | ro | host state: `detecting`, `detected`, `rf_on`, … (vendor strings) |
| `version` | ro | chip firmware version, e.g. `1041` |
| `attached` | ro | 1 while the chip reports a pen in a charging session |
| `charge_state` | ro | `Unknown` / `Charging` / `Full` / `Notcharging` |
| `level` | ro | pen battery in %, `-1` unknown |
| `mac` | ro | pen Bluetooth address read from its NFC tag (cleared when the pen is lost) |
| `reget_mac` | wo | `1`: stop charging, read the address again, resume |
| `info_report` | wo | `1`/`0`: battery level events on/off |
| `rf_on` | wo | `1`: factory test mode, RF field permanently on; `0`: hard reset to normal mode |
| `cn_test` | ro | reading sends BIST "activation"; only answered in `rf_on` mode |
| `param` | wo | up to 32 raw bytes sent to the pen over the NFC application channel |
| `pen_cmd` | wo | `1`: sends `aa 55 cc 33` to the pen. Stock issues this when the pen's **Bluetooth pairing is cleared** — do not use casually |
| `uid` | ro | *(new)* NFC UID of the detected pen |
| `bist_result` | ro | *(new)* payload of the last BIST response (status byte first), so results do not have to be fished out of dmesg |
| `ntag_read` | wo | *(new)* `"<page> [count]"`: read `count`×16 bytes of the pen's NFC tag from a 4-byte page (≥ 12), rf_on mode only; answer in `bist_result` |
| `chip_status` | ro (root) | *(new)* the chip's DUMP_STATUS items and the answer to a battery level request |
| `chip_params` | ro (root) | *(new)* the chip's configuration parameters (read only; rf_on mode) |
| `update_firmware` | wo | only with `allow_firmware_update=1` |

uevents on the misc device carry `ATTACHED=`, `CHARGING_STATE=`, `LEVEL=`, `MAC=` and
`WRITEPENDATA=` as before. While a pen is attached, `/sys/class/power_supply/ctn730-pen`
(scope `Device`) exposes `status`, `capacity`, `present`.

Useful checks:

```sh
cd /sys/class/misc/ctn730
echo 1 | sudo tee reget_mac          # position test: mac is valid for ~2 s if a pen is in the field
echo 1 | sudo tee rf_on; sleep 1; cat cn_test; sleep 1; cat bist_result; echo 0 | sudo tee rf_on
#   20            no tag in the field
#   21 <uid> …    tag present, but it does not advertise wireless-charging capability
#   00 <uid> …    pen ready to be charged

# the pen's tag (NXP CRN120, Type 2): session registers, Bluetooth address
echo 1 | sudo tee rf_on; sleep 1
echo 0xec | sudo tee ntag_read; cat bist_result    # 00 NC_REG LAST_NDEF_BLOCK SRAM_MIRROR_BLOCK WDT WDT CLK NS_REG
echo 0x10 | sudo tee ntag_read; cat bist_result    # 00 <address, little endian> …
echo 0 | sudo tee rf_on
```

## Firmware update — disabled

The vendor source contains a path that rewrites the chip's user EEPROM and application
flash from `user_ee_hostcontrolled.bin` / `wlc_host_user_app.bin`. Lenovo had it compiled
out (attribute commented) and the stock vendor image ships neither file. It is ported
for completeness but unreachable unless the module is loaded with
`allow_firmware_update=1`; **it has never been executed on mainline and can brick the
charger**. Normal operation needs no firmware files on the host.

## Differences from the vendor driver

Modernised: `probe(client)`/void `remove`, `gpiod` + `interrupts` from DT
(`enable-gpios`, `reset-gpios` instead of `rst-gpios`/`interrupt-gpios`), devm, attribute
groups, `sysfs_emit`, one mutex around the state machine (the vendor code was unlocked),
`linux/crc32.h` instead of the private CRC table, standard `wakeup-source` handling.

Dropped:

- `is_stylus_attached()` and the `ctn730_notifier_*` exports — their only user was the
  downstream `goodix_ts_core`; mainline `goodix_berlin` has no such hook.
- `register_hardware_info()` — Lenovo-only API. The version is in `version` and dmesg.
- DRM panel notifier (stop battery-level events while the screen is off) — the
  `drm_panel_notifier` API does not exist in mainline. Level events are now switched off
  in `suspend` and back on in `resume`; `info_report` still works manually.
- `pm_wakeup_event()` hack in the IRQ thread — the IRQ is masked across suspend and
  replayed on resume; wake-up is opt-in through the DT `wakeup-source` property.
- `enable` no longer reports `attached=1` before any pen was seen (vendor workaround
  for its touchscreen driver).
- The legacy NXP reference driver `CTN730_i2c.c` (raw read/write char device; not built
  for this product).

Fixed on the way: `param` accepted more than 32 bytes (buffer overflow), uninitialised
`charge_state` on some events, payload length checks, firmware buffer leaks.

Robustness (differs from the vendor code):

- A command the chip NAKs (it is asleep between detection pings) is resent after 10 ms,
  up to three times, before the state machine is rescheduled. The vendor retried after
  1 ms, forever. After about one second without success the chip is hard reset so that host
  and chip start again from the reset event (an earlier version of this port gave up
  after 50 fast retries, about 150 ms, and left the state machine stuck: "command 0x11
  failed 51 times").
- The interrupt handler rereads after a NAK instead of dropping the interrupt.
- If the chip sends no reset event within 500 ms of `enable` (seen when VEN was low only
  briefly, e.g. on module reload), the reset line is pulsed, up to five times.
- Device states 6, 7, 8, 0x0a, 0xfa and events 0x8f/0x9f are logged by name.

## To do for an in-tree driver

- DT binding (`nxp,ctn730.yaml`) and a home (`drivers/power/supply/`), with the
  `power_supply` as the primary interface and the vendor attributes moved to debugfs.
- A way to tell the touchscreen driver that the pen is docked (was `is_stylus_attached`).
- Suspend/resume and `wakeup-source` are untested.

## Licence and origin

GPL-2.0 (see the SPDX line in `ctn730.c`). Derived from `drivers/misc/ctn730/` of
Lenovo's GPL kernel release for the TB-Q706F; `CTN730_i2c.c` there is
"Copyright (C) 2021 NXP", `ctn730.c` has no copyright notice.
