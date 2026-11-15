# Ubuntu Desktop arm64 pe TB-Q706F — inventar și plan (ramura `ubuntu-desktop-arm64`)

Creat: 12.11.2026 (document istoric de planificare; o parte descrie încă etapa cu kernelul 7.1).
La data scrierii, Ubuntu Touch era portul principal. Aici evaluăm un **Ubuntu Desktop arm64 obișnuit**
(GNOME, apt, snap) cu **kernel mainline**, adică varianta „Calea B” dintr-o decizie de arhitectură internă (nepublicată).

## 1. Ce face Canonical pe ARM și ce ne folosește

- Imaginea ISO generică arm64 de desktop este calea oficială pentru laptopurile Snapdragon X Elite
  (din 25.04) și X2 Elite (enablement în lucru). Sursa:
  https://discourse.ubuntu.com/t/ubuntu-on-arm-summer-26-update/84872
- Dispozitivele cu devicetree primesc DTB-ul prin **stubble**: un stub EFI care alege DTB-ul după
  HWID-urile SMBIOS. Sursa: https://discourse.ubuntu.com/t/what-s-new-for-generic-arm64-desktop-isos-in-25-10/66277
  - **Pentru noi:** ABL-ul tabletei nu oferă nici UEFI, nici SMBIOS, deci ISO-ul nu pornește direct.
- Kernelul generic Ubuntu 26.04 (7.0) are aproape toate driverele SM8250, ca module: DRM_MSM,
  clock-urile 8250, UFS, Q6V5_PAS (remoteproc), ATH11K_PCI, BT_QCA, SND_SOC_SM8250, PMIC_GLINK,
  FASTRPC și GOODIX_BERLIN. Pachetul livrează DTB-urile qcom upstream, dar **q706f nu e upstream**.
- **Ce preluăm de la munca pentru X Elite / X2 Elite:**
  - userland-ul arm64 (pachete, Mesa/freedreno, `qcom-firmware-extract`, pipeline-ul de kernel generic).
  - Adreno 650 (a6xx) e o generație mai veche și mai matură în freedreno decât Adreno X1/X2, deci
    accelerarea GPU are șanse bune.
  - **Nu preluăm calea de boot:** laptopurile au UEFI și ACPI/SMBIOS, tableta nu.

## 2. Stadiul mainline pentru q706f

| Element | Stare | Sursă |
|---|---|---|
| DTS `sm8250-lenovo-q706f.dts` | doar în fork-ul silime (ramurile `lenovo-q706f` 6.10, `sm8250/6.11-release` 6.11, `q706f-audio-fixup`); **nu e în torvalds/linux și nici în `sm8250/6.15-dev`** | clonă locală `sources/linux-silime-q706f` |
| Pachetul pmOS/Nura `device-lenovo-q706f` | **arhivat la 22.06.2026** (kernel 6.11.0); boot.img Android cu DTB atașat, pagesize 4096 | gitlab.nura.eco/nura/pmaports |
| Kernelul SM8250 activ în Nura | `linux-postmarketos-qcom-sm8250` 7.2 (fără q706f) | gitlab.postmarketos.org/soc/qualcomm-sm8250/linux |
| Funcții confirmate de pmOS | SoC, UFS, SD, butoane, USB-C cu role switch, touch (goodix-berlin); încărcare parțială; stylus nesuportat | wiki pmOS (tabelul complet nu a putut fi citit) |

Ce conține DTS-ul (6.10/6.11):
- **Activ:** panou `samsung,amsa26zp01` (DSI); touch `goodix,gt9916`; GPU, GMU și zap; Wi-Fi
  `pci17cb,1101` (QCA6390, ath11k) și BT `qcom,qca6390-bt`; remoteproc ADSP, CDSP și SLPI; venus;
  camss/cci; baterie `ti,bq27541`; USB-C (pm8150b_typec, fsa4480, nb7vpq904m), DP; tastatura și
  touchpad-ul pogo ca `hid-over-i2c` (marcat „untest”); simple-framebuffer.
- Pe ramura `lenovo-q706f` (6.10) amplificatoarele `cirrus,cs35l45` sunt comentate; pe
  **`sm8250/6.11-release` (cea folosită) sunt active** (4× i2c5 0x30/0x31/0x36/0x37, TDM primar),
  dar silime notează „only left channel”. Comentat: blocul WCD938x/SoundWire și senzorul `ovti,ov8856`.
  Microfoanele par să fie pe ES7210 (i2c5 @0x40) + Synaptics AS33970 (@0x41) — fără driver mainline.
  Harta completă a driverelor: `docs/DRIVERE-OPEN-SOURCE.md`.

## 3. Ce avem deja local

