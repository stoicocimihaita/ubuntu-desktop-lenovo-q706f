# KERNEL-7.3.4-STARE.md — kernelul q706f rebazat pe Linux v7.3.4 (nepornit încă)

Stare la **13.11.2026**. Totul de mai jos este **compilat și verificat static**; imaginea **nu a fost pornită** pe
tabletă. Nimic nu a fost scris pe tabletă (fără ssh, fără fastboot) și nimic nu a fost modificat în `scripts/desktop/`,
`sources/linux-desktop*`, `out/desktop/kernel/`, `out/desktop/kernel-7.3/` sau în imaginile existente. Nu s-a făcut commit.

## 1. Pe scurt

| Element | Valoare |
|---|---|
| Bază | **Linux v7.3.4** upstream stable (tag `8310b43a724c`, commit `7595a62d45ee`, 10.11.2026). Verificat azi cu `git ls-remote` pe kernel.org: este cel mai nou 7.3.y |
| `uname -r` | **`7.3.4`** (fără sufix; `LOCALVERSION` forțat gol, deci nu se schimbă între reconstruiri) |
| Imagine de boot (RAM) | `out/desktop/ubuntu-boot-7.3.4.img` (36 196 352 octeți, SHA256 `2d2fc719…735f3dd2`) |
| Module (de copiat pe rootfs) | `out/desktop/kernel-7.3.4/modules/lib/modules/7.3.4/` (480 de `.ko`, 28 MB, cu `extra/ctn730.ko`, `depmod` rulat) |
| Kernel / DTB | `out/desktop/kernel-7.3.4/Image.gz` (15 709 559 octeți), `sm8250-lenovo-q706f.dtb` (143 345 octeți) |
| Config | `out/desktop/kernel-7.3.4/config` |
| Surse | `sources/linux-desktop-7.3.4` (= tarball v7.3.4 + seria de mai jos, verificat octet cu octet) |
| Seria de patch-uri | `out/desktop/kernel-7.3.4/series/` (13 patch-uri + `README`) |
| Reconstruire | `out/desktop/kernel-7.3.4/build.sh` (`prepare` + `build`), apoi `make-image.sh` |

Sursa upstream: tag-ul `v7.3.4` adus cu `git fetch --depth 1` din `stable/linux.git` în
`out/desktop/kernel-7.3.4/upstream.git`; în plus tarball-ul `linux-7.3.4.tar.xz` de pe cdn.kernel.org, cu SHA256
`b11b6df8…5840fd1f` identic cu cel din `sha256sums.asc` de pe kernel.org (semnătura PGP a listei nu a fost verificată —
nu am importat chei). Arborele din tarball + serie este identic cu cel obținut din git.

## 2. Delta silime pe 7.3: ce s-a păstrat și ce s-a scos

**Constatare care corectează descrierea inițială:** ramura silime `7.3.0-dev` (`085dfc0609`) **nu** conține lucru pentru
SM8250. Este portul **SM8550 / Meizu 20 Infinity**, peste un mainline puțin mai nou decât tag-ul `v7.3-rc3`. Diferența
`v7.3-rc3 → 7.3.0-dev` are 199 de fișiere (clasificarea completă: `out/desktop/kernel-7.3.4/silime-delta.class`):

- **61 de fișiere sunt upstream curat** (mm, x86, infiniband, fs, `mac80211/airtime.c`…): 49 identice cu v7.3.4, 12 conținute
  în v7.3.4 (diferența se aplică invers curat). Nu sunt delta silime.
- **138 de fișiere sunt delta propriu silime.** Din ele s-a păstrat **un singur lucru**:

| Păstrat | Motiv |
|---|---|
| `drivers/pci/controller/dwc/pcie-qcom.c` — citirea `iommu-map` după `#iommu-cells` | **Necesar pentru Wi-Fi.** Din 7.3-rc, `sm8250.dtsi` are intrări `iommu-map` cu 5 celule (IOMMU cu 2 celule), dar `qcom_pcie_config_sid_1_9_0()` din v7.3.4 le citește tot ca 4 celule: a doua intrare (bus 1 = QCA6390) este interpretată greșit și tabela BDF→SID e programată cu valori fără sens. silime avea o revizie timpurie a corecției; am luat **varianta upstream** `5121d76cb9dd` „PCI: qcom: Honor IOMMU provider's #iommu-cells in qcom_pcie_config_sid_1_9_0()” (v7.4-rc1), identică cu a lui silime cu excepția unui mesaj. Corecția nu este în v7.3.4 |

