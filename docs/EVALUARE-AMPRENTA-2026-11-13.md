# Evaluare: cititorul de amprente Goodix pe Ubuntu (q706f) cu stiva `goodix-fp-spi-linux`

Data: 2026-11-13. Studiu de fezabilitate, fără nicio modificare pe tabletă.
Actualizat 2026-11-13 (partea a doua): profilul 2 decodat complet, întrebarea HMAC, review `core.c`,
GPIO 26 lămurit, patch-uri de profil scrise și testate. Vezi secțiunea 11.

Legendă pentru fiecare afirmație: **[V]** = verificat direct (fișier citit, binar dezasamblat, compilare,
citire de pe tabletă); **[D]** = dedus din ce am verificat; **[R]** = afirmat de proiectul de referință,
neverificat de noi; **[N]** = necunoscut.

---

## 0. Verdict pe scurt

**GO condiționat, pe etape.** Portarea e plauzibilă, dar nu e „drop-in":

- Platforma de referință (Xiaomi Pad 5 Pro 5G) are **același SoC (SM8250)**, **aceeași magistrală SPI
  ținută de TrustZone (GPIO 40–43)** și **aceeași linie de IRQ (GPIO 23)** ca tableta noastră. [V]
- Aplicația de încredere există în firmware-ul nostru (`goodixfp`), e semnată de Lenovo și vorbește
  **aceeași familie de protocol** (aceleași numere de comenzi 1000–1099, aceleași coduri de eroare,
  același antet de cerere de 128 de octeți, aceleași fișiere sigilate). [V]
- **Dar structurile de date diferă**: antetul comun al comenzilor are 96 de octeți la noi față de 100
  la referință, iar structura de IRQ are 327584 de octeți față de 327624. Driverul libfprint are
  offseturile referinței scrise fix în cod, deci ne trebuie un „profil 2" propriu. [V]
- Partea de kernel se aplică și se compilează curat pe arborele nostru 7.1. [V]
- Trei lucruri pot opri proiectul și nu se pot afla decât pe hardware: dacă TrustZone-ul Lenovo
  acceptă încărcarea TA-ului din kernelul mainline; dacă TA-ul acceptă înrolarea fără cheia HMAC
  pe care HAL-ul stock o trimite la deschidere; cablajul real (GPIO 26 e deja folosit în DTS-ul nostru).

Efort estimat: 6–12 sesiuni, cu variație mare în faza de pornire pe hardware. Șansă de reușită
estimată de mine: bună pentru „TA încărcat + senzor detectat", incertă pentru „înrolare + deblocare GDM".

---

## 1. Hardware și device tree

### 1.1 Ce folosește senzorul

| Resursă | Valoare | Sursă |
|---|---|---|
| Nod stock | `goodix_fp`, `compatible = "goodix,fingerprint"`, nod de platformă (nu copil SPI) | [V] `out/desktop/stock-fw/dtbo17.dts` |
| IRQ | TLMM GPIO 23, front crescător | [V] dtbo + `gf_spi.c` (`IRQF_TRIGGER_RISING`) |
| Reset | TLMM GPIO 26 (activ pe 0: puls 0 timp de 3 ms) | [V] dtbo + `platform.c` |
| Alimentare | TLMM GPIO 131 (`fp-gpio-envdd`), pus pe 1 la deschidere și lăsat așa | [V] `platform.c` |
| `vdd-supply` | `pm8150a_l7` = `vreg_l7c_ts_3p0` la noi (comun cu touchscreen-ul); driverul stock **nu** apelează regulatorul | [V] dtbo `__fixups__` + `gf_spi.c` |
| Magistrala SPI | QUP SE14 (`spi@880000`), pini GPIO 40–43 | [D] vezi mai jos |
| Ceas SPI | necontrolat de Linux (`AP_CONTROL_CLK` nedefinit în driverul stock) | [V] `gf_spi.c` |

Cum am stabilit magistrala: în `sm8250.dtsi`, GPIO 40–43 sunt pinii `qup_spi14` / `qup_i2c14`. [V]
În DT-ul stock de bază, `spi@880000` și `i2c@880000` sunt `disabled`, iar nodul `goodix_fp` nu are nicio
referință la un controler SPI. [V] TA-ul importă `qsee_spi_open / qsee_spi_full_duplex / qsee_spi_write`,
deci vorbește el însuși pe SPI. [V] Numărul exact al instanței din TA (`g_spi_device_id`) nu l-am
extras. [N]

### 1.2 Este magistrala a TrustZone pe unitatea noastră?

Da, după toate indiciile:

- DTS-ul nostru mainline are `gpio-reserved-ranges = <40 4>`, identic cu `sm8250-xiaomi-elish-common.dtsi`
  (platforma de referință). [V]
- Pe tabletă, `/sys/kernel/debug/gpio` nu listează GPIO 40–43 (rezervate). [V]
- Starea citită acum de pe tabletă: GPIO 131 intrare, 0 (senzor **nealimentat**); GPIO 26 ieșire, 1;
  GPIO 23 intrare cu pull-down. [V]

### 1.3 Conflict găsit: GPIO 26

În `sm8250-lenovo-q706f.dts`, GPIO 26 este cerut de `audio4_1p8_supply` (regulator fix, `always-on`,
pinctrl `spkr_1_sd_n_active`), folosit ca `vdd-batt-supply` de cele patru amplificatoare cs35l45. [V]
În overlay-ul stock, GPIO 26 apare **doar** ca reset al cititorului de amprente; amplificatoarele folosesc
GPIO 49 (activare 1,8 V) și GPIO 127 (reset). [V] Numele `spkr_1_sd_n` vine din placa de referință
Qualcomm (WSA881x), deci cel mai probabil e o moștenire greșită în portul mainline. [D]

Consecință: driverul de senzor nu poate cere GPIO 26 cât timp îl ține regulatorul audio. Trebuie scos
`gpio`/`pinctrl` din `audio4_1p8_supply` și retestat sunetul pe difuzoare. Efectul asupra audio nu e
verificat. [N]

### 1.4 Nodul cerut de stiva de referință și cum ar arăta al nostru

Driverul de referință (`drivers/input/misc/goodix_fp_spi.c`) cere: `compatible = "goodix,gf3626"`,
`interrupts`, `reset-gpios`, `vdd-supply` (regulator), opțional `firmware-name`. [V]
Nu știe de un GPIO de alimentare, dar acesta se modelează ca `regulator-fixed` cu `gpio = <&tlmm 131 ...>`,
fără nicio modificare în driver. [D]

Ciornă (neaplicată nicăieri): `out/desktop/fp-eval/patches/q706f-fingerprint-dts-draft.txt`.

| Proprietate | Referință (elish) | q706f |
|---|---|---|
| `interrupts` | TLMM 23, front crescător | TLMM 23, front crescător |
| `reset-gpios` | TLMM 125, activ pe 0 | TLMM 26, activ pe 0 |
| `vdd-supply` | `vreg_l10a_3p0` | regulator fix pe GPIO 131 (alimentat din `vreg_l7c_ts_3p0`, de confirmat) |
| `firmware-name` | `gfenu` | `goodixfp` |

