# DE-FACUT.md — ce rămâne de făcut pentru Ubuntu 26.04 Desktop pe q706f (kernel 7.3.4)

> **Notă 20.11.2026:** documentul nu a mai fost actualizat după 13.11.2026. Starea curentă e în `README.md` și `docs/STATUS-UBUNTU.md`.

Stare la **13.11.2026**. Starea componentelor: `docs/STATUS-UBUNTU.md`. Istoricul testelor: jurnalul de lucru (nepublicat).
Regulile de siguranță citate în tabele: **R1** scrieri pe partiții, **R2** întâi din RAM,
**R4** scrieri persistente în cipuri, **R5** suspendare doar cu proprietarul lângă tabletă, **R6** `apt` doar cu
`--no-install-recommends`, **R7** cod extern compilat doar cu acord, **R8** plafonul difuzoarelor, **R9** date personale;
**§7** = publicări doar la semnalul proprietarului.

Efort: **S** ≤ o oră · **M** o sesiune · **L** mai multe sesiuni. „Proprietar” = trebuie să fie lângă tabletă.
„Aprobare” = cere acord explicit înainte (și regula care o cere).

## Ordinea recomandată (primele 15)

1. A1 — înregistrare scurtă de microfon pe 7.3.4 (riscul de regresie cel mai mare)
2. A2 — sunetul ascultat pe 7.3.4, stereo L/R
3. F1 — pinning apt pentru pachetele interzise + `Install-Recommends "false"`
4. A3 — încărcarea cu încărcător de perete cu `0110` (ICL, terminare la 4,25 V, temperatură)
5. E1 — parolă reală pentru `ubuntu`
6. E2 — SSH doar cu cheie + chei de gazdă regenerate
7. E3 — test OSK în ecranul de login cu tastatura detașată (condiție pentru E4)
8. E4 — decizia autologin + blocarea ecranului (și keyring-ul, E5)
9. A4 — tastatura pogo atașată/detașată, tastare, touchpad
10. A5 — vârful, hover-ul și înclinarea pen-ului (`0109`) + o aplicație de desen
11. B1 — o captură de cameră pe 7.3.4
12. E6 — `--unsafe-mode` scos, E7 — politica sudo
13. C1 — măsurarea consumului în suspendare pe 7.3.4
14. F3 — rutină de backup pentru `/home` și `/etc`
15. C2 — linia de comandă fără `clk_ignore_unused pd_ignore_unused` (din RAM)

## (A) Blocante pentru folosirea zilnică

| # | Ce | De ce | Efort | Proprietar | Aprobare | Ordine |
|---|---|---|---|---|---|---|
| A1 | Înregistrare scurtă (5–10 s) de la microfoanele interne pe 7.3.4, ascultată de proprietar; comparat dmesg-ul SoundWire cu 7.1 | pe 7.3.4 s-au scos modificările silime `soundwire/qcom.c` (`maxport = nports + 1`) și `lpass-tx-macro.c` (decimatoare), cu argumentul greșit că acele căi nu sunt folosite — microfoanele merg exact pe WCD938x → TX macro; în dmesg apar `din-ports/dout-ports mismatch` | S | da | nu | 1 |
| A2 | Ton de test pe 7.3.4, stânga/dreapta, fără a ridica volumul | sunetul n-a fost ascultat pe 7.3.4; difuzoarele n-au protecție | S | da | nu (plafonul UCM rămâne, R8) | 2 |
| A3 | Încărcare cu încărcător de perete: curentul ales automat (DCP 2 A), oprirea la 4,25 V, comportarea la 45 °C | `0110` (ICL + protecție termică) n-a fost testat pe încărcător de perete pe niciun kernel | M | da | nu | 4 |
| A4 | Tastatura pogo: atașare/detașare (mod tabletă ↔ laptop), tastare, touchpad, gesturi | netestat fizic pe niciun kernel; quirk-ul touchpad-ului s-a mutat pe `BIT(27)` în 7.3.4 | S | da | nu | 9 |
| A5 | Pen: vârf, hover, înclinare (`evtest`/`libinput debug-tablet`) + Xournal++ | `0109` n-a fost testat niciodată cu pen-ul | S | da | nu | 10 |
| A6 | Rotația fizică și comutarea 60/120 Hz pe 7.3.4; butoanele de volum; 10 degete | confirmate doar pe 7.1 sau deloc | S | da | nu | 16 |
| A7 | Cauza pentru care shell-ul pierde prima cerere „screen on” după trezire | azi se ocolește cu reîncercări la 0,6 s și 1,5 s | M | parțial | nu | 20 |
| A8 | Reverificat remote desktop-ul (FreeRDP3) și MAC-ul Wi-Fi de fabrică pe 7.3.4 | confirmate doar pe 7.1 | S | nu | nu | 21 |