| Scos | Motiv |
|---|---|
| DTS `sm8550-meizu-20-inf`, `sm8550.dtsi`, `sm8550.config`, `defconfig`, `alsa-ucm-conf/…/sm8550`, binding-urile aferente | alt dispozitiv / alt SoC |
| Drivere noi: `panel-nt37290-boe`, `qcom-hv-haptics`, `imx563`, `imx766`, `mars-focus`, `tfa98xx-downstream` (34 de fișiere), `q6apm-voice-dai` + intrările lor din Kconfig/Makefile | hardware Meizu; nefolosite de DTS-ul nostru |
| `ak7375`, `dw9768` (`dw9800k`), `qcom-rpmh-regulator` (PM8010 L6), `dispcc-sm8550`, `qcom_battmgr`, `pmic_glink`, `battery_charger.h`, `qcom-ipcc`, IPA, `ath12k` | SM8550 / periferice Meizu |
| AudioReach: `audioreach.*`, `q6apm*`, `topology.c`, `sc8280xp.c`, `sound/soc/qcom/common.c` (legătură de voce) | SM8250 folosește stiva veche `q6afe/q6asm/q6adm`; placa noastră e `sm8250.c` |
| Iris: `iris_hfi_gen2*`, `iris_ctrls`, `iris_vidc`, `iris_platform_common.h` | doar firmware HFI Gen2; SM8250 e Gen1 |
| CAMSS C-PHY (`camss-csiphy-3ph-1-0.c`, `camss-csid*`, `camss.c`) | C-PHY este permis explicit doar pe SM8550; senzorii noștri sunt D-PHY |
| GMU ca dispozitiv „component” (`a6xx_gmu.c`, `a6xx_gpu.c/.h`, `adreno_device.c`, `adreno_gpu.h`, `msm_drv.c/.h`) și „avoid losing synchronous HFI responses” (`a6xx_hfi.c`) | refacere a inițializării GPU făcută pentru Adreno 740; nu există nici în 7.1.0-dev (kernelul care merge pe tabletă), nici upstream până la v7.4-rc2. Prefer codul upstream |
| `dpu_encoder_phys_cmd.c` (TE extern) | doar panouri în mod comandă; al nostru e DSI video + DSC |
| `dsi_host.c`: parametri RC pentru DSC 1.2 | panoul nostru declară DSC 1.1, deci fără efect; restul e un `pr_warn`→`pr_debug` |
| `hci_qca.c`, `socinfo.c/.h`: adresă BT din seria SoC-ului | activ doar cu proprietatea DT `qcom,soc-serial-bd-address`, pe care nu o avem |
| `dwc3/core.c/.h`: `usb-psy-icl-unvote-on-disconnect` | activ doar cu proprietate DT pe care nu o avem |
| `net/qrtr/af_qrtr.c`, `ns.c`: „restore HELLO reply handling” | anulează o schimbare upstream din 7.3; în v7.3.4 intră în conflict cu `qrtr_endpoint_hello()` (corecție upstream pentru reluare). Prefer upstream. **De urmărit la primul boot:** serviciile QRTR ale DSP-urilor (`qrtr-lookup`, senzori) |
| `soundwire/qcom.c` (`maxport = nports + 1`), `lpass-tx-macro.c` (decimatoare active) | modificări generice silime, absente din 7.1.0-dev și din upstream; căile respective (WCD938x/TX macro) nu sunt folosite acum (sunet doar pe difuzoare) |

Scoaterea lor nu a rupt compilarea. Singurele locuri unde portarea q706f se sprijinea pe context silime au fost trei
bucăți respinse la aplicare (vezi 3.1). Simbolul de config `SND_SOC_QDSP6_APM_VOICE_DAI` dispare odată cu driverul.

## 3. Portarea patch-urilor

Ordinea din serie (peste v7.3.4 curat; toate se aplică cu `patch -p1 -F0`, fără fuzz):