Observație: comentariul din DTS-ul nostru „Fingerprint reader power (goodix_fp)" de la `vreg_l16a_2p7`
nu e susținut de DT-ul stock. [V]

Modelul exact al senzorului nu e cunoscut. [N] HAL-ul și TA-ul sunt generice pentru familia „Milan"
și conțin, printre altele, `GF_CHIP_3626ZS1` (cipul referinței) și `GF_CHIP_3658DN1/2/3`. [V]

---

## 2. Aplicația de încredere (TA)

### 2.1 Prezență, nume, semnătură

- Fișiere în `modem_b` (imagine FAT), director `image/`: `goodixfp.mdt` (7260 octeți) și
  `goodixfp.b00`–`goodixfp.b07`. [V] Extrase în `out/desktop/stock-fw/fp/image/` (ignorat de git).
- ELF pe 32 de biți ARM, 8 antete de program; `.mdt` = 308 octeți de antete + 6952 octeți de hash.
  **Aceeași formă ca `gfenu`** (7260 = 308 + 6952, 8 segmente). [V] Imagine asamblată: 5 369 506 octeți
  (referința: 4 993 345). [V, calcul]
- Numele sub care îl încarcă HAL-ul: `ta_name = "goodixfp"` în `libgf_ca.so`; căi căutate:
  `/vendor/firmware_mnt/image`, `/system/etc/firmware`, `/firmware/image`; `ta_buf_size = 4096`. [V]
- Semnătură: lanț de certificate **LENOVO Attestation CA → LENOVO Root CA 1**, certificat de atestare
  emis la 2024-08-07. [V] Deci e semnat de OEM, nu de Qualcomm. Dacă imaginea e legată de model prin
  câmpurile de atestare nu am decodat. [N] Concluzie practică: se folosește **numai** copia din
  firmware-ul propriu al tabletei.
- În aceeași partiție mai există `fingerpr.*` (TA-ul Qualcomm pentru senzori ultrasonici), nefolosit
  de HAL-ul Goodix. [D]
- Dată de build în TA: `2019.12.09_20:00:58`; biblioteca whitebox din CA: `1.0.0-2017-12-21`. [V]

### 2.2 Cât de aproape e de protocolul documentat la referință

**Identic** (verificat prin dezasamblarea `libgf_ca.so` / `libgf_hal.so` de la noi):

| Element | Referință | La noi |
|---|---|---|
| Interfața CA exportată | `gf_ca_open_session`, `gf_ca_invoke_command`, `gf_ca_tee_auth`, `get_key_from_keymaster`, `gf_sec_ion_*`, `gf_ca_logdump` | aceleași simboluri [V] |
| Transport | `QSEECom_send_modified_cmd`, cerere 128 + răspuns 64 de octeți | la fel [V] |
| Antet cerere | adresa fizică la +0 (4 octeți), token +8, clasă +12, timp (ms de la miezul nopții) +16, nivel log +24, id comandă +32, lungime +36 | la fel [V] |
| Răspuns | stare la +128, indicator excepție TA la +132 (→ 1049 `TA_DEAD`) | la fel [V] |
| Clase de comenzi | 1 normal, 2 CA/utilizator, 3 test, 4 dump | la fel [V] |
| Numere de comenzi | 1000 DETECT_SENSOR … 1016 IRQ, 1017/1018, 1079–1081, 1086 AUTHENTICATE_FINISH, 1089 GET_DEV_INFO, 1097/1098 | toate comenzile documentate la referință au același număr în tabelul HAL-ului nostru (99 de intrări) [V] |
| Coduri de eroare | 116 definite; 1011, 1013, 1045, 1047, 1049, 1057, 1062, 1064, 1070, 1088, 1094, 1117 | 116 intrări în tabelul HAL-ului; valorile verificate (23) coincid [V] |
| Stocare | `fts_*` peste `qsee_fts_*` / `qsee_sfs_*`; `finger_%d_%d.so`, `_bak`, `auth_token_%d.so`, `gf_calibration.so`, `gf_otp_info.so`, `gf_nav_base.so`, `gf_fdt_base.so` | la fel [V] |
| Driver kernel | ioctl magic `'g'`, netlink 25, `GF_NET_EVENT_IRQ = 1`, nod de platformă | la fel [V] |

**Diferit** (acestea sunt nepotrivirile concrete):

| Element | Referință | La noi | Efect |
|---|---|---|---|
| Antetul comun al payload-ului | 100 octeți | **96 octeți** | toate corpurile de comandă sunt deplasate cu −4 |
| SET_ACTIVE_GROUP / INIT_FINISHED | 104 | **100** | |
| INIT | 348 | **344** | |
| ENUMERATE | 184 | **180** | |
| ENROLL | 180, grup la +100, token la +110 | **176**, grup la +96 (token probabil la +106 [D]) | |
| SAVE / REMOVE | SAVE 112; grup +100, deget +104 | **108 / 188**, grup +96, deget +100 | |
| AUTHENTICATE | grup la +100 | **120**, grup la +96 | |
| AUTHENTICATE_FINISH | 124; grup +112, deget +116, ieșiri +120/+121 | **120**; +100 ← IRQ+100, +104 ← IRQ+96, grup +108, deget +112, ieșiri +116/+117 | |
| GET_DEV_INFO | 5500 | **5496** | |
| PRE_ENROLL | 112 | **104** | |
| IRQ: dimensiune | 327624 | **327584** | |
| IRQ: mască / operație / navigare | +100 / +104 / +136 | **+96 / +100 / +132** (rolul câmpurilor +96/+100 dedus prin analogie [D]) | |
| IRQ: grup / deget (/ eșantioane rămase) | 0x4fce4 / 0x4fce8 / 0x4fcec | **0x4fcc0 / 0x4fcc4** / 0x4fcc8 [D] | −36 |
| IRQ: câmpuri de armare | 327049 = 0x02000000; 327096 = 512; 327616 = 1 | **327013; 327060; 327580** (aceleași valori) | −36 |
| Director obiecte sigilate | `/data/vendor/fpdump/` | **`/data/vendor_de/0/fpdata/`** | doar altă cale în directorul supplicantului |
| Fișiere în plus | — | `gf_broken_check_history_record.so`, `gf_memmgr_config.so`, `/persist/data/ifaa_fplist` | supplicantul le tratează generic |
| Strat „whitebox" în CA | `gf_ca_tee_auth` e stub [D din adresele publicate] | implementat (AES/HMAC whitebox, comenzile 110/111), dar **dezactivat implicit**: proprietatea `gf.debug.whitebox.enabled` nu e setată nicăieri în imaginile stock | fără efect cât timp rămâne dezactivat [D] |
| Cheie HMAC la deschidere | nedocumentat | CA-ul trimite **întotdeauna** clasa 2, comanda 109, 256 octeți obținuți de la TA-ul `keymaster64` | vezi 2.4 |

