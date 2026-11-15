# Harta driverelor open-source pentru TB-Q706F (kernel mainline)

Cercetare din 12.11.2026, făcută pe web și verificată local unde se putea (clona silime, kernelul GPL
Lenovo și imaginile stock). Mainline-ul era atunci la 7.4-rc2.

## Constatarea principală: baza de pornire e silime `7.1.0-dev`

Ramura `7.1.0-dev` din https://github.com/silime/linux (commit d54d86b880a, 19.07.2026, Linux 7.1)
conține DTS-ul `sm8250-lenovo-q706f.dts` mult mai complet decât 6.10/6.11. Adaugă:
- microfoanele: drivere noi `es7210.c` și `as33970.c`, plus rutare q6;
- difuzoarele: patru CS35L45 pe TDM;
- camerele: OV13B10, S5K5E9 și OV8856, plus driverul VCM `dw9768`;
- încărcătorul PM8150B (`qcom_pm8150b_charger.c`, cu un fix USB pentru Q706F);
- tastatura și touchpad-ul pogo, cu o excepție pentru Q706F în hid-multitouch;
- vibrațiile (`qcom-spmi-haptics`);
- senzorul hall (SW_LID);
- ramoops și modurile de repornire PON.

Ramurile `7.3.0-dev` și `sm8250/6.15-dev` **nu** conțin q706f. Tableta nu e în torvalds/linux.

## Pe componente

Legendă: ✅ driver existent (mainline sau 7.1.0-dev) · 🟡 patch sau fork, trebuie adaptat · ❌ nimic open-source

| Componentă | Cip | Stare | Sursa / ce trebuie făcut |
|---|---|---|---|
| Panou | Samsung AMSA26ZP01, DSI + DSC | 🟡 fork | `panel-samsung-amsa26zp01.c` în silime și în gitlab.postmarketos.org/jianhua/sm8250-mainline. Are moduri de 120 și 60 Hz, dar secvența de init scrie mereu valoarea pentru 120 Hz, deci trecerea pe 60 Hz probabil nu schimbă nimic (trebuie reparat). Luminozitatea se controlează prin DCS. |
| GPU | Adreno 650 | ✅ | freedreno GL 4.5 / ES 3.2; Turnip are conformanță Vulkan 1.3 pe A6xx (Collabora, 09.2026). Are nevoie de `a650_zap.mbn` semnat Lenovo (din repo-ul de firmware silime). |
| Touch | Goodix GT9916 / Berlin (comentariul din DTS spune GT6975P) | ✅ degete | `goodix_berlin` din mainline |
| Stylus pe touch (presiune) | același controler | 🟡 patch | Pengyu Luo, „goodix_berlin: Add stylus support” v2 (10.07.2025, nemerge-uit): https://patchwork.kernel.org/project/linux-input/patch/20250710115733.226670-3-mitltlatltl@gmail.com/. Creează un dispozitiv separat cu BTN_TOOL_PEN și ABS_PRESSURE, deci libinput/GNOME ar trebui să dea **presiune reală**. Kernelul Lenovo activează modul pen cu comanda 0x14 (oprire cu 0x15): probabil trebuie trimisă la probe. |
| Încărcarea wireless a stylusului | NXP CTN730 (i2c 0x28) | 🟡 sursă GPL | Nu există nimic în mainline sau NCI. Kernelul GPL Lenovo are driverul complet `drivers/misc/ctn730/ctn730.c` (2273 de linii); trebuie portat pe un kernel modern. Firmware: `user_ee_hostcontrolled.bin`, `wlc_host_user_app.bin`. |
| Stylus BT (butonul) | BLE HID | ✅ | BlueZ + hid-generic |
| Tastatură pogo + touchpad | i2c-hid, ELAN 04F3:31F3 | ✅ / 🟡 | În 7.1.0-dev merge prin i2c-hid-of și hid-multitouch. Bateria tastaturii și BT-ul ei sunt hack-uri Lenovo care lipsesc. |
| Vibrații | PM8150B haptics | 🟡 fork | Seria SPMI haptics a lui Caleb Connolly (v7, 2022, nemerge-uită), inclusă în 7.1.0-dev. Netestat. |
| Difuzoare | 4× Cirrus CS35L45 (I2C) | 🟡 | Driverul există în mainline din 5.19 (DSP din 6.4). Glue-ul TDM pentru sm8250 și firmware-ul sunt în silime. silime notează „doar canalul stâng”, deci trebuie configurate sloturile TDM. Profilul UCM2 `Lenovo-Q706F` trebuie scris de la zero. |
| Microfoane | Everest ES7210 + Synaptics AS33970 | 🟡 fork | Drivere noi în 7.1.0-dev (commit 0077d7c20ed); nu sunt în mainline. Netestate. |
| Codec WCD938x / bolero | | ✅ (posibil nefolosit) | Upstream, dar pe tabletă captura pare să treacă prin ES7210. |
| Încărcare 5 V | PM8150B SMB5 | 🟡 | Seria Casey Connolly „smb5 support” (06.2025): patch-ul smb5 nu a intrat în mainline, dar e în 7.1.0-dev ca `qcom_pm8150b_charger.c`. |
| Încărcare rapidă 45 W | 2× SMB1396 charge pump (i2c15 0x34/0x35), USB-PD | ❌ | Există doar driverul downstream msm-4.19. PD-ul PM8150B e upstream (`qcom_pmic_typec_pdphy`). |
| Fuel gauge | TI bq27541 | ✅ | `bq27xxx_battery_i2c` |
| Wi-Fi | QCA6390 (ath11k PCI) | ✅ / 🟡 | Firmware-ul e în linux-firmware, dar `board-2.bin` nu are intrare Lenovo. Trebuie extras `bdwlan` din stock și împachetat ca variantă `Lenovo_Q706F`, plus `qcom,calibration-variant` în DTS. |
| Bluetooth | QCA6390 | ✅ | Upstream din 6.11 (pwrseq-qcom-wcn) |
| Camera spate 13 MP | OmniVision OV13B10 (module ofilm/txd) + VCM DW9768 | 🟡 | Driverul mainline e doar ACPI. Seria DT pentru Xiaomi Pad 6 (pipa, tot SM8250) e la v2 în 03.2026; 7.1.0-dev o are deja. |
| Ultra-wide 5 MP | Samsung S5K5E9 (sau GalaxyCore GC5035, în funcție de lot) | 🟡 | `s5k5e9.c` e în 7.1.0-dev. GC5035 are o serie ChromeOS v4 din 2020, nemerge-uită. |
| Față 8 MP | OmniVision OV8856 (sau S5K4H7) | ✅ / ❌ | OV8856 e în mainline cu DT; există un șablon pentru Xiaomi Pad 5 Pro (06.2026). Pentru S5K4H7 nu există driver. |
| ISP / aplicația cameră | CAMSS SM8250 + libcamera | 🟡 | CAMSS e upstream; libcamera folosește pipeline-ul `simple` cu SoftISP (calitate modestă). Nu am găsit niciun SM8250 cu cameră confirmată cap-coadă. |
| Senzori (accelerometru, lumină) | prin SLPI | 🟡 experimental | hexagonrpcd + libssc + iio-sensor-proxy. Merge pe SDM845; pe SM8250 nu am găsit nicio confirmare. Are nevoie de registry-ul din `persist` (doar citire). |
| Decodare video | Venus / Iris | ✅ | H.264/HEVC/VP9 prin GStreamer `v4l2*dec`. Browserele decodează tot software. Are nevoie de `venus.mbn` semnat Lenovo. |
| Suspend | | ❔ | Nu am găsit niciun raport pentru SM8250 mainline; ne așteptăm la s2idle. |