| Nr. în serie | Ce este | Note de portare |
|---|---|---|
| `0001` | upstream `5121d76cb9dd` PCI `iommu-map` | vezi secțiunea 2 |
| `0002` | portarea q706f (`q706f-on-7.3.patch` reaplicat pe v7.3.4) | vezi 3.1 |
| `0101` | Goodix Berlin stylus (`0001` din proiect) | identic |
| `0102` | DTS stylus + doar difuzoare (`0002`) | identic |
| `0104` | DTS CTN730 (`0004`) | identic |
| `0105` | tastatura pogo `SW_TABLET_MODE` (`0005`) | 5 decalaje de linii; `I2C_HID_QUIRK_REPLAY_EARLY_REPORT` rămâne `BIT(9)`, fără coliziune (upstream BIT(0)…BIT(7), portarea BIT(8)). v7.3.4 a mai adăugat un quirk ITE/Yoga Slim în aceeași tabelă |
| `0106` | panou 60 Hz (`0006`) | identic |
| `0107` | limite de încărcare baterie (`0007`) | identic |
| `0109` | stylus tip/hover/tilt (`0009`) | identic |
| `0110` | încărcător: limită de curent + termic (`0010`) | identic |
| `0111` | as33970 fără descărcare de firmware la probe (`0011`) | identic |
| `0201` | backport UFS (vezi 4) | curat |
| `0202` | backport GCC CX (vezi 4) | curat |

Numerotarea `01xx` păstrează numărul patch-ului din `scripts/desktop/patches/` (+100). Patch-urile `.needs-approval` nu
sunt în serie. Cele nouă patch-uri ale noastre s-au aplicat toate fără respingeri și fără fuzz; **niciunul nu este
înlocuit de ceva din v7.3.4** (stylusul Goodix nu a intrat upstream, driverul de încărcător e tot cel silime).
DTS-ul plăcii, `goodix_berlin_core.c`, `hid-lenovo-q706f-kbd.c`, `as33970.c`, `qcom_pm8150b_charger.c` și
`panel-samsung-amsa26zp01.c` sunt **identice octet cu octet** cu cele din arborele rc3.

### 3.1 `q706f-on-7.3.patch` pe v7.3.4

64 de fișiere; 61 s-au aplicat direct (cu decalaje). Rezolvate manual:

- `drivers/hid/hid-multitouch.c`: upstream a ocupat `BIT(26)` cu `MT_QUIRK_IGNORE_FEATURE_ID_MISMATCH` și a adăugat
  singur variabila `td` în `mt_get_feature()`. `MT_QUIRK_NO_MODE_REPORTS` (touchpadul ELAN al husei) a devenit **`BIT(27)`**;
  declarația `td` din patch nu mai e necesară. (`quirks` este `__s32`, bitul 27 încape.)
- `drivers/input/misc/Kconfig`: intrarea `INPUT_QCOM_SPMI_HAPTICS` avea drept vecin `INPUT_QCOM_HV_HAPTICS` (silime, scos);
  așezată după `INPUT_PMIC8XXX_PWRKEY`.
- binding `dongwoon,dw9768.yaml`: contextul conținea `dw9800k` (silime); adăugat doar `dongwoon,dw9763`.
- `drivers/misc/fastrpc.c` (două bucăți cu fuzz, verificate manual): v7.3 final a rescris alocarea memoriei pentru Audio PD
  (regiune rezervată din DT în loc de alocare la cerere). Modificările portării (`pgid`/`tgid`) stau peste noul cod fără
  schimbare funcțională. **Consecință upstream:** Audio PD din ADSP cere acum nodul `adsp-rpc-remote-heap`, care există
  în `sm8250.dtsi`.
- `drivers/media/i2c/dw9768.c`: fuzz doar din lipsa liniei `dw9800k`.

Ce lipsește în continuare față de 7.1 este neschimbat față de raportul rc3 (corecția DP EDID/ELD, buclele de reîncercare
pentru ceasurile lpass, modificarea IRQ-ului de handover q6v5).

## 4. Corecții 7.4-rc evaluate pentru backport

Patch-urile sunt în `out/desktop/kernel-7.3.4/patches-backport/` (și în serie cele aplicate). Commit-urile au fost aduse
individual de pe kernel.org în `upstream.git` (`refs/backport/*`); `upstream-log.git` a fost folosit doar pentru căutare.