DETECT_SENSOR: 520 la referință; la noi probabil 516, alocarea n-am decodat-o complet. [D]

Notă despre sursa de referință: documentația ei dă pentru grup/deget offseturi zecimale (327396…) care
nu corespund cu cele din codul ei (0x4fce4…). Am comparat cu **codul** (`gfharness.c`, driverul libfprint).

**Concluzie:** aceeași generație de protocol Goodix „gf", dar altă revizie a structurilor. Profilul
`GOODIX_QSEE_PROFILE_V1` din libfprint nu se poate folosi nemodificat.

### 2.3 Stocare sigură, `persist`, RPMB

- TA-ul cere fișiere prin două servicii „listener": 10 (fișiere simple) și 28672 (GPFS, obiecte
  sigilate). [R, confirmat prin simbolurile TA-ului nostru: `qsee_sfs_*`, `qsee_fts_*`] [V]
- Supplicantul de referință tratează căile Android ca nume **în interiorul** directorului său de stare
  (`/var/lib/qsee-supplicant`). [R, din README-ul supplicantului; codul lui nu l-am revizuit] La noi, șabloanele ar ajunge în
  `/var/lib/qsee-supplicant/data/vendor_de/0/fpdata/`, iar `fingerprint_version` și `ifaa_fplist` în
  `/var/lib/qsee-supplicant/persist/data/`.
- **Nu e nevoie de nimic din partiția `persist` reală.** Calibrarea (`gf_calibration.so`, OTP, baze) e
  generată de TA la primul `INIT`. [R] Partiția `persist` nu se montează și nu se atinge.
- **RPMB:** în TA nu există niciun șir sau simbol legat de RPMB. [V] Supplicantul nu implementează
  listenerul 8192 (RPMB), iar kernelul nostru are `CONFIG_RPMB` dezactivat. [V] Prin această stivă nu
  există o cale de scriere în RPMB. [D]
- Obiectele sunt sigilate cu o cheie legată de dispozitiv; Linux stochează doar text cifrat. [R]

### 2.4 Ce s-ar putea scrie persistent în afara sistemului de fișiere Linux

Din ce am putut stabili: **nimic**. Încărcarea TA-ului îl ține doar în memoria TrustZone până la
descărcare sau repornire. [R] Înrolarea scrie doar fișiere prin supplicant. [R + V pe lista de fișiere]

Ce rămâne neverificat pe unitatea noastră: [N]

- dacă QSEE-ul Lenovo ține vreun contor propriu (anti-rollback al TA-ului) la încărcare;
- dacă TA-ul are blocare (lockout) persistentă. Are contor de eșecuri (`g_authenticate_fail_count`,
  `gf_ta_lockout`); pare a fi doar în memorie. [D]

**Ce ar putea fi ireversibil și trebuie evitat explicit:**

1. Comenzile de test care rescriu firmware/configurație în senzor: 1003, 1004, 1053–1056
   (`DOWNLOAD_FW`, `DOWNLOAD_CFG`, `TEST_DOWNLOAD_*`, `TEST_RESET_FWCFG`). Nu se trimit niciodată.
2. Orice experiment cu Gatekeeper/Keymaster (`keymaster64`) pentru un token semnat. Acolo starea e
   comună cu Android (credențialul de blocare a ecranului). Rămâne în afara acestui plan.
3. Scrierea în `persist` reală. Nu e cazul în această stivă.

### 2.5 Cheia HMAC și tokenul de înrolare (cea mai mare necunoscută de protocol)

La referință, înrolarea merge cu un token de 69 de octeți care conține doar provocarea (`challenge`),
fără semnătură. [R] La noi, CA-ul stock trimite după deschidere o cheie HMAC luată de la `keymaster64`
(`send_hmac_key`: clasa 2, comanda 109). [V] TA-ul are `gf_ta_set_hmac_key`, `GF_ERROR_UNTRUSTED_ENROLL`,
`GF_ERROR_INVALID_HAT_VERSION`, `invalid challenge detected`. [V]

Nu știm dacă TA-ul nostru acceptă tokenul „doar cu provocare" fără cheia HMAC. [N] Dacă nu:

- varianta A: reproducem `send_hmac_key` (cere un client pentru `keymaster64` – vezi punctul 2 de mai sus,
  de evaluat separat);
- varianta B: comenzile de test `GF_CMD_TEST_UNTRUSTED_ENROLL` (1060) / `..._AUTHENTICATE` (1061) din clasa 3,
  dacă build-ul de producție le are compilate. [N]

---

## 3. Kernel

### 3.1 Ce are deja mainline 7.1 la noi

- `qcom_scm.c` are apelurile QSEECOM de bază (versiune, căutare aplicație, trimitere comandă) și
  clientul `uefisecapp`. [V] Nu are: încărcare de aplicații, listenere, descărcare. [V]
- Lista de mașini permise (`qcom_scm_qseecom_allowlist`) conține doar laptopuri/plăci
  sc8180x/sc8280xp/x1e; **nicio mașină SM8250**. [V] Ea condiționează doar clienții din kernel.
- Configurația noastră: `CONFIG_QCOM_QSEECOM` dezactivat, `CONFIG_QCOMTEE` dezactivat, `CONFIG_TEE=y`,
  `CONFIG_QCOM_MDT_LOADER=y`, `CONFIG_QCOM_TZMEM_MODE_GENERIC=y`, CMA 32 MB. [V]
- Pe tabletă nu există `/dev/tee*` și nici variabile EFI (pornim prin ABL), deci nu există alți
  utilizatori QSEECOM care să fie afectați. [V]
- `drivers/tee/qcomtee` (smcinvoke) nu ajută: TA-ul Goodix răspunde doar pe QSEECOM. [R]

### 3.2 Ce adaugă stiva de referință

Două ramuri în `wrobelda/linux`, bazate pe v7.1, **netrimise upstream**. [R + V pe bază]

| Serie | Commit-uri | Volum | Fișiere |
|---|---|---|---|
| `qcom-qseecom-tee` | 45 | +2909 / −395 linii | `drivers/tee/qseecom/core.c` (nou, 1934 linii), `drivers/firmware/qcom/qcom_scm.c`, `include/linux/firmware/qcom/qcom_scm.h`, `drivers/soc/qcom/mdt_loader.c` + `Kconfig` + antet, `include/uapi/linux/tee.h` (`TEE_IMPL_ID_QSEECOM = 5`), `drivers/tee/{Kconfig,Makefile}`, `Documentation/tee/qseecom.rst`, `MAINTAINERS` |
| `goodix-fp-spi` | 4 | +760 linii | `drivers/input/misc/goodix_fp_spi.c` (nou, 687 linii), `Kconfig`, `Makefile`, binding YAML, documentație, nod DT pentru elish |

Simboluri de configurare: `CONFIG_QCOM_QSEECOM=y`, `CONFIG_TEE_QSEECOM=m`, `CONFIG_INPUT_GOODIX_FP_SPI=m`.