| Resursă | Cale | Folosire |
|---|---|---|
| Kernel silime (6.10, 6.11-release, 6.15-dev, audio-fixup) | `sources/linux-silime-q706f` | kernel + DTB |
| Firmware pmOS (adsp, cdsp, slpi, venus, a650_zap, ipa, goodix, cirrus cs35l45, hexagonfs) | `sources/lenovo-sm8250-q706f-firmware` (78 MB) | `/lib/firmware/qcom/sm8250/q706f/` |
| Firmware BT QCA6390 | partiția `bluetooth_b` din `backup/edl-2026-11-12` | se extrage read-only (FAT, mtools) |
| Board-data Wi-Fi (bdwlan) + firmware modem/dsp | partițiile `modem_b` / `dsp_b` din backup și `/vendor/firmware` pe tabletă | `ath11k/QCA6390/hw2.0/board-2.bin` |
| Unelte boot.img (mkbootimg AOSP) | container `ut-q706f-build:22.04` | împachetare boot.img v2 |
| Cross-compiler aarch64 | același container | build kernel |
| Ubuntu Touch funcțional pe `boot_b` + `userdata` | tabletă | rămâne neatins |

**Lipsește pe host:** emularea arm64 (`binfmt_misc` nu are `qemu-aarch64`). Fără ea nu putem
construi rootfs-ul Ubuntu arm64 (mmdebstrap/chroot). Instalarea cere o singură comandă cu sudo,
rulată de utilizator:

```bash
sudo apt install qemu-user-binfmt mmdebstrap   # 26.04; on 22.04/24.04: qemu-user-static binfmt-support
```

## 4. Opțiuni de boot

| | A. boot.img Android cu kernel mainline (recomandat ca prim pas) | B. U-Boot ca boot.img → EFI → GRUB | C. edk2-msm (UEFI) |
|---|---|---|---|
| Cum | ABL încarcă `Image.gz + DTB + initramfs`; rootfs `ubuntu-desktop.img` pe `userdata`, lângă `ubuntu.img` al UT | U-Boot `qcom_defconfig` + DTB q706f; GRUB pornește kernelul Ubuntu | UEFI complet (ca pe Mi Pad 5) |
| Test fără scriere | **da:** `fastboot boot` | da: `fastboot boot u-boot.img` | da |
| Coexistă cu UT | da (alt fișier rootfs; UT rămâne pe `boot_b`) | da | da |
| Kernel | silime 6.11 (sau al nostru, rebazat pe Ubuntu/Nura 7.x) | kernelul generic Ubuntu + DTB-ul nostru | la fel |
| Risc / efort | mic | mediu: SM8250 nu e confirmat pe telefoane/tablete; probleme cunoscute cu memoria raportată de ABL și cu UFS/dwc3 | mare: nu există port pentru SM8250 |

Am verificat că există șablonul pentru calea A: Xiaomi Pad 6 „pipa” (tot SM8250) rulează Ubuntu cu
un boot.img mainline. Vezi https://github.com/themojoman/xiaomi-pipa

## 5. Plan pe etape (fiecare cu criteriu de acceptare)

0. **Pregătire** (ramura aceasta): inventar, scripturi, emulare arm64 pe host. ✅ Acceptare: `scripts/desktop/check-host.sh` trece.
1. **Kernel 6.11 silime → înlocuit cu 7.1.0-dev (vezi DRIVERE-OPEN-SOURCE.md) + DTB q706f**: build în container, boot.img cu initramfs minimal (shell + telnet/USB).
   - ✅ Acceptare: `fastboot boot` → `dmesg` cu panou, touch și UFS. **Nimic nu se scrie pe tabletă.**
2. **Rootfs Ubuntu 26.04 arm64**: mmdebstrap cu `ubuntu-desktop-minimal`, firmware-ul și un utilizator.
   - Rootfs-ul devine imaginea `ubuntu-desktop.img` (~16 GB) în `/userdata`, copiată din UT, nu prin fastboot.
   - ✅ Acceptare: GDM pornește pe framebuffer.
3. **GPU (freedreno a650 + zap)**, touch, rotație, Wi-Fi ath11k, BT. ✅ Acceptare: GNOME pe Wayland, accelerat.
4. **Audio** (cs35l45: driver mainline + patch-uri silime, doar canalul stâng; microfoane ES7210 fără driver), baterie/încărcare, suspend, camere (camss, probabil ❌).
5. **Kernel modern**: portăm DTS-ul pe 7.x (Nura sm8250 sau Ubuntu generic) și, eventual, trimitem DTS-ul upstream.
   - Dacă reușim, putem folosi kernelul generic Ubuntu cu DTB-ul nostru (calea B).
6. **Dual-boot permanent**: de decis cu utilizatorul (de exemplu Ubuntu Desktop pe `boot_a`, UT pe `boot_b`, schimbare prin `fastboot set_active`).
   - Necesită verificarea efectului asupra mapării `super`.
   - **Scriere pe partiții → confirmare separată (regulă de siguranță a proiectului).**

## 6. Riscuri și limite cunoscute

- Pe mainline, camerele, încărcarea rapidă, stylusul și audio pe difuzoare (cs35l45) sunt probabil absente sau parțiale.
- DTS-ul e „untested” pe alocuri și are ~2 ani; portarea pe 7.x poate cere fix-uri.
- `userdata` e partajat cu UT: rootfs-ul desktop e un fișier separat, iar UT nu se șterge.