| Corecție | Commit upstream | Rezultat |
|---|---|---|
| ufs-qcom: echilibrul ceasurilor de lane | `f07317a8d57f` „scsi: ufs: ufs-qcom: Enable only lane clocks in lane clock APIs” | **aplicat** (`0201`), curat, compilează. Înlocuiește `0013-ufs-qcom-lane-clks-enable-balance.patch.needs-approval`: conține și verificarea `is_lane_clks_enabled` din `0013`, și cauza de fond (API-urile de lane porneau *toate* ceasurile nodului). Numele ceasurilor din `sm8250.dtsi` (`tx_lane0_sync_clk`, `rx_lane0_sync_clk`, `rx_lane1_sync_clk`, `lanes-per-direction = 2`) corespund |
| SM8250: domeniul CX pentru GCC | `389a0144c511` „arm64: dts: qcom: sm8250: Add GCC CX power domain” | **aplicat** (`0202`), doar DT (o linie). Cu codul gdsc din v7.3.4 GDSC-urile GCC devin subdomenii ale RPMh CX (`gdsc_register()` face asta când furnizorul are domeniu). Curățenia de driver `361b375a4bb1` „clk: qcom: gcc-sm8250: Use common clock controller probe data” și binding-ul `98e936c9d46a` **nu** au fost luate (nu sunt necesare pentru efect). Este o schimbare de comportament pe toate GDSC-urile GCC (USB, UFS, PCIe); dacă apare ceva ciudat la alimentare, acesta e primul patch de scos |
| ath11k: IRQ la suspendare | `e56c9d429ba0` „wifi: ath11k: fix unbalanced IRQ enable/disable during suspend/resume” | **sărit — nu se aplică și nu e necesar.** Repară o regresie introdusă de `f7a74e131d3f` („disable interrupts during firmware crash recovery”), care există doar în 7.4-rc; v7.3.4 nu are codul respectiv. Păstrat ca `…patch.not-applicable` |
| (în plus) PCI `iommu-map` | `5121d76cb9dd` | **aplicat** (`0001`), vezi secțiunea 2 |

Corecțiile din 7.3 final menționate în raportul rc3 (timeout-ul de inițializare GMU, rotunjirea byte-clock DSI, referința
de ceas la probe UFS, handover q6v5, `hci_qca`, tcpm, `power_supply_core`, `pinctrl-spmi-gpio`, ath11k) sunt toate în
v7.3.4 prin bază; nu a fost nevoie de niciun patch pentru ele.

## 5. Configurație

Procedura rc3, plus un fragment: `config-pmos-q706f-6.11` → `olddefconfig` → `merge_config.sh` cu `q706f-desktop.config`,
`q706f-7.3-renames.config` (copie în directorul 7.3.4) și **`out/desktop/kernel-7.3.4/q706f-7.3.4-extra.config`** →
`olddefconfig`. Avertismente la `olddefconfig`: aceleași două ca la rc3 (`IPV6=m`, `CRYPTO_LIB_CURVE25519_GENERIC=m`).

Diferențe față de configul rc3 (`out/desktop/kernel-7.3/config`):

| Schimbare | Origine |
|---|---|
| `CONFIG_FW_DEVLINK_SYNC_STATE_TIMEOUT=y` | fragmentul nou (cerut) |
| `CONFIG_CMA_SIZE_MBYTES=64` (era 32) | fragmentul nou (cerut) |
| **86 de drivere de ceas/pinctrl/interconnect pentru alte SoC-uri dezactivate** (30 erau `=y`, 56 `=m`): Eliza, Glymur, Hawi, Kaanapali, Maili, Milos, Nord, Shikra, X1E80100/X1P42100, IPQ5210/5424/9650, QCS615/8300, SA8775P, SC8180X, SM4450/6115/6350/8150/8750 | fragmentul nou. Lista = tot ce e activ din `drivers/clk/qcom`, `drivers/pinctrl/qcom`, `drivers/interconnect/qcom` și **nu** era activ în configul 7.1. Rămân neschimbate: `SM_GCC/DISPCC/GPUCC/VIDEOCC/CAMCC_8250`, `CLK_GFM_LPASS_SM8250`, `PINCTRL_SM8250` (+ `_LPASS_LPI`), `PINCTRL_QCOM_SPMI_PMIC`, `INTERCONNECT_QCOM_SM8250` (+ RPMh, BCM voter, OSM L3), `QCOM_CLK_RPMH`, `QCOM_GDSC` |
| `# CONFIG_SND_SOC_QDSP6_APM_VOICE_DAI` dispare | driver silime scos |
| `ARM64_ERRATUM_3821522=y`, `ARM64_WORKAROUND_BROKEN_AMU_CONSTCNT=y`, `HAVE_EXIT_THREAD=y` | simboluri noi în v7.3.4 |

