# STATUS-UBUNTU.md — matricea de hardware pentru Ubuntu 26.04 Desktop (mainline) pe q706f

> **Notă 20.11.2026:** documentul nu a mai fost actualizat după 13.11.2026. Starea curentă (somn adânc la fiecare suspendare cu patch-urile 0118 și 0121, ≈52 mA peste noapte) e în `README.md`.

Stare la **13.11.2026**: Ubuntu 26.04.1 arm64, GNOME 50.1 (Wayland), **kernel Linux 7.3.4** (stabil kernel.org +
seria de 13 patch-uri din `scripts/desktop/patches/`: `0001`, `0002`, `0101`–`0111`, `0201`, `0202`) pe `boot_a`,
rootfs `/userdata/ubuntu-desktop.img`. 7.3.4 e pe `boot_a` din 13.11.2026, cu două porniri curate de pe partiție.
Revenire pregătită: `out/desktop/ubuntu-boot-7.1.img` + modulele `7.1.0` lăsate pe tabletă.

Completat **strict din dovezile consemnate** în jurnalul de lucru al proiectului (nepublicat; intrările din 13.11.2026) și din verificările pasive
din 13.11.2026 (doar citire, prin SSH). Lista de lucru prioritizată e în `docs/DE-FACUT.md`. Matricea portului
Ubuntu Touch (alt kernel, altă stivă) este în depozitul acelui port și nu se aplică aici.

Statusuri: ✅ funcțional, cu test consemnat · 🟡 parțial / testul complet nerulat · ❌ nu merge (cu motiv) ·
⬜ netestat nicăieri · **netestat pe 7.3.4** = a mers pe 7.1, nereverificat pe kernelul actual · ➖ n/a

Cine a verificat: **[F]** = confirmat fizic de proprietar · **[S]** = doar prin SSH (comenzi, loguri, `evtest`), fără
confirmarea umană a efectului. **👤** = poate fi confirmat doar de proprietar (auz, imagine, mână pe tabletă).

## Matricea