## (B) Lipsuri de hardware

| # | Ce | De ce | Efort | Proprietar | Aprobare | Ordine |
|---|---|---|---|---|---|---|
| B1 | Captură de cameră pe 7.3.4 (cele 3), apoi Snapshot, autofocus, video | capturi reale doar pe 7.1; CAMSS a fost reasamblat pe 7.3.4 | S | da | nu | 11 |
| B2 | Tuning libcamera SoftISP pentru OV13B10/S5K5E9/OV8856 | imagine întunecată | L | da (imagini) | nu | 30 |
| B3 | Decodare video HW cu `qcom_iris` (GStreamer `v4l2h264dec`/`v4l2vp9dec`, fluster) | netestată niciodată; driverul s-a schimbat din `venus` în `qcom_iris` | M | nu | nu | 24 |
| B4 | USB OTG (stick), DisplayPort pe USB-C, microSD, audio BT, tastatură BT, vibrații | netestate pe Ubuntu | S fiecare | da | nu | 25 |
| B5 | Încărcare rapidă 45 W: port SMB1396 din kernelul GPL Lenovo | nimic upstream; azi doar 5 V | L | da (teste) | da (kernel nou: R2, apoi R1) | 40 |
| B6 | Protecția difuzoarelor (firmware Cirrus „Protection” + calibrare) | singura limită e plafonul −14,75 dB | L | da | da (R8; rețetă inexistentă upstream) | 41 |
| B7 | AS33970 (microfon far-field): `0011b` + descărcarea firmware-ului la fiecare boot | dezactivat intenționat | M | da | **da (R4: scriere în cip; patch `needs-approval`)** | 42 |
| B8 | Wi-Fi: board data Lenovo (`0012` + `setup-wifi-board.sh`), domeniul de reglementare (`config.regdom`) | board data generică; phy-ul ignoră țara | S–M | nu | da (patch/config `needs-approval`; un board file greșit = fără Wi-Fi) | 31 |
| B9 | RTC persistent (`0008`, offset în SDAM2 al PMIC) | fără rețea, ora rămâne în urmă după o oprire lungă | S | nu | **da (R4: scriere persistentă în PMIC, partajată cu Android)** | 32 |
| B10 | Corecțiile 7.1 care lipsesc pe 7.3.4: DP EDID/ELD, reîncercările ceasurilor LPASS, IRQ-ul handover q6v5 | pierdute la rebase | M | nu | da (kernel nou: R2) | 33 |

## (C) Consumul în suspendare

Pe 7.1: ~154 mA cu ecranul stins (142 mA cu `sync_state` forțat). Pe 7.3.4 nemăsurat, iar `cxsd/aosd/ddr` rămân 0,
deci SoC-ul tot nu intră în stările adânci. Referință: un SM8550 a ajuns la ~23 mA după ce a deblocat `sync_state`
(GMU fără driver, nod crypto fără driver) și voturile de interconectare.