Restul este identic cu rc3 (inclusiv `HW_RANDOM_QCOM=m`, `VIDEO_QCOM_IRIS=m` + `VENUS=m`, tot ce e pe calea de boot `=y`).
Module: 480 (rc3: 542; cele 62 dispărute sunt toate din `clk/qcom`, `pinctrl/qcom`, `interconnect/qcom`; niciun modul nou).
Față de 7.1 lipsesc aceleași ca la rc3 (`authenc`, `authencesn`, `cbc` acum built-in; `iio-trig-interrupt`, `hisi-trng-v2`);
`qcom-rng`, `at24`, `at25` doar s-au mutat în alt director.

## 6. Rezultatul compilării

- Container `ut-q706f-build:22.04`, GCC 11.4.0 `aarch64-linux-gnu-`, `-j16`, `O=/work/out/desktop/kernel-7.3.4/build`.
- `Image.gz`, `dtbs`, `modules`: **fără erori și fără niciun avertisment** (`grep -c warning build.log` = 0). Avertismentul
  din rc3 (`qcom_geni_serial_poll_rx_fifo_locked` nefolosit) a dispărut: în v7.3.4 funcția e sub
  `#ifdef CONFIG_SERIAL_QCOM_GENI_CONSOLE`.
- `modules_install` cu `INSTALL_MOD_STRIP=1` → `out/desktop/kernel-7.3.4/modules`.
- `ctn730`: copie privată în `out/desktop/kernel-7.3.4/ctn730/`, compilat fără avertismente
  (`vermagic: 7.3.4 SMP preempt mod_unload aarch64`), instalat în `extra/`, apoi `depmod -b`.
- Imagine: `make-image.sh` este `out/desktop/kernel-7.3/make-image.sh` cu căile schimbate plus o verificare de mărime:
  header v0, pagină 4096, DTB lipit după `Image.gz`, `kernel_offset 0x8000`, `ramdisk_offset 0x01000000`,
  `second_offset 0x00f00000`, `tags_offset 0x100`. Antetul rezultat a fost comparat câmp cu câmp cu `ubuntu-boot.img` și
  `ubuntu-boot-7.3.img`: aceleași adrese, aceeași linie de comandă
  `console=tty0 clk_ignore_unused pd_ignore_unused loglevel=7 rdinit=/init q706f.rootimg=ubuntu-desktop.img`.
  Initramfs: 20 335 854 octeți (busybox, `initramfs-init`, modulele 7.3.4, același firmware).

### Mărime și margine

| | 7.1 | 7.3-rc3 | **7.3.4** |
|---|---|---|---|
| `Image.gz` | 15 343 474 | 15 918 040 | **15 709 559** |
| `Image.gz` + DTB | 15 486 512 | 16 061 365 | **15 852 904** (0xF1E568) |
| sfârșit în memorie (`kernel_offset` + mărime) | 0xECCE30 | 0xF593B5 | **0xF26568** |
| margine până la `ramdisk_offset` 0x01000000 | 1 257 936 | 683 083 | **891 544 octeți (~871 KiB)** |

Scoaterea balastului a adus 208 KB la `Image.gz` față de rc3 (mai puțin decât cei 575 KB estimați acolo; o parte din
creștere vine din nucleul 7.2/7.3, nu din drivere). Kernelul depășește în continuare `second_offset` nominal (0x00F00000)
cu ~157 KB, ca la rc3; nu există „second”, iar ABL își alege singur adresele — rămâne primul suspect dacă `fastboot boot`
e refuzat sau tableta rămâne în fastboot după „Booting OKAY”.

## 7. Verificări statice

Unealtă: `out/desktop/kernel-7.3.4/static-checks.py` (parser FDT propriu, compară noduri/proprietăți cu phandle-urile
rezolvate; potrivește fiecare `compatible` cu aliasurile `of:` din `modules.alias` și `modules.builtin.modinfo`).

### 7.1 DTB

- **Față de DTB-ul rc3** (`dtb-compare-rc3-vs-7.3.4.txt`): 1181 de noduri în ambele, **o singură diferență**:
  `/soc@0/clock-controller@100000` (GCC) primește `power-domains = <&rpmhpd CX>` — backportul `0202`. Nimic altceva.