| Componentă | Status | Dovadă (test, dată) | Cauză / pasul următor |
|---|---|---|---|
| Boot de pe `boot_a` | ✅ 7.3.4 [S+F] | 13.11: `fastboot flash boot_a` cu 7.3.4, sha256 recitit identic; două porniri de pe partiție (după flash și după `systemctl reboot`): `running`, 0 unități eșuate | 20 de cicluri de boot și oprirea completă (power-off) nerulate |
| Ecran DSI 2560×1600 | ✅ 7.3.4 [S] | 13.11: captură corectă la bootul 7.3.4; `card0-DSI-1` connected | — |
| Rată de refresh 120/60 Hz | 🟡 netestat pe 7.3.4 | 7.1 `#4` [F]: comutarea din Setări are efect vizibil (patch `0006`, acum `0106`, identic) | 👤 o comutare din Setări pe 7.3.4 |
| Luminozitate | 🟡 [S] | backlight reglabil din sysfs | slider-ul GNOME neconsemnat; schimbările rapide pot bloca panoul; erori `dsi_err_worker` sporadice pe 7.1 → luminozitatea automată oprită intenționat |
| GPU Adreno 650 | ✅ 7.3.4 [S] | 13.11: GMU v2.1.8, firmware încărcat; Vulkan (Turnip) folosit de PdfCraft prin wgpu; glmark2 3275 pe 7.1 | glmark2 nerulat pe 7.3.4; eroare cosmetică `a650_sqe.fw` la prima cerere |
| Decodare video HW | ⬜ | pe 7.3.4 nodul video e legat de `qcom_iris` (nu `venus`); „Iris Decoder/Encoder” apar în PipeWire | test cu GStreamer `v4l2h264dec`/`v4l2vp9dec`; browserele generice nu folosesc V4L2 |
| Touchscreen | ✅ 7.3.4 [S] | 13.11: touch prezent și folosit; `evtest` 162 de atingeri pe 7.1 | 👤 10 degete / pinch netestate |
| Stylus pe ecran (presiune) | ✅ 7.1 [S+F] / dispozitiv prezent pe 7.3.4 | 7.1 `#3`: `ABS_PRESSURE` 0–4095; 7.3.4: „Goodix Berlin Stylus” enumerat | 👤 **vârful, hover-ul și înclinarea după `0109` netestate cu pen-ul pe niciun kernel**; nicio aplicație de desen încercată |
| Pen prin Bluetooth (buton, baterie) | ✅ 7.3.4 [S+F] | 13.11: pen conectat la fiecare pornire 7.3.4, baterie în upower | reconectarea automată a unui pen adormit (`q706f-pen-dock`) netestată |
| Indicatorul Bluetooth care „pâlpâia” | ✅ rezolvat | 13.11: pen-ul își pierduse cheia de legătură (`PIN or Key Missing`, reconectări la ~0,9 s); re-împerecheat → 15 s de btmon fără reconectări, 0 erori HoG | cauza pierderii cheii **necunoscută**; de urmărit dacă revine |
| Încărcarea wireless a pen-ului (CTN730) | ✅ 7.1 [F+S] / prezent pe 7.3.4 | 7.1 `#5`: „Charging” → „Full 100”, oprire singură; 7.3.4: `ctn730 1041 detected`, pen atașat, `Full` | un ciclu de încărcare de la zero pe 7.3.4 neconsemnat |
| Rotație / accelerometru | 🟡 netestat pe 7.3.4 | 7.1 `#4` [F]: rotația automată merge; 7.3.4 [S]: `HasAccelerometer=true`, `iio-sensor-proxy` + `hexagonrpcd` active | 👤 rotirea fizică pe 7.3.4 |
| Senzor de lumină | 🟡 [S] | 7.3.4: `HasAmbientLight=true` | nefolosit (luminozitate automată oprită, vezi „Luminozitate”) |
| Busolă | ⬜ | apare în `monitor-sensor` (7.1) | valori neverificate |
| Tastatură pogo + touchpad | 🟡 [S] | 7.3.4: dock „Lenovo Tab P12 Pro keyboard dock” și touchpad `04F3:31F3` detectate; quirk-ul touchpad-ului mutat pe `BIT(27)` | 👤 tastarea, touchpad-ul, gesturile, **atașarea/detașarea fizică** neconsemnate (nici pe 7.1) |
| Tastatură pe ecran (sesiune) | ✅ 7.3.4 [F] | 13.11: GJS OSK v53 (`scripts/desktop/setup-gjs-osk.sh`), proprietarul confirmă că e bună la scris | deschiderea automată la atingerea unui câmp de text neconfirmată |
| Tastatură pe ecran (ecranul de login GDM) | 🟡 | în greeter rămâne OSK-ul GNOME (extensiile utilizatorului nu rulează acolo); imaginea îl forțează pentru GDM | 👤 netestat fizic (tableta folosește autologin); obligatoriu înainte de a opri autologin-ul |
| Wi-Fi QCA6390 | ✅ 7.3.4 [S] | 13.11: ping 2/2 la fiecare pornire; conectat pe 2,4 GHz (40 MHz) pe 7.3.4, pe 5 GHz HE80 pe 7.1 | 100 MB descărcați nerulat; board data generică; domeniul de reglementare (phy self-managed) de lămurit |
| MAC Wi-Fi de fabrică | 🟡 netestat pe 7.3.4 | 7.1 `#5` [S]: aplicat la boot cu prefixul corect | reverificare pe 7.3.4 |
| Bluetooth (HID) | ✅ 7.3.4 [S] | pen BLE funcțional; RFCOMM/BNEP în kernel | — |
| Bluetooth audio, tastatură BT | ⬜ | pe Ubuntu neconsemnate (pe UT ✅) | 👤 căști/boxă + o tastatură BT |
| Difuzoare (4× CS35L45) | 🟡 netestat pe 7.3.4 | 7.1 [F]: ton auzit după S16LE; 7.3.4 [S]: placa + sink-urile prezente | 👤 **sunetul nu a fost ascultat pe 7.3.4**; stereo L/R neconfirmat; **fără protecție de excursie/termică**, plafon UCM −14,75 dB (nu se ridică) |
| Microfoane (WCD938x, AMIC1/3) | 🟡 netestat pe 7.3.4 — **risc** | 7.1 [S]: tonul de 1 kHz regăsit în înregistrare (RMS 180/305 față de 0,4); 7.3.4: sursa „Internal microphones” prezentă | pe 7.3.4 s-au scos modificările silime `soundwire/qcom.c` și `lpass-tx-macro.c`, exact pe calea microfoanelor; în dmesg apar nepotriviri de porturi SoundWire. 👤 primul test: o înregistrare scurtă |
| Microfon far-field (AS33970) | ❌ intenționat | cipul nu are firmware în flash; `0111` oprește descărcarea la probe | reactivare doar cu `0011b…needs-approval` + acord separat pentru scrierea în cip |
| Camere (OV13B10, S5K5E9, OV8856) | 🟡 netestat pe 7.3.4 | 7.1 `#3` [S]: capturi 1280×720 cu imagine reală de la toate trei; 7.3.4 [S]: cele 3 camere în libcamera și PipeWire | 👤 nicio captură pe 7.3.4; imagine întunecată (SoftISP fără tuning), autofocus, video, Snapshot neconfirmate |
| Lanternă | ⬜ | nicio intrare de flash în `/sys/class/leds` | dispozitivul LED de flash nu e expus |
| Vibrații | ⬜ | dispozitivul `spmi_haptics` există | netestat |
| Buton power | ✅ 7.3.4 [F] | 13.11: stinge/aprinde ecranul; trezește din s2idle | aprinderea cere uneori reîncercarea de la ~1,5 s (vezi „Suspend”) |
| Husă (senzor hall) | ✅ 7.3.4 [F] | 13.11: închiderea stinge ecranul; deschiderea trezește din s2idle real | — |
| Butoane volum | ⬜ | `gpio-keys` prezent | 👤 netestate |
| Baterie / gauge bq27541 | ✅ [S] | 7.3.4: procent, tensiune, curent, temperatură; tensiune maximă 4,25 V (`0107`) | recalibrare completă (un ciclu) neconsemnată |
| Încărcare de la PC (SDP 500 mA) | ✅ 7.3.4 [S] | 13.11: „Charging” 500 mA | — |
| Încărcare cu încărcător de perete | 🟡 netestat cu `0110` | 7.1: 4,12 → 4,245 V, oprire în CV la 4,25 V, dar cu `current_max` ridicat manual înainte de patch-ul ICL | 👤 **ICL automat (DCP 2 A), terminarea și zonele termice netestate pe niciun kernel** |
| Încărcare rapidă 45 W | ❌ | pompele SMB1396 au doar driver downstream msm-4.19 | port din kernelul GPL Lenovo; nimic upstream |
| Protecție termică la încărcare | 🟡 cod, netestat | `0110`: zone 0/15/45/50 °C, mod prudent 1,5 A / 4,20 V | verificare la cald, cu proprietarul lângă tabletă |
| Termic SoC | 🟡 [S] | cooling CPU + GPU legate la zone | throttling netestat la cald; nicio zonă „skin” |
| Suspend s2idle (intrare/trezire) | ✅ 7.3.4 [F] | 13.11: intrare, trezire din power, trezire din husă după 10 s de somn real; fix `q706f-screen-keys` (suspendare amânată 3 s și anulabilă, cerere de trezire prin alarmă RTC, reîncercări „screen on”) testat OK | ecranul cere uneori reîncercarea la ~1,5 s după trezire (cauza din shell necunoscută); calea cu alarma RTC (`wake-intent`) neexersată |
| Consum în suspendare | ❌ 7.1 / ⬜ nemăsurat pe 7.3.4 | 7.1 `#5`: ~154 mA (142 mA cu `sync_state` forțat); 7.3.4 [S]: contoarele `cxsd/aosd/ddr` tot 0 după 3 suspendări | SoC-ul nu intră în stările adânci; suspecți: `clk_ignore_unused pd_ignore_unused` pe cmdline, GMU fără driver, ADSP treaz. Vezi `DE-FACUT.md` (C) |
| USB gadget (NCM + SSH, 172.16.42.1) | ✅ [S] | folosit la toată dezvoltarea | activ permanent (de făcut la cerere) |
| SSH prin Tailscale | ✅ 7.3.4 [S] | 13.11: funcțional după repornire | tableta adoarme când ecranul e stins → conexiunea cade |
| USB OTG / host | ⬜ | `port_type=[dual]` | 👤 stick USB |
| DisplayPort pe USB-C | ⬜ | `card0-DP-1` disconnected; corecția DP EDID/ELD din 7.1 lipsește pe 7.3.4 | 👤 monitor extern |
| Audio pe USB-C | ⬜ | — | netestat |
| microSD | ⬜ | `mmc0` există | 👤 card |
| Amprentă (Goodix în QSEE) | ❌ | fără driver mainline; evaluare „GO condiționat, pe etape” | `docs/EVALUARE-AMPRENTA-2026-11-13.md`, plan în `DE-FACUT.md` (D) |
| Ceas (RTC) | 🟡 [S] | RTC-ul PMIC e doar citire; ora restaurată la boot (`85-hwclock.rules`) și prin NTP | după o oprire lungă fără rețea ora rămâne în urmă; soluția persistentă (`0008`) așteaptă aprobare |
| Securitate kernel (LSM) | ✅ 7.3.4 [S] | `capability,landlock,yama,apparmor` | — |
| Memorie (zram) | ✅ [S] | zram 3,7 GB, governor `schedutil` | — |
| Desktop la distanță (tabletă → PC) | 🟡 netestat pe 7.3.4 | 7.1 [S]: FreeRDP3 → desktopul PC-ului afișat | parola RDP stă în keyring-ul necriptat (vezi `DE-FACUT.md` E) |
| GPS / modem | ➖ | TB-Q706F e doar Wi-Fi | — |
| Actualizări | 🟡 | `apt` funcționează (doar cu `--no-install-recommends`); kernelul se reconstruiește și `boot_a` se rescrie manual, cu acord | fără pinning apt pentru pachetele interzise (vezi `DE-FACUT.md` F) |
| Dual-boot cu slotul `b` (UT) | ✅ [S] | Ubuntu pe `a`, Ubuntu Touch neatins pe `b`; comutare cu `fastboot set_active` | comutarea cere PC |
| Instalator `scripts/desktop/install.sh` | ⬜ | doar `--dry-run` și initramfs simulat | rulare cap-coadă pe o tabletă |