| # | Ce | De ce | Efort | Proprietar | Aprobare | Ordine |
|---|---|---|---|---|---|---|
| C1 | Măsurare s2idle pe baterie pe 7.3.4 cu `tools/q706f-suspend-measure.sh.proposed` (600 s) | cifra de referință pe kernelul actual | S | da | da (R5; scriptul e `.proposed`) | 13 |
| C2 | Imagini de test fără `clk_ignore_unused`/`pd_ignore_unused` (variantele P1–P3 din `make-testboot.sh.power.patch.needs-approval`), din RAM | flag-urile țin ceasurile/domeniile de la bootloader pornite | M | da | da (R2; P3 poate da ecran negru) | 15 |
| C3 | `0014` (dezactivează `crypto@1dfa000`) și `0015` (dezactivează PCIe2) | QCE fără driver blochează `sync_state`; PCIe2 e legătura modemului de pe TB-Q706Z | S | da | da (`needs-approval`, R2) | 17 |
| C4 | Seria upstream „drm/msm: Attach a driver to GMU” (RFT, 05.2026) sau un driver GMU minimal | GMU fără driver ține `gcc`/`gpucc` în așteptarea `sync_state` | M | da | da (R2) | 18 |
| C5 | De ce ADSP-ul nu doarme (voturi LPASS, pinctrl lpi); auditul voturilor de interconectare în suspendare | rămâne treaz și fără PipeWire | M | da | nu (doar citire) / da pentru patch-uri | 19 |
| C6 | Hook-ul de somn extins (`q706f-sleep.proposed`), îmbinat cu logica `wake-intent` din hook-ul instalat | oprește senzorii/CTN730, opțional BT, și jurnalizează consumul | S | da | da (`.proposed`, R5) | 22 |

## (D) Amprenta

Evaluare: `docs/EVALUARE-AMPRENTA-2026-11-13.md`; tabelul cu etapele, actualizat pentru 7.3.4, e în **§13** al acelui
document (nu se dublează aici). Pe scurt: „GO condiționat, pe etape”, 7–14 sesiuni. Mainline 7.3.4 nu poate încărca
TA-ul `goodixfp`; calea e seria ne-upstream `qcom-qseecom-tee` + `goodix-fp-spi`, de rebazat pe 7.3.4.

| Etapă | Ce | Punct de decizie | Aprobare |
|---|---|---|---|
| 0 | Rebase + build pe gazdă, nimic pe tabletă | — | regula R7 (cod extern compilat) |
| 1–3 | Kernel din RAM, module, supplicant, TA în `/lib/firmware` | redare stereo L/R după eliberarea GPIO 26 | da (R2, pachete) |
| 4 | Încărcarea TA-ului în QSEE | **GO/NO-GO**: acceptă TZ-ul Lenovo încărcarea din mainline? | da |
| 5 | Detectarea senzorului, IRQ | — | da |
| 6 | Prima înrolare | **GO/NO-GO**: cere TA-ul cheie HMAC/Gatekeeper? Dacă da → oprire (etapa 8 recomandat NO-GO) | da |
| 7 | fprintd + `gdm-fingerprint` | — | da (R6) |
| 9 | Kernelul final pe `boot_a` | — | da (R1) |

Prioritate: după (A), (E) și (C1). Proprietar lângă tabletă: da, din etapa 1.

## (E) Curățenia de securitate

Tableta de lucru e o instalare manuală de bring-up. Imaginea implicită (fără `BRINGUP=1`) nu mai pune sudo fără
parolă, autologin, `--unsafe-mode` și keyring-ul necriptat, dar rootfs-ul de pe tabletă n-a fost refăcut.
Starea live a acestor resturi pe 7.3.4 n-a fost reverificată. **(P)** = alegerea e a proprietarului.