- **Față de DTB-ul 7.1** (`dtb-compare-7.1-vs-7.3.4.txt`): aceeași diferență plus exact cele patru din raportul rc3, toate din
  `sm8250.dtsi` upstream: `video-codec@aa00000` (domeniul `mmcx`, tabela OPP 240/338/366/444 MHz), nodul
  `adsp-rpc-remote-heap` + `memory-region`/`qcom,vmids` pe `fastrpc` ADSP, `reg` PDC 0x30000 → 0x10000, `iommu-map` PCIe cu
  o celulă în plus. Nicio diferență din DTS-ul plăcii.

### 7.2 Drivere pentru fiecare `compatible`

Tabele: `dt-compat-drivers-{7.1,7.3-rc3,7.3.4}.tsv`, comparație în `dt-compat-compare.txt`.

- 7.1: 314 noduri, 218 cu driver. 7.3-rc3: 315 / 218. **7.3.4: 315 / 217.**
- **Niciun nod activ care avea driver pe 7.1 nu rămâne fără driver pe 7.3.4.** Singurele pierderi față de 7.1 sunt cele
  două noduri **dezactivate** `qcom,geni-debug-uart` (ca la rc3).
- Driver schimbat față de 7.1 (ca la rc3): `video-codec@aa00000` `venus_core` → `qcom_iris`; `smem` → `qcom_smem`;
  tastatura/touchpadul pogo au și aliasul `i2c_hid_acpi_prp0001` pe lângă `i2c_hid_of`. `pen-charger@28` apare cu `ctn730`.
- Față de rc3, singura diferență: `gmu@3d6a000` nu mai are alias propriu. Pe rc3 îl avea doar datorită driverului
  „component” GMU al lui silime (scos, secțiunea 2); în upstream și pe 7.1 GMU-ul este inițializat de driverul GPU prin
  `qcom,gmu`, fără potrivire proprie. Nu este o regresie față de 7.1.

### 7.3 Seria

`build.sh prepare` rulat pe o extragere proaspătă a tarball-ului într-un director separat, apoi `diff -r` față de
`sources/linux-desktop-7.3.4`: **identic** (95 998 de fișiere, aceleași biți de execuție). `gen-series.sh` regenerează
seria identic din `tree.git`.

## 8. Comenzi pentru integrator

Niciuna nu a fost rulată. Prima scrie pe rootfs-ul tabletei (doar un director nou de module), a doua pornește din RAM.

**1. Modulele pe tabletă** (din worktree; `/usr/lib/modules/7.1.0` nu este atins, numele directorului e diferit):

```sh
cd <rădăcina acestui depozit>
R=7.3.4
tar -C out/desktop/kernel-7.3.4/modules/lib/modules --exclude="$R/build" -cf - "$R" | ssh q706f-ubuntu "sudo sh -ec '
  rm -rf /usr/lib/modules/$R; mkdir -p /usr/lib/modules/$R
  tar -C /usr/lib/modules/$R -xf - --strip-components=1 -m
  chown -R 0:0 /usr/lib/modules/$R; depmod $R; sync'"
ssh q706f-ubuntu "ls /usr/lib/modules; ls /usr/lib/modules/$R/extra"
```

Fără acest pas kernelul pornește doar cu ce e built-in (ecran, UFS, USB/NCM), fără touch, Wi-Fi, BT, sunet, DSP-uri.

**2. Pornire din RAM** (aceeași secvență ca `scripts/desktop/kernel-cycle.sh ramboot`, cu imaginea 7.3.4):

```sh
# oprește curat încărcarea pen-ului, apoi repornește în bootloader
ssh q706f-ubuntu 'sudo sh -c "[ -e /sys/class/misc/ctn730/enable ] && echo 0 > /sys/class/misc/ctn730/enable; sleep 2; sync; (sleep 1; systemctl reboot --reboot-argument=bootloader) >/dev/null 2>&1 &"'
until fastboot devices | grep -q fastboot; do sleep 3; done; sleep 6
fastboot reboot bootloader          # ABL-ul intrat din Linux e inițializat pe jumătate: o repornire a lui
sleep 25; until fastboot devices | grep -q fastboot; do sleep 2; done
fastboot getvar max-download-size   # trebuie 805306368; altfel „Restart bootloader” din meniul tabletei
fastboot getvar current-slot        # trebuie a
fastboot boot out/desktop/ubuntu-boot-7.3.4.img
```