## Ce poate confirma doar proprietarul (stare la 13.11.2026)

Sunet ascultat pe 7.3.4 (stereo L/R) · o înregistrare de microfon ascultată · imaginea camerelor pe 7.3.4 · vârful,
hover-ul și înclinarea pen-ului · tastatura pogo atașată/detașată, tastare și touchpad · încărcarea cu încărcător de
perete · rotirea fizică și comutarea 60/120 Hz pe 7.3.4 · OSK-ul din ecranul de login · butoanele de volum, 10 degete.

## Riscuri cunoscute pe 7.3.4

- **Microfoanele** (vezi rândul din matrice): primul test cu proprietarul trebuie să fie o înregistrare scurtă.
- `0202` (domeniul CX al GCC, backport din 7.4-rc1) e primul de scos dacă apare ceva ciudat la USB/UFS/PCIe.
- Lipsesc față de 7.1: corecția DP EDID/ELD, buclele de reîncercare pentru ceasurile LPASS, modificarea IRQ-ului de
  handover q6v5 (`docs/KERNEL-7.3.4-STARE.md`).
- Mesaj nou `QRTR failed to announce new service`, aparent la reinițializarea Wi-Fi după trezire; funcțional fără efect.
- Bootloader-ul: `reboot bootloader` din 7.3 a ajuns de două ori într-un fastboot instabil; nimic nu se scrie până ABL
  nu răspunde consecvent de 6 ori (`kernel-cycle.sh` așteaptă asta).