| # | Ce | De ce | Efort | Proprietar | Aprobare | Ordine |
|---|---|---|---|---|---|---|
| E1 | Parolă reală pentru `ubuntu` (proprietarul o tastează) | parola implicită e publică | S | da | parola o alege și o scrie doar proprietarul | 5 |
| E2 | `sshd`: `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin no`, cheia PC-ului în `authorized_keys`; chei de gazdă regenerate (`ssh-keygen -A`) și `known_hosts` actualizat | SSH accesibil pe Wi-Fi, Tailscale și USB; arborii vechi de rootfs aveau chei de gazdă comune | S | nu | da (schimbă accesul de la distanță; calea USB rămâne plasa de siguranță) | 6 |
| E3 | Test fizic: ecranul de login GDM cu tastatura pogo detașată → apare OSK-ul GNOME și se poate tasta parola | altfel, după oprirea autologin-ului, proprietarul poate rămâne blocat în afara interfeței | S | da | nu | 7 |
| E4 | **(P)** Autologin oprit + `lock-enabled=true` (recomandat) | oricine ține tableta are sesiunea, keyring-ul, Tailscale | S | da | da (P) | 8 |
| E5 | **(P)** Keyring: cu E4, parola RDP mutată în keyring-ul de login deblocat de PAM, keyring-ul necriptat șters; amprenta certificatului RDP setată (fără TOFU) | parola RDP a PC-ului stă necriptată pe disc | S | nu | da (P) | după E4 |
| E6 | **(P)** `--unsafe-mode` scos (repus temporar doar la depanare) | orice client D-Bus al sesiunii poate rula JS în shell; afectează capturile de la distanță | S | nu | da (P) | 12 |
| E7 | **(P)** sudo: `NOPASSWD:ALL` scos sau restrâns; adaptate scripturile | root fără parolă pentru oricine are sesiunea sau cheia SSH | S–M | nu | da (P) | 12 |
| E8 | **(P)** Firewall minimal: SSH doar pe `usb0` și pe interfața VPN, dacă există | niciun firewall; tableta intră în rețele Wi-Fi străine | S | nu | da (P) | 23 |
| E9 | Gadgetul USB (SSH pe USB) pornit la cerere, nu permanent | suprafață de atac la orice cablu | S | nu | da (e calea de recuperare) | 26 |
| E10 | **(P)** Criptarea rootfs-ului (LUKS pe imagine) sau acceptarea riscului, scrisă în README | bootloader deblocat → oricine cu acces fizic citește tot | L | da | da (P) | 43 |

## (F) Actualizări și întreținere

| # | Ce | De ce | Efort | Proprietar | Aprobare | Ordine |
|---|---|---|---|---|---|---|
| F1 | `/etc/apt/preferences.d/q706f-forbidden` cu `Pin-Priority: -1` pentru `qbootctl`, `droid-juicer`, `qcom-phone-utils`, `flash-kernel`, `linux-image-*`, `linux-generic*`; `APT::Install-Recommends "false";` în `/etc/apt/apt.conf.d/`; ambele oglindite în `overlay/` | regula R6 e azi doar procedurală; un singur `apt install` neatent poate scrie fanioanele A/B sau reporni tableta | S | nu | da (configurație nouă pe tabletă; întărește R6) | 3 |
| F2 | Strategia de kernel: `.deb` local (module + `boot.img` + sha256) **fără** flash automat; scrierea pe `boot_a` rămâne o comandă separată, cu acord | actualizarea kernelului e azi complet manuală; un hook automat ar încălca R1 | M | nu | da (R1 la fiecare scriere) | 27 |
| F3 | Backup: `/home` și `/etc` pe PC (rsync/restic prin USB sau Tailscale); copia completă a imaginii doar din initramfs sau din UT (imagine nemontată) | tot sistemul e un singur fișier pe `userdata`, fără backup | S | nu | da (P: unde se ține copia) | 14 |
| F4 | Pachete locale pentru `libssc` și `iio-sensor-proxy` patch-uit (azi în `/usr/local`) | apt nu știe de ele; un update al unității din arhivă le poate ocoli | M | nu | da (R7, cod extern compilat) | 34 |
| F5 | Extensiile GNOME (GJS OSK, Dash to Panel, ArcMenu) — de reverificat la orice upgrade de release (GNOME 51+); pe 26.04 rămâne GNOME 50.x | extensiile din `~/.local` nu le actualizează apt | S | nu | nu | la upgrade |
| F6 | Rebase pe 7.4.y după 7.4.1–7.4.3 (probabil LTS); backporturile `0001`/`0201`/`0202` devin native | întreținere pe termen lung | M–L | da (test) | da (R2, apoi R1) | 35 |
| F7 | Pornit din RAM `out/desktop/ubuntu-boot.img` refăcut din `scripts/desktop` (sha `c69cab3a…`) | build-ul reproductibil n-a fost pornit niciodată; pe `boot_a` e `2d2fc719…` | S | da | da (R2) | 28 |
| F8 | Curățenie pe disc: `sources/linux-desktop-7.3`, `-7.3.4`, `linux-kfix`, `linux-power`, `out/desktop/kernel-7.3*` (artefactele 7.1 de revenire rămân) | spațiu | S | nu | da (ștergere) | 29 |
| F9 | `install.sh` rulat cap-coadă pe o tabletă, ideal reinstalând tableta de lucru dintr-o imagine implicită (închide și majoritatea punctelor din E) | instalatorul n-a rulat niciodată pe dispozitiv | M–L | da | **da (R1: scrieri pe partiții)** | 36 |
| F10 | `README.md` și `docs/UBUNTU-DESKTOP-ARM64.md` aduse la 7.3.4 | încă descriu 7.1 pe alocuri | S | nu | nu | 37 |