## Cât ne ajută munca altora

- **Qualcomm RB5 (QRB5165 = SM8250).** Are cel mai bun suport upstream: GPU, Venus, DSP-uri,
  ath11k, audio și CAMSS. Canonical nu are o imagine Ubuntu pentru RB5. meta-qcom are kernelurile
  `linux-qcom-next` și `linux-qcom_6.18`.
  - Ce preluăm: driverele, `sm8250.dtsi` și firmware-urile nesemnate (`a650_sqe.fw`, `a650_gmu.bin`).
  - Ce nu merge: blob-urile `.mbn` ale RB5. Tableta cere versiunile semnate Lenovo.
- **Xiaomi Pad 6 „pipa” și Xiaomi Pad 5 Pro „elish” (tot SM8250).** Sunt cele mai apropiate tablete;
  de la ele vin camerele OV13B10 și OV8856 și un kernel 7.1 stabil (https://git.mainlining.org/pipa-mainline/linux).
- **Snapdragon X Elite / X2 Elite (laptopuri).** De acolo preluăm userland-ul Ubuntu arm64, Mesa
  și uneltele de firmware Qualcomm. Calea de pornire (UEFI/ACPI) și GPU-ul (Adreno X1/X2) diferă.
- **Repo-uri silime încă necitite:** `deepin-lenovo-q706f` și `ArchlinuxARM-qcom-aarch64`. Sunt
  rootfs-uri de referință pentru tabletă și merită citite.

## Ordinea de lucru propusă

1. Kernelul 7.1.0-dev (în build), apoi `fastboot boot` cu initramfs-ul de diagnostic.
2. Rootfs Ubuntu 26.04 cu firmware-ul silime și `board-2.bin` Wi-Fi extras din stock.
3. Patch-ul de stylus Goodix Berlin peste 7.1, ca să avem **presiune pe stylus în GNOME**.
   E mai simplu aici decât în Mir-ul din Ubuntu Touch.
4. Audio pe toate cele patru canale și profilul UCM2.
5. Portarea driverului CTN730 pentru încărcarea stylusului.

## Kernel 7.3 (verificat 12.11.2026)

Ramura silime `7.3.0-dev` (7.3-rc3, 19.10.2026) **nu conține nimic din suportul q706f**: lipsesc
DTS-ul, panoul, es7210/as33970, încărcătorul pm8150b, s5k5e9 și haptics. Sunt doar plăcile SM8250
upstream. Noutățile din 7.3 pentru laptopurile ARM țintesc X Elite/X2 Elite, adică alte SoC-uri.
Plan: pornim întâi tableta pe 7.1.0-dev, apoi portăm setul de patch-uri q706f pe 7.3/7.4 (rebase).