În seria patch-uită, dispozitivul TEE (`qcom_qseecom_tee`) se înregistrează **înainte** de verificarea
listei de mașini, deci lista nu trebuie modificată. [V]

### 3.3 Aplicare și compilare pe arborele nostru (test făcut)

Pe copia privată `sources/linux-kfix` (resincronizată din `linux-desktop`), cu ieșirea în
`out/desktop/kernel-kfix/build`:

- `qcom-qseecom-tee`: se aplică fără nicio abatere. [V]
- `goodix-fp-spi`: driverul, binding-ul și documentația se aplică curat; `Kconfig` cu fuzz 2; hunk-ul de
  DTS pentru elish nu se aplică pe fork-ul nostru (nu ne trebuie). [V]
- Compilare cu `W=1` (gcc 11.4 aarch64, configurația noastră + cele trei opțiuni): `qcom_scm.o`,
  `mdt_loader.o`, `drivers/tee/qseecom/core.o`, `goodix_fp_spi.o` – **fără erori și fără avertismente**. [V]
- Nu am făcut legarea finală a modulelor (`.ko`) și nici imaginea de kernel. [N]

Fișierele sunt în `out/desktop/fp-eval/patches/` (seriile `.patch`, diff-urile comprimate, configurația
de test).

### 3.4 Merge QSEECOM pe SM8250 cu mainline?