## (G) Publicare

Făcut: exportul public (acest depozit), cu istoric nou și fără bloburi proprietare. Fișierele UCM ale lui
silime nu sunt redistribuite: `scripts/desktop/ucm/fetch-ucm.sh` le descarcă la build și aplică modificările locale.

## Propuneri în așteptare (`*.needs-approval`, `*.proposed`)

| Fișier | Ce face |
|---|---|
| `scripts/desktop/patches/0008-q706f-dts-rtc-offset.patch.needs-approval` | celula nvmem „offset” pentru RTC în SDAM2 al PMIC — scriere persistentă în PMIC (R4) |
| `scripts/desktop/patches/0011b-q706f-dts-as33970-senary-capture.patch.needs-approval` | reactivează AS33970 și legătura „SENARY Capture”; inutil fără descărcarea firmware-ului în cip (R4) |
| `scripts/desktop/patches/0012-q706f-dts-wifi-calibration-variant.patch.needs-approval` | `qcom,calibration-variant` pentru board data Lenovo; de verificat numele proprietății citite de ath11k pe 7.3.4 |
| `scripts/desktop/patches/0014-q706f-dts-disable-unused-qce.patch.needs-approval` | dezactivează nodul `crypto@1dfa000` (fără driver), care bloca `sync_state` |
| `scripts/desktop/patches/0015-q706f-dts-disable-unused-pcie2.patch.needs-approval` | dezactivează PCIe2 (legătura modemului de pe TB-Q706Z); economie doar cât tableta e trează |
| `scripts/desktop/make-testboot.sh.power.patch.needs-approval` | `BASE_CMDLINE` pentru imagini de test fără flag-urile de bring-up (P1–P3); textul despre `boot_a` e depășit |
| `scripts/desktop/q706f-desktop.config.power.needs-approval` | opțiuni de depanare PM (`PM_DEBUG`, `PM_SLEEP_DEBUG`) și varianta `CRYPTO_DEV_QCE=m`; punctul 1 (`FW_DEVLINK_SYNC_STATE_TIMEOUT`) e deja activ pe 7.3.4 |
| `scripts/desktop/q706f-desktop.config.regdom.needs-approval` | `CFG80211_CERTIFICATION_ONUS` + `ATH_REG_DYNAMIC_USER_REG_HINTS`, ca ath11k să accepte țara setată (conformitatea trece la utilizator) |
| `scripts/desktop/tools/q706f-suspend-measure.sh.proposed` | măsoară un ciclu s2idle pe baterie: consum, contoare `qcom_stats`, furnizori nesincronizați, noduri ICC |
| `scripts/desktop/overlay/usr/lib/systemd/system-sleep/q706f-sleep.proposed` | hook de somn extins (senzori, CTN730, opțional BT oprit, jurnal de consum); cere îmbinare cu `wake-intent` din hook-ul instalat |