**3. Verificare:** `ssh q706f-ubuntu uname -r` → `7.3.4`, `lsmod | wc -l` > 1, apoi
`scripts/desktop/kernel-cycle.sh check` și lista de verificări a portului (document de lucru nepublicat). `fastboot boot` nu scrie
nimic; un reboot readuce kernelul 7.1 de pe `boot_a`. Dacă pornirea eșuează și ABL trece pe celălalt slot:
`fastboot set_active a`.

De urmărit în plus față de lista rc3, din cauza schimbărilor de aici:

1. **Wi-Fi** (`0001`): `dmesg | grep -iE "pcie|ath11k|iommu|smmu"` — fără „Malformed iommu-map” și fără erori SMMU la
   pornirea `ath11k_pci`.
2. **UFS** (`0201`): `dmesg | grep -i ufs` fără „failed to get …_sync_clk”; în `/sys/kernel/debug/clk/clk_summary` contorul
   de enable al `gcc_ufs_phy_axi_clk` nu mai crește în timp.
3. **GCC CX** (`0202`) + **`FW_DEVLINK_SYNC_STATE_TIMEOUT`**: `dmesg -l err,warn | grep -iE "gdsc|rpmhpd|sync_state|genpd"`,
   USB/UFS/PCIe funcționale după ~10 s de la boot (momentul în care expiră timeout-ul și se eliberează voturile de boot).
4. **QRTR / DSP-uri** (revenirea silime scoasă): `cat /sys/class/remoteproc/*/state`, `qrtr-lookup`, senzorii.
5. **GPU** (GMU pe calea upstream, nu „component”): `dmesg | grep -iE "adreno|gmu"`, sesiunea GNOME accelerată.
6. **Touchpadul husei** (bitul de quirk mutat pe `BIT(27)`): cursorul și gesturile cu două degete.
7. **CMA 64 MiB**: `grep -i cma /proc/meminfo`.

## 9. Fișiere

| Cale | Ce este |
|---|---|
| `out/desktop/ubuntu-boot-7.3.4.img` | imaginea de test pentru `fastboot boot` |
| `out/desktop/kernel-7.3.4/modules/lib/modules/7.3.4/` | modulele de copiat în `/usr/lib/modules/` |
| `out/desktop/kernel-7.3.4/{Image.gz,sm8250-lenovo-q706f.dtb,config,build.log,build-run.log}` | kernel, DTB, config, loguri |
| `out/desktop/kernel-7.3.4/build.sh`, `make-image.sh` | reconstruire (tarball + serie → arbore → build → imagine) |
| `out/desktop/kernel-7.3.4/series/` + `README` | seria numerotată peste v7.3.4 curat și cum se reface arborele |
| `out/desktop/kernel-7.3.4/patches-backport/` | corecțiile upstream 7.4-rc (aplicate + cea respinsă) |
| `out/desktop/kernel-7.3.4/q706f-7.3.4-extra.config`, `q706f-7.3-renames.config` | fragmentele de config suplimentare |
| `out/desktop/kernel-7.3.4/static-checks.py`, `dtb-compare-*.txt`, `dt-compat-*.tsv`, `dt-compat-compare.txt` | verificările statice |
| `out/desktop/kernel-7.3.4/silime-delta.files`, `silime-delta.class` | delta silime și clasificarea ei față de v7.3.4 |
| `out/desktop/kernel-7.3.4/upstream.git` | v7.3.4, v7.3-rc3, ramurile silime și commit-urile de backport (superficial) |
| `out/desktop/kernel-7.3.4/tree.git`, `g`, `gen-series.sh` | istoricul arborelui (un commit per patch), în afara surselor |
| `out/desktop/kernel-7.3.4/dl/` | tarball-ul, semnătura lui și `sha256sums.asc` |
| `out/desktop/kernel-7.3.4/ctn730/`, `initramfs/`, `work/` | copia modulului ctn730, initramfs-ul despachetat, loguri de lucru |

Ca seria să devină setul de patch-uri al proiectului: `series/` înlocuiește `q706f-on-7.3.patch` + `scripts/desktop/patches/`
la un build din tarball-ul v7.3.4, cu cele două fragmente adăugate la `merge_config`. `0013…needs-approval` devine inutil
(înlocuit de `0201`).

## 10. Observații

- `git apply` rulat dintr-un subdirector al worktree-ului sare în tăcere peste fișierele din afara lui; seria se aplică
  cu `patch -p1` (așa face `build.sh`).