- Pe platforma de referință (tot SM8250), autorul raportează ciclul complet funcțional. [R]
- Pe unitatea noastră: neîncercat. [N] Versiunea QSEE nu o știm; kernelul o tipărește
  („qseecom: found qseecom with version …") abia cu `CONFIG_QCOM_QSEECOM=y`.
- Kernelul stock folosește `CONFIG_QTEE_SHM_BRIDGE=y`; noi avem modul TZMEM generic. [V] Ce mod
  folosește referința nu am găsit documentat. [N]
- Imaginea TA cere ~9,4 MB contigui (5,4 MB + aliniere la 4 MiB), iar fiecare comandă IRQ ~330 KB,
  din CMA-ul de 32 MB. [D din cod] Posibil să fie nevoie de un CMA mai mare.
- TA-ul trebuie pus în `/lib/firmware/goodixfp.mdt` + `.b00`–`.b07` (kernelul îl ia cu
  `request_firmware`, spațiul utilizator doar îl numește). [V în cod]

### 3.5 Moduri de eșec cunoscute (din documentația și codul referinței)

| Eșec | Efect | Sursă |
|---|---|---|
| Adresa fizică lipsă/greșită la offsetul 0 al cererii | TA-ul dereferențiază 0; **mașina se resetează** | [R] |
| Supplicant care raportează succes fără să fi completat bufferul | lumea sigură se blochează până la watchdog | [R] |
| Supplicant blocat | toate apelurile QSEECOM stau până la timeout (10 s); o aplicație rămasă „parcată" dă `-EBUSY` până la repornire | [R + V în cod] |
| TA încărcat a doua oară | `EINVAL` de la QSEE; nevătămător | [R] |
| Fișier gol în loc de fișier absent | 1033, inițializare eșuată | [R] |
| Offseturi greșite în payload (cazul nostru dacă folosim profilul 1) | necunoscut: de la `BAD_PARAMS` la excepție în TA | [N] |

Specific proiectului nostru: o resetare provocată de TrustZone în timpul unui kernel pornit din RAM
poate face ABL să treacă pe slotul `a` (gol). Remediul e cel deja cunoscut: `fastboot set_active b`.

---

## 4. Spațiul utilizator

### 4.1 `qsee-supplicant`

- C simplu (≈1200 de linii), fără dependențe în afară de libc și pthread; `make`, `make check`. [V]
- Are împachetare Debian (`debian/`, `dpkg-buildpackage -b -us -uc`); pachetul nu pornește și nu
  activează serviciile la instalare. [V în README]
- Două programe: `qsee-supplicant` (listenerele 10 și 28672) și `qsee-app-loader <nume-TA>`; unități
  systemd cu izolare (rulează ca root cu `CAP_SYS_ADMIN`). [V]
- Regula udev din `goodix-fp-spi-linux/udev/` pornește `qsee-app-loader@<firmware_name>.service` când
  apare `/dev/goodix_fp`. [V]

### 4.2 Ramura libfprint `goodix-qsee`

- Bazată pe libfprint 1.94.100; adaugă descoperirea dispozitivelor „misc" descrise în firmware și
  driverul `goodixqsee` (≈1300 de linii). [V]
- Se leagă doar de `compatible = "goodix,gf3626"` și citește numele TA-ului din sysfs. [V]
- Dependențe de build: meson ≥ 0.62, glib ≥ 2.68, gusb, gudev, opțional pixman/openssl/cairo/
  gobject-introspection. Toate există în arhiva Ubuntu; pe tabletă sunt deja `meson` și
  `libgudev-1.0-dev`. [V] `fprintd` și `libpam-fprintd` (1.94.5) sunt disponibile, neinstalate. [V]
- Ubuntu livrează `libfprint-2-2` 1.95.1+tod1 (cu patch-urile TOD). Compatibilitatea `fprintd` din
  arhivă cu biblioteca din ramură (același soname `libfprint-2.so.2`) trebuie verificată. [N]

**Modificări necesare la noi:** un al doilea profil de protocol cu offseturile din 2.2 (fișierele
`goodix-qsee-proto.[ch]`, constantele din `goodix-qsee.c`), selectat după numele TA-ului sau după un
`compatible` propriu. Aceeași adaptare trebuie făcută în `gfharness.c` pentru testele din linia de comandă.

### 4.3 Integrare fprintd / GDM / PAM

- `fprintd` are nevoie de `/dev/goodix_fp` și `/dev/teeN` (nu de `/dev/teeprivN`): drop-in systemd cu
  `DeviceAllow=/dev/goodix_fp rw` și `DeviceAllow=char-tee rw`. [R]
- GDM folosește un serviciu PAM separat (`gdm-fingerprint`) cu `pam_fprintd.so`; pe Ubuntu, `libpam-fprintd`
  se activează prin `pam-auth-update`. [D] De verificat la instalare ce livrează `gdm3` 50.1 de la noi.

### 4.4 Cum rămâne totul ușor de scos

- Nu se suprascrie `libfprint-2-2` din distribuție. Biblioteca din ramură se instalează sub un prefix
  propriu (de exemplu `/opt/q706f-fp`), construită doar cu `-Ddrivers=goodixqsee`, fără reguli udev/hwdb
  proprii; `fprintd` o primește printr-un drop-in (`Environment=LD_LIBRARY_PATH=…`).
- `qsee-supplicant` ca `.deb` separat; regula udev și drop-in-urile într-un pachet mic al nostru.
- Scoatere: dezactivarea celor două servicii, ștergerea drop-in-ului, `apt remove`, ștergerea
  `/var/lib/qsee-supplicant` și a `/lib/firmware/goodixfp.*`.
- Build-ul se poate face pe gazdă într-un container arm64, nu pe tabletă; pe tabletă ajung doar pachete.

---

## 5. Riscuri pentru dispozitiv și pentru celălalt sistem

| Risc | Evaluare | Bază |
|---|---|---|
| Deteriorare permanentă a tabletei prin încărcarea unui TA greșit | Scăzut: QSEE respinge imaginile nesemnate/malformate; folosim doar TA-ul propriu | [R + V semnătură] |
| TA sau TrustZone blocat | Mediu ca probabilitate în faza de teste; efect: repornire forțată, eventual `set_active b` | [R] |
| Afectarea amprentelor din Android / Ubuntu Touch | Scăzut: datele lor stau în `userdata` Android (`/data/vendor_de/0/fpdata`) și în `persist`, pe care Linux nu le montează; înrolările din Linux sunt un set separat de fișiere | [D] |
| Stare comună în TrustZone (contoare, RPMB) | Nu am găsit nicio cale; neverificat pe hardware | [D]/[N] |
| Sunetul pe difuzoare după eliberarea GPIO 26 | Necunoscut | [N] |
| Regulatorul `vreg_l7c_ts_3p0` e comun cu touchscreen-ul | Driverul îl pornește/oprește prin regulatorul fix; touchscreen-ul îl ține oricum pornit | [D] |
| Suprafață de atac nouă (`/dev/tee0` trimite comenzi arbitrare oricărui TA încărcat) | Real; se limitează prin permisiuni doar pentru `fprintd` | [R] |
| Token de înrolare fără semnătură | Oricine are root poate înrola o amprentă; mai slab decât pe Android | [R] |
| Cod de kernel terț, nerevizuit upstream, scris în mare parte cu LLM (declarat de autor) | De citit înainte de a intra în kernelul nostru; se încarcă întâi doar din RAM | [V în README] |

### Ordinea cea mai sigură a testelor, fiecare cu revenirea ei

| # | Pas | Ce aflăm | Revenire |
|---|---|---|---|
| 1 | Kernel cu `CONFIG_QCOM_QSEECOM=y` + seriile, **pornit din RAM**, fără module încărcate | versiunea QSEE din dmesg; că bootul nu e afectat | repornire normală |
| 2 | Nodul DT + eliberarea GPIO 26, tot din RAM; test de sunet | că audio nu depinde de GPIO 26 | repornire normală |
| 3 | `modprobe goodix_fp_spi`; fără a deschide `/dev/goodix_fp` | apare dispozitivul, `firmware_name = goodixfp` | `rmmod`, repornire |
| 4 | `modprobe qseecomtee` | apar `/dev/teeN`, `impl_id = 5` | `rmmod`, repornire |
| 5 | Supplicantul pornit singur, cu director de stare gol | înregistrarea listenerelor 10 și 28672 | oprirea serviciului |
| 6 | Încărcarea TA-ului (`qsee-app-loader goodixfp`) | dacă QSEE-ul Lenovo acceptă încărcarea din mainline | închiderea sesiunii (descărcare) sau repornire |
| 7 | `DETECT_SENSOR` → `INIT` → `INIT_FINISHED` → `GET_DEV_INFO`, cu profilul 2 | modelul senzorului; apar fișierele de calibrare | ștergerea directorului de stare, repornire |
| 8 | `ENUMERATE` (listă goală), apoi IRQ la atingere, fără înrolare | că structura IRQ e decodată corect | repornire |
| 9 | Prima înrolare cu tokenul „doar provocare" | dacă e nevoie de cheia HMAC | `REMOVE` prin protocol sau ștergerea directorului de stare |
| 10 | Autentificare, apoi fprintd, apoi GDM | funcționalitatea finală | dezinstalarea pachetelor |

Pașii 1–5 nu trimit nimic TA-ului. Riscul real începe la pasul 6.

---

## 6. Licențe

| Componentă | Licență | Observații |
|---|---|---|
| `goodix-fp-spi-linux` (documentație, `gfharness.c`, regula udev) | GPL-2.0-only | [V] |
| Seria `qcom-qseecom-tee` | GPL-2.0-only | cod nou al autorului [V] |
| Seria `goodix-fp-spi` | GPL-2.0-only (binding: GPL-2.0-only OR BSD-2-Clause) | derivat din driverul Goodix/Xiaomi; păstrează drepturile de autor originale [V] |
| `qsee-supplicant` | BSD-2-Clause; `qsee_protocol.h` BSD-3-Clause-Clear (Qualcomm MinkIPC); `handle_db.*` BSD-2-Clause (Linaro) | [V] |
| libfprint, ramura `goodix-qsee` | LGPL-2.1-or-later | [V] |

Ce am redistribui noi: patch-urile de kernel (compatibile cu kernelul nostru GPL-2.0), profilul 2
pentru libfprint (LGPL), nodul DT, scripturile de împachetare. Offseturile recuperate sunt fapte de
interoperabilitate și pot fi publicate.

**Ce rămâne în afara oricărui repo public:** `goodixfp.mdt` / `.b00`–`.b07`, bibliotecile stock
(`libgf_ca.so`, `libgf_hal.so`, `libgoodixhwfingerprint.so` etc.), listările de dezasamblare din
`out/desktop/stock-fw/fp/`, conținutul `/var/lib/qsee-supplicant` (date biometrice sigilate, legate de
dispozitiv). Toate sunt deja sub `out/`, ignorat de git. Utilizatorii portului și-ar extrage TA-ul din
propria tabletă.

---

## 7. Recomandare și plan

**Recomandare: GO pentru etapa (a) și pentru pașii 1–5 din tabelul de teste; decizie separată înainte
de pasul 6 (încărcarea TA-ului) și înainte de pasul 9 (prima înrolare).** Dacă pasul 6 eșuează fără o
cauză reparabilă în kernel, proiectul se oprește (NO-GO) fără urme pe dispozitiv.

Efort: (a) 2–3 sesiuni; integrare kernel + DT + test din RAM 1–2; împachetare userspace 1–2; pornire
pe hardware 2–5.

### (a) Pași care nu cer aprobare (analiză, compilare pe gazdă)

1. Decodarea completă a profilului 2 din `libgf_hal.so`: `DETECT_SENSOR`, offsetul tokenului în `ENROLL`,
   tablourile din `ENUMERATE`, câmpul „eșantioane rămase", câmpurile din antetul de 96 de octeți.
2. Decodarea `get_key_from_keymaster` și a comenzii 109, doar static, ca să știm ce ar însemna varianta A.
3. Extragerea `g_spi_device_id` din TA și a câmpurilor de atestare din certificat (legare de model).
4. Citirea integrală a `drivers/tee/qseecom/core.c` și a modificărilor din `qcom_scm.c` (revizie de cod).
5. Scrierea profilului 2 pentru libfprint și pentru `gfharness`, plus testele fără hardware; build într-un
   container arm64 pe gazdă.
6. Legarea finală a modulelor în copia privată (`linux-kfix`) și verificarea DTS-ului cu `dtbs_check`.

### (b) Pași care cer aprobarea proprietarului

1. Introducerea celor două serii terțe și a nodului DT în kernelul nostru (patch-uri în `scripts/desktop/patches`),
   inclusiv schimbarea de la `audio4_1p8_supply`.
2. Pornirea din RAM a acelui kernel pe tabletă (pașii 1–4 din tabel).
3. Copierea TA-ului în `/lib/firmware` pe tabletă și instalarea pachetelor `qsee-supplicant` / libfprint
   (sau build pe tabletă, dacă se preferă).
4. **Încărcarea TA-ului** (pasul 6) și primele comenzi către el (pașii 7–8).
5. **Prima înrolare** (pasul 9).
6. Activarea în fprintd/GDM/PAM.
7. Separat și doar dacă devine necesar: orice interacțiune cu `keymaster64`.

---

## Anexă: unde sunt materialele

| Ce | Unde |
|---|---|
| Cele trei repo-uri de referință (clonate, doar citite) | `out/desktop/fp-eval/{goodix-fp-spi-linux,qsee-supplicant,libfprint}` |
| Seriile de kernel, diff-uri, configurația de test, ciorna DT | `out/desktop/fp-eval/patches/` |
| TA-ul extras | `out/desktop/stock-fw/fp/image/` |
| Bibliotecile stock extrase + dezasamblări | `out/desktop/stock-fw/fp/vendor/` |
| Copia privată de kernel și build-ul de test | `sources/linux-kfix`, `out/desktop/kernel-kfix/build` |

Nu s-a modificat nimic în `sources/linux-desktop`, în `scripts/desktop/` sau pe tabletă. De pe tabletă
s-au făcut doar citiri (debugfs gpio, `/proc/meminfo`, dmesg, lista de pachete). Nu s-a făcut commit.

---

## 11. Continuare 2026-11-13: profil 2, HMAC, core.c, GPIO 26, patch-uri

### 11.1 Profilul 2 complet (recuperat din `libgf_hal.so` / `libgf_ca.so`)

Toate offseturile de mai jos sunt citite din dezasamblarea HAL-ului nostru [V]. Deltele față de profilul 1
sunt coerente: **−4** la câmpurile ancorate în antet, **−36** la câmpurile din zona adâncă a payload-ului
IRQ (−4 antet plus −32 zonă), **−40** la dimensiunea payload-ului IRQ.

| Câmp | Referință (p1) | q706f (p2) | Δ |
|---|---|---|---|
| Antet corp comandă (body) | 100 | **96** | −4 |
| IRQ payload | 327624 | **327584** | −40 |
| IRQ mască / operație / nav | 100 / 104 / 136 | **96 / 100 / 132** | −4 |
| IRQ grup / deget / rămase | 0x4fce4 / 0x4fce8 / 0x4fcec | **0x4fcc0 / 0x4fcc4 / 0x4fcc8** | −36 |
| IRQ armare: mode / size / arm | 327049 / 327096 / 327616 | **327013 / 327060 / 327580** | −36 |
| PRE_ENROLL (nonce la body+4) | 112 (nonce @104) | **104 (nonce @100)** | |
| **ENROLL / token HAT** | 180, token @**110** | **176, token @106** (grup @96) | −4 |
| SAVE / REMOVE (grup @body, deget @body+4) | 112 / 188 | **108 / 188** | |
| AUTHENTICATE / FINISH | 112 / 124 | **120 / 120** | |
| SET_ACTIVE_GROUP / INIT_FINISHED | 104 / 104 | **100 / 100** | −4 |
| ENUMERATE (count@body, grup@body+4, deget@+44) | 184 (100/104/144) | **180 (96/100/140)** | −4 |
| INIT / GET_DEV_INFO | 348 / 5500 | **344 / 5496** | −4 |
| DETECT_SENSOR | 520 | **516** [D] | |

- **Token ENROLL:** `gf_hal_common_enroll` face `memcpy` de 69 de octeți la `cmd+0x6a` (= **+106**),
  cu grupul la `cmd+96`, flag de dump la +104, zero la +105. [V]
- **ENUMERATE:** `gf_hal_common_enumerate` citește `group[i]` la `buf+100` și `finger_id[i]` la `buf+140`,
  cu numărul la `buf+96`, zece intrări. [V]
- **IRQ:** `hal_milan_an_series_irq` armează `0x02000000`@327013, `512`@327060, `1`@327580, și citește
  masca@96 / operația@100. Succesul (enrol/auth) citește grupul/degetul la 0x4fcc0 / 0x4fcc4. [V]
- Verdictul IRQ la **+12** l-am păstrat ca la referință (e în antetul aplicației); de confirmat la prima
  autentificare. [D]

### 11.2 Întrebarea HMAC / tokenul de înrolare

- **Confirmat [V]:** CA-ul nostru trimite cheia HMAC la **fiecare** deschidere de sesiune. În
  `gf_ca_open_session`, ramura „whitebox dezactivat" (cazul nostru implicit) apelează `send_hmac_key`
  (adresa 0x3328), care ia o cheie de la `keymaster64` prin `get_key_from_keymaster` și o trimite TA-ului
  cu clasa 2, comanda 109, 256 de octeți. Nu e condiționat de whitebox — e exact ramura `else`.
- **TA-ul are mecanismul [V]:** `gf_ta_set_hmac_key`, `gf_generate_hmac_enroll`, `gf_ta_load_auth_token`,
  `gf_so_load/save_auth_token`, plus șirurile „invalid challenge detected", `GF_ERROR_UNTRUSTED_ENROLL`,
  `GF_ERROR_INVALID_HAT_VERSION`, `GF_ERROR_INVALID_CHALLENGE`, `gf_ta_lockout`,
  `g_authenticate_fail_count` / `g_max_authenticate_failed_retry_count`.
- **Dacă TA-ul refuză înrolarea fără cheie: necunoscut static [N].** Am încercat să izolez verificarea din
  segmentele TA-ului (nu sunt cifrate: cod Thumb-2 în `goodixfp.b02`, vaddr 0). Dezasamblarea cu capstone
  reușește, dar funcțiile de verificare a tokenului loghează printr-un **catalog de șiruri indirectat**
  (nu `movw/movt` direct și nici pool PC-relativ pe adresa șirului), așa că ramura exactă
  „challenge-only → UNTRUSTED_ENROLL" nu se poate urmări fiabil cu uneltele disponibile. Acesta e exact
  genul de întrebare pe care proiectul de referință o marchează drept „se rezolvă doar pe dispozitiv".
- **Consecință pentru plan:** la pasul 9 (prima înrolare) încercăm întâi tokenul „doar provocare"
  (ca referința). Dacă TA-ul răspunde `1057 UNTRUSTED_ENROLL`, varianta B e să reproducem `send_hmac_key`,
  ceea ce cere un client `keymaster64` — **decizie separată**, pentru că atinge stare comună cu Android.

### 11.3 Review `drivers/tee/qseecom/core.c` — specific SM8250/Lenovo

- **TZMEM: generic vs SHM bridge.** Driverul folosește `qcom_tzmem_pool_new/alloc` și e **agnostic** față
  de mod. [V] La noi `CONFIG_QCOM_TZMEM_MODE_GENERIC=y` → `dma_alloc_coherent` (din CMA), fără a înregistra
  zonele ca punți SHM. Kernelul stock Android folosește `CONFIG_QTEE_SHM_BRIDGE=y`. [V] **Risc real [D]:**
  dacă TrustZone-ul Lenovo acceptă doar buffere înregistrate prin SHM bridge pentru QSEECOM (driverul
  downstream `qseecom.c` chiar înregistrează shmbridge pentru heap-ul lui ION), modul generic poate fi
  respins. Mitigare: dacă generic eșuează, trecem pe `CONFIG_QCOM_TZMEM_MODE_SHMBRIDGE` (îl selectează și
  QCOMTEE). Comutatorul e curat în Kconfig.
- **CMA pentru ~9,4 MB.** Încărcarea TA-ului alocă un pool dedicat de
  `PAGE_ALIGN(9,4 MB) + 4 MiB ≈ 13,4 MB` din `dma_alloc_coherent`, eliberat după încărcare. [V cod]
  Bufferele listenerelor: FS 20 KB + GPFS 504 KB, din pool-ul `ON_DEMAND` (`QSEECOM_TEE_POOL_MAX = 32M`).
  Fiecare IRQ: ~330 KB tranzitoriu. CMA-ul nostru e **32 MB**. [V] Un bloc contiguu de 13,4 MB dintr-un CMA
  de 32 MB parțial folosit poate eșua la fragmentare. **Recomandare:** CMA 64 MB (sau o zonă
  `reserved-memory` dedicată) înainte de pasul de încărcare.
- **Listener register.** `qcom_scm_qseecom_listener_register` înregistrează bufferul kernel (nu cel al
  spațiului utilizator), ținut printr-o referință `tee_shm` până la retragere. [V] Nimic specific SM8250.
- **Adresare:** pentru QSEE < TZ.BF.4.0, driverul limitează masca DMA la 32 de biți. SM8250 e 4.0+, deci
  64 de biți — fără constrângerea sub 4 GB. [D]
- **Listă de mașini:** dispozitivul TEE se înregistrează **înainte** de verificarea listei, deci lista
  (fără SM8250) nu blochează interfața de spațiu utilizator. [V]

### 11.4 GPIO 26 — lămurit din dovezi

- În DT-ul stock de bază există o stare pinctrl `spkr_1_sd_n_active` pe GPIO 26, dar ea aparține nodului
  **`wsa_spkr_en1_pinctrl`** (fragment@52) — un „enable" pentru amplificator **WSA**, moștenit din placa
  de referință Qualcomm (kona-mtp). [V]
- Amplificatoarele reale ale tabletei sunt **Cirrus cs35l45** (4 bucăți), iar în stock ele folosesc
  `reset-gpios = GPIO 127`, `vdd-1v8-enable-gpios = GPIO 49`, cu `VA-supply`/`VP-supply` de la PMIC —
  **niciunul pe GPIO 26**. [V]
- Singurul consumator real al GPIO 26 în stock este nodul `goodix_fp` (`fp-gpio-reset`). [V]
- **Concluzie:** pe această placă GPIO 26 este resetul cititorului de amprente; `spkr_1_sd_n` /
  `audio4_1p8_supply` din portul nostru mainline sunt **boilerplate vestigial** din placa de referință.
  Difuzoarele merg azi pentru că amplificatoarele își iau alimentarea de la GPIO 49/127 + PMIC, nu de la 26.
- **Ce trebuie schimbat în DTS:** din `audio4_1p8_supply` se scot `gpio = <&tlmm 26 ...>`,
  `enable-active-high`, `pinctrl-names`, `pinctrl-0 = <&spkr_1_sd_n_active>`; rămâne un `regulator-fixed`
  `regulator-always-on` (regulator fictiv mereu pornit), ca `vdd-batt-supply` al cs35l45 să rămână rezolvat.
  Nodul pinctrl `spkr_1_sd_n_active` se elimină, iar GPIO 26 devine `fp_reset_default` pentru nodul
  `fingerprint`. [D din dovezile de mai sus]
- **Ce s-ar putea strica [N]:** dacă, în ciuda dovezilor, GPIO 26 ar comanda fizic o șină de care au nevoie
  amplificatoarele, difuzoarele ar amuți. **Test:** redare stereo L/R imediat după schimbarea DTS (pasul 2),
  înainte de orice atingere a stivei de amprentă. Revenire: repornire la kernelul instalat.

### 11.5 Patch-uri scrise și testate (sub `out/desktop/fp-eval/patches/`)

- `goodix-qsee-profile.h` — structura `goodix_qsee_profile` + instanțele v1 (identic cu upstream) și v2
  (q706f). Selecție după numele TA (`goodixfp` → v2), nu după `compatible`.
- `goodix-qsee-proto2.c` — helperele proto parametrizate pe profil (prepare/parse IRQ, enroll/finger,
  enumerate, finish). **Compilat [V].**
- `test_profile2.c` — test fără hardware care verifică layout-ul ambelor profile și marginile (token în
  payload, tabloul finger în payload, buffer IRQ scurt respins). **Rulează și trece pentru ambele
  profile [V].**
- `profile2-gfharness.patch` — face `gfharness` conștient de profil (`-DGF_PROFILE=2`); ambele profile
  compilează fără avertismente; patch-ul se aplică curat. **[V]**
- `README-profile2.md` — note de integrare în driverul libfprint (wiring-ul complet în `goodix-qsee.c`
  rămâne de făcut; nu l-am putut compila aici fără glib/libfprint).

Întrebare necunoscută rămasă la profil: verdictul IRQ la +12 și dimensiunea DETECT_SENSOR (516) — de
confirmat la primele comenzi pe hardware.

---

## 12. Primul pas pe hardware — acțiuni în ordine, fiecare cu revenirea ei

Toate acestea presupun aprobarea proprietarului (secțiunea 7b) și un kernel **pornit din RAM**, nu flash-uit.
Niciuna din acțiunile 1–5 nu trimite ceva TA-ului; riscul real începe la 6.

| # | Acțiune | Ce confirmă | Revenire |
|---|---|---|---|
| 0 | Mărește CMA la 64 MB în configurația de kernel; lasă `TZMEM_MODE_GENERIC` | spațiu pentru încărcarea de ~13,4 MB | doar configurație, nu atinge tableta |
| 1 | Construiește kernelul cu seriile `qcom-qseecom-tee` + `goodix-fp-spi` + nodul DT (GPIO 26 eliberat); **pornește-l din RAM** (`fastboot boot`, fără flash) | bootul nu e afectat; în `dmesg` apare „qseecom: found qseecom with version 0x…" | oprire/repornire → revine la kernelul instalat |
| 2 | Cu acel kernel, redă sunet stereo L/R | că eliberarea GPIO 26 nu a stricat difuzoarele | repornire la kernelul instalat |
| 3 | `modprobe goodix_fp_spi`; **fără** a deschide `/dev/goodix_fp` | apare `/dev/goodix_fp`, `firmware_name = goodixfp` | `rmmod goodix_fp_spi` |
| 4 | `modprobe qseecomtee` | apar `/dev/tee0` și `/dev/teepriv0`, `impl_id = 5` | `rmmod qseecomtee` |
| 5 | Copiază `goodixfp.mdt` + `.b00..b07` în `/lib/firmware/`; pornește `qsee-supplicant` singur, director de stare gol | se înregistrează listenerele 10 și 28672 | oprește serviciul; șterge `/lib/firmware/goodixfp.*` |
| 6 | `qsee-app-loader goodixfp` (încarcă TA-ul) | **dacă QSEE-ul Lenovo acceptă încărcarea din mainline** (aici se vede dacă TZMEM generic merge sau trebuie SHM bridge) | închide sesiunea loaderului (descărcare prin refcount) sau, dacă TZ s-a blocat, repornire; dacă ABL cade pe slotul a: `fastboot set_active b` |
| 7 | `gfharness --bringup` cu profilul 2 (`-DGF_PROFILE=2`): DETECT_SENSOR → INIT → INIT_FINISHED → GET_DEV_INFO | modelul real al senzorului; apar fișierele de calibrare în directorul de stare | șterge directorul de stare; repornire |
| 8 | `gfharness --enumerate` (listă goală), apoi `--capture --auth` fără înrolare, la atingere | că structura IRQ a profilului 2 e corectă (mască, operație, verdict +12) | repornire |
| 9 | `gfharness --capture --enroll` — **prima înrolare**, întâi cu token „doar provocare" | dacă e nevoie de cheia HMAC (`1057` = da) | `--remove <id>` prin protocol sau ștergerea directorului de stare |
| 10 | Instalează libfprint cu profilul 2 sub prefix propriu; fprintd; apoi serviciul PAM `gdm-fingerprint` | funcționalitatea finală (deblocare GDM) | dezactivează serviciile; `apt remove`; șterge drop-in-urile |

Plasa de siguranță la nivel de dispozitiv rămâne backup-ul EDL din `backup/edl-2026-11-12/` și regula
`fastboot set_active b` dacă un kernel de test căzut face ABL să treacă pe slotul gol (vezi `docs/RECUPERARE.md`).

---

## 13. Actualizare 13.11.2026 (7.3.4)

Cercetare făcută după trecerea proiectului pe Linux 7.3.4 (nimic rulat pe tabletă). Concluzia rămâne **„GO condiționat,
pe etape”**, cu două puncte de decizie GO/NO-GO (etapele 4 și 6 de mai jos). Ce s-a schimbat față de secțiunile 1–12:

- **Kernelul.** Mainline 7.3.4 are doar un QSEECOM minimal (versiune, căutare aplicație, trimitere comandă), folosit
  pentru `uefisecapp`, cu o listă de mașini fără SM8250; **nu are încărcare de TA, listenere sau descărcare**.
  `qcomtee` (smcinvoke, din 6.18) poate încărca TA-uri, dar e țintit la SM8650+ și nu se potrivește cu TA-ul Goodix,
  care folosește API-ul QSEECom legacy. Calea rămâne seria ne-upstream `qcom-qseecom-tee` + `goodix-fp-spi`
  (bazată pe 7.1), care trebuie **rebazată pe 7.3.4**; atinge `qcom_scm.c` și `mdt_loader.c`, schimbate între 7.1 și 7.3
  (serviciul PAS generic), deci rebase-ul poate avea conflicte (neverificat).
- **Stiva de referință.** Funcțională pe un singur dispozitiv verificat (Xiaomi Pad 5 Pro 5G, SM8250, firmware Xiaomi);
  nimic trimis upstream, iar autorul spune că codul trebuie revizuit înainte de RFC. Pe Pixel 3a (FPC) înrolarea a cerut
  un token Gatekeeper și un listener RPMB pe partea AP; pe un SC8280XP căutarea/trimiterea dau încă `-22`. Pentru TA-ul
  Lenovo (care primește cheia HMAC de la `keymaster64`, §11.2) riscul „înrolarea cere HMAC/Gatekeeper” e deci real.
- **Efort revizuit:** 7–14 sesiuni (6–12 inițial, +1–2 pentru rebase pe 7.3.4).
- **Linia de oprire recomandată:** orice client pentru `keymaster64`/Gatekeeper (stare comună cu Android, posibil RPMB)
  = decizie separată, recomandat NO-GO.

### Planul pe etape (A = cere aprobarea proprietarului)

| Etapă | Ce | Test | Revenire | Aprobare |
|---|---|---|---|---|
| 0 | Rebase al seriilor pe 7.3.4 în copie privată, profilul 2 legat în `goodix-qsee.c`, build libfprint/supplicant în container arm64, `dtbs_check`, CMA 64 MB | compilare W=1, `test_profile2` | nimic pe tabletă | nu pentru analiză; cod extern compilat pe gazdă — de confirmat (regula 7) |
| 1 | Patch-uri în `scripts/desktop/patches` + nod DT + eliberarea GPIO 26; `fastboot boot` din RAM | boot normal, „qseecom: found qseecom with version” în dmesg; redare stereo L/R | repornire la kernelul instalat; `set_active` dacă ABL cade | **A** (kernel nou, pornire din RAM) |
| 2 | `modprobe goodix_fp_spi`, `modprobe qseecomtee` | `/dev/goodix_fp`, `/dev/tee0` + `teepriv0`, `impl_id=5` | `rmmod` | **A** |
| 3 | TA în `/lib/firmware`, pachetul `.deb` al supplicantului, pornit cu director gol | listenerele 10 și 28672 înregistrate | oprire serviciu, ștergere fișiere | **A** (instalare pachete) |
| 4 | `qsee-app-loader goodixfp` | TZ-ul Lenovo acceptă încărcarea (sau trecere la SHM bridge) | descărcare / repornire | **A — punct GO/NO-GO** |
| 5 | `gfharness` profil 2: DETECT/INIT/GET_DEV_INFO, ENUMERATE, IRQ la atingere | modelul senzorului, calibrare, IRQ decodat | ștergerea directorului de stare | **A** |
| 6 | Prima înrolare cu token „doar provocare” | `1057 UNTRUSTED_ENROLL` = e nevoie de HMAC | `REMOVE` / ștergerea directorului | **A — punct GO/NO-GO** |
| 7 | fprintd + serviciul PAM `gdm-fingerprint` | deblocare în GDM, parola rămâne alternativă | dezactivare servicii, `apt remove` | **A** |
| 8 | Doar dacă e nevoie: client `keymaster64`/Gatekeeper | — | — | **A separat; recomandat NO-GO** |
| 9 | `boot_a` cu kernelul final | — | backup EDL, `set_active` | **A (scriere pe partiție)** |

Comenzile interzise din §2.4 (rescrierea firmware-ului senzorului) rămân interzise în toate etapele.
