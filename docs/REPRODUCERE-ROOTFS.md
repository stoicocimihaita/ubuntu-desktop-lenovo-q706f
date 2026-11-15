# Reproducerea imaginii rootfs Ubuntu 26.04 (q706f)

Stare: 13.11.2026. Documentul spune ce conține `out/desktop/ubuntu-desktop.img` când e construit de la zero din repo,
ce adaugă comutatorul `BRINGUP=1` și ce apare abia pe tabletă, la instalare. A fost scris după compararea (doar citire)
cu tableta de dezvoltare și după un build curat verificat offline (secțiunea 6).

## 1. Comenzi

```sh
SERIAL=none scripts/desktop/kernel-cycle.sh build   # kernel + modulul ctn730 (o singură dată / la schimbări de kernel)
scripts/desktop/build-rootfs.sh                     # ~10 min, out/desktop/rootfs (arbore deținut de root)
scripts/desktop/make-rootimg.sh                     # out/desktop/ubuntu-desktop.img (ext4, 14 GB sparse)
scripts/desktop/check-rootimg.sh                    # verificare offline: e2fsck -fn + debugfs, fără mount
```

Variabile:

| Variabilă | Script | Implicit | Efect |
|---|---|---|---|
| `BRINGUP=1` | `build-rootfs.sh` | `0` | imagine de dezvoltare (secțiunea 3) |
| `ROOTFS_NAME` | `build-rootfs.sh`, `make-rootimg.sh` | `rootfs` | arborele `out/desktop/<nume>` |
| `IMG_NAME` | `make-rootimg.sh` | `ubuntu-desktop.img` | fișierul imagine; numele trebuie să fie cel din `q706f.rootimg=` ca să pornească |
| `TIMEZONE` | `build-rootfs.sh` | `Europe/Bucharest` | fusul orar (din el deduce `q706f-regdom` țara pentru Wi-Fi) |
| `USER_PASSWORD` | `build-rootfs.sh` | `ubuntu` | parola inițială a contului `ubuntu` |
| `MAIN_REPO` | `make-rootimg.sh` | calea autorului | unde e clona `sources/lenovo-sm8250-q706f-firmware` |

`make-rootimg.sh` **nu mai modifică arborele rootfs**: modulele, firmware-ul și `scripts/desktop/overlay/` se adaugă
într-un overlayfs temporar, în container. Se oprește cu mesaj clar dacă lipsesc modulele kernelului, `modules.dep`,
modulul out-of-tree `extra/ctn730.ko` (îl construiește doar `kernel-cycle.sh build`) sau firmware-ul; rulează `depmod`
și verifică prezența lui `extra/*.ko` în `modules.dep`, compilează schemele GSettings și refuză un `90_q706f.gschema.override`
respins de scheme.

## 2. Ce conține imaginea implicită

**Pachete** (`PKGS` din `build-rootfs.sh`, fără Recommends): `ubuntu-desktop-minimal`, GNOME Shell 50 / GDM, PipeWire,
NetworkManager, BlueZ, `linux-firmware`, `openssh-server`, `avahi-daemon` + `libnss-mdns`, `systemd-timesyncd`,
`fake-hwclock`, `systemd-zram-generator`, `rtkit`, `iio-sensor-proxy` (cel din arhivă, fără SSC), libcamera +
`pipewire-libcamera`, `gnome-snapshot`, `epiphany-browser`, `xournalpp`, `gnome-terminal`, `gnome-screenshot`,
`gnome-keyring`, `libsecret-tools`, `freerdp3-sdl`, `gnome-connections`, `apparmor`, unelte de diagnostic (`evtest`,
`i2c-tools`, `iw`, `usbutils`…), `curl`, `gnome-shell-extensions`. `onboard` este scos dacă ajunge în arbore (în
build-ul curat nu mai ajunge).

**Din `rootfs-customize.sh`:**
- hostname `q706f`, `fstab` gol, netplan cu NetworkManager;
- contul `ubuntu` (grupuri `sudo,video,audio,input,plugdev,netdev`), parola inițială `ubuntu` — `sudo` cere parola;
- locale `en_US.UTF-8`, `ro_RO.UTF-8`; fus orar `Europe/Bucharest`;
- gadget USB NCM cu adresă fixă + `ssh` (`q706f-usb-gadget.service`, activat), `usb0` ignorat de NetworkManager;
- `DefaultTimeoutStopSec=15s`;
- **fără chei de gazdă SSH** în imagine (se generează la primul boot, `q706f-ssh-hostkeys.service`); `/etc/machine-id` gol;
- `/etc/fake-hwclock.data` = data build-ului (ceasul primului boot nu mai pornește din 1970);
- tastatura virtuală GNOME forțată **doar pe ecranul de autentificare GDM** (`/etc/gdm3/greeter.dconf-defaults`), vezi secțiunea 5;
- `/etc/q706f-image` (`BRINGUP=…`, data build-ului).

**Din `scripts/desktop/overlay/`** (copiat de `make-rootimg.sh`, totul `root:root`, fără drept de scriere pentru grup):
- servicii de sistem activate: `q706f-bt-addr`, `q706f-pen-dock`, `q706f-tablet-mode`, `q706f-ssh-hostkeys`;
  pornite din udev: `q706f-clock-restore` (regula `85-hwclock.rules`), `q706f-bt-addr` (`82-…`), `q706f-wifi-addr` și
  `q706f-regdom` (`83-q706f-wifi.rules`);
- servicii de utilizator activate (`graphical-session.target`): `q706f-screen-keys`, `q706f-audio-settle`;
- logind (`10-q706f-tablet.conf`), suspendare (`10-q706f-suspend.conf`, `AllowSuspend=yes`), hook-ul `system-sleep/q706f-sleep`;
- zram (`/etc/systemd/zram-generator.conf`: `min(ram/2, 4096)`, `lzo-rle`);
- audio: UCM `Lenovo/q706f`, WirePlumber `51-q706f-audio-format.conf` (S16LE);
- udev: partițiile Android ascunse, butoane, `libssc`, adresa BT/Wi-Fi, ceas;
- NetworkManager `q706f-wifi-mac.conf`, `/etc/default/q706f-regdom` (`REGDOM=auto`);
- GNOME: `90_q706f.gschema.override` (fără suspendare automată, fără luminozitate automată, butonul Power lăsat
  serviciului nostru, ecran stins după 5 min fără blocare, procentul bateriei, favoritele din dock incl. „Remote PC”,
  **extensia `osk-button@q706f` activată implicit**) și extensia însăși;
- lansatorul `q706f-remote-pc` + intrarea `.desktop`;
- drop-in-urile pentru senzori (`hexagonrpcd.service.d`, `iio-sensor-proxy.service.d` cu `ConditionPathExists=`):
  fără pasul de senzori ele nu au niciun efect (vezi secțiunea 4).

**Din `make-rootimg.sh`:** `/usr/lib/modules/<versiune>` (cu `extra/ctn730.ko`, index `depmod` refăcut) și firmware-ul
Lenovo (`qcom/sm8250/q706f/*`, `goodix_*.bin`, `cirrus/`) din clona de firmware — proprietar, nu e în repo.

**Ce NU este în imaginea implicită:** `sudo` fără parolă, autologin, `--unsafe-mode`, keyring prefăcut, chei SSH,
adrese MAC, profiluri Wi-Fi, împerecheri Bluetooth, configurația „Remote PC”.

## 3. Ce adaugă `BRINGUP=1`

`BRINGUP=1 scripts/desktop/build-rootfs.sh` produce imaginea de dezvoltare, echivalentă cu tableta de lucru. Numai pentru
o tabletă ținută pe birou: oricine are acces la ea (sau la portul USB) devine root.

| Element | Fișier | De ce există |
|---|---|---|
| `sudo` fără parolă | `/etc/sudoers.d/90-bringup` | `kernel-cycle.sh`, `setup-sensors.sh` rulează `sudo` neinteractiv prin ssh |
| autologin GDM | `/etc/gdm3/custom.conf` (`AutomaticLoginEnable=true`, `AutomaticLogin=ubuntu`) | sesiunea (și serviciile de utilizator) pornesc fără om la tabletă |
| `gnome-shell --unsafe-mode` | `~/.config/systemd/user/org.gnome.Shell@.service.d/unsafe.conf` | capturi de ecran prin ssh (`gnome-screenshot`) |
| keyring implicit necriptat | `~/.local/share/keyrings/{default,Default_keyring.keyring}` (gol) | la autologin nu există parolă cu care să fie deblocat keyring-ul „login” |

Revenire pe o tabletă instalată: se șterg primul și al treilea fișier, cele două rânduri `AutomaticLogin*` din
`custom.conf` și, dacă nu mai e nevoie, keyring-ul necriptat. `make-rootimg.sh` avertizează când împachetează un arbore
`BRINGUP=1`, iar `check-rootimg.sh` verifică prezența/absența acestor patru elemente după `/etc/q706f-image`.

Parola implicită rămâne și în imaginea normală (nu există asistent de prim boot, iar fără o parolă cunoscută nu te poți
autentifica deloc); se schimbă la `install.sh post` (pasul 1/4) sau se dă alta la build cu `USER_PASSWORD=`.
Autentificarea SSH cu parolă și gadgetul USB cu `ssh` rămân active: sunt singura cale de acces pentru `install.sh post`.

## 4. Ce se creează abia pe tabletă (nu se copiază niciodată în repo)

| Ce | Unde | Cine |
|---|---|---|
| chei de gazdă SSH | `/etc/ssh/ssh_host_*` | primul boot (`q706f-ssh-hostkeys.service`) |
| identitatea mașinii | `/etc/machine-id` | primul boot (systemd) |
| parola contului | `/etc/shadow` | `install.sh post` 1/4 |
| cheia ta publică SSH | `~/.ssh/authorized_keys` | `ssh-copy-id` (`install.sh post` 4/4) |
| profiluri Wi-Fi (cu parole) | `/etc/netplan/90-NM-*.yaml` | `install.sh post` 2/4 (`nmcli --ask`) sau Setări |
| adresa Bluetooth de fabrică | `/etc/q706f-bt-addr` | `install.sh post` 3/4 (altfel: adresă derivată din serie) |
| adresa MAC Wi-Fi de fabrică | `/etc/q706f-wifi-addr` | `install.sh post` 3/4 (altfel: derivată din serie) |
| împerecheri Bluetooth (pen, boxe) | `/var/lib/bluetooth/` | Setări → Bluetooth |
| senzori (rotație, lumină, busolă) | pachetul `hexagonrpcd`, `/usr/local/lib/libssc.so*`, `/usr/local/bin/ssccli`, `/usr/local/libexec/iio-sensor-proxy`, `/usr/share/qcom/sm8250/Lenovo/q706f/` (registry proprietar), pachete `-dev` | `install.sh post` 4/4 → `setup-sensors.sh` (compilează pe tabletă, are nevoie de internet) |
| „Remote PC” | `~/.config/q706f-remote-pc.conf` + utilizator/parolă în keyring (`secret-tool`, serviciul `q706f-pc-rdp`) | manual, vezi comentariul din `/usr/local/bin/q706f-remote-pc` |
| setări de utilizator | `~/.config/dconf/user`, `~/.config/monitors.xml` | GNOME, la folosire |
| ora salvată | `/etc/fake-hwclock.data` | `fake-hwclock` (periodic și la oprire) |

Fără pasul de senzori imaginea e consistentă: `iio-sensor-proxy` nu pornește (condiția din drop-in), `hexagonrpcd` nu e
instalat, hook-ul de suspendare ignoră serviciile lipsă; lipsesc doar rotația automată și senzorul de lumină.
**Nu instala `hexagonrpcd` cu Recommends** (`qbootctl`, `droid-juicer` rescriu fanioanele A/B / repornesc tableta).

## 5. Autentificarea pe o tabletă fără tastatură (GDM 50)

Verificat în sursa GNOME Shell 50.1 din arbore (`libshell-18.so`, `ui/keyboard.js`, `ui/sessionMode.js`):

- tastatura virtuală este creată doar dacă `org.gnome.desktop.a11y.applications screen-keyboard-enabled` e `true` **sau**
  dacă seat-ul e în „touch mode” și ultimul dispozitiv folosit e ecranul tactil;
- „touch mode” = comutatorul `SW_TABLET_MODE` pornit (driverul `lenovo-q706f-kbd` din patch-ul `0005`, sau daemonul
  `q706f-tablet-mode`, care pornește înaintea display manager-ului); fără comutator, Mutter cere să nu existe niciun
  pointer, iar touchpad-ul pogo există mereu → OSK-ul nu ar apărea;
- în modul `gdm` bara de sus nu mai are meniul de accesibilitate din care se putea porni tastatura (doar
  `dwellClick`, `keyboard`, `quickSettings`).

Deci cu tastatura pogo desprinsă OSK-ul apare singur la atingerea câmpului de parolă, dar depinde de comutator. Ca să nu
existe nicio situație fără ieșire, imaginea pune `screen-keyboard-enabled=true` **numai pentru greeter**. Efect secundar:
la ecranul de autentificare OSK-ul apare și cu tastatura atașată. În sesiune comportamentul rămâne cel automat, plus
butonul din bară (`osk-button@q706f`). **Netestat fizic**: tableta de dezvoltare folosește autologin.

## 6. Verificarea build-ului curat (13.11.2026)

Două build-uri curate (implicit și `BRINGUP=1`), în directoare separate, fără a atinge `out/desktop/rootfs`,
`ubuntu-desktop.img`, `kernel*` sau `ubuntu-boot.img`:

```sh
ROOTFS_NAME=rootfs-verify scripts/desktop/build-rootfs.sh
ROOTFS_NAME=rootfs-verify IMG_NAME=ubuntu-desktop-verify.img scripts/desktop/make-rootimg.sh
scripts/desktop/check-rootimg.sh out/desktop/ubuntu-desktop-verify.img

BRINGUP=1 ROOTFS_NAME=rootfs-verify-bringup scripts/desktop/build-rootfs.sh
ROOTFS_NAME=rootfs-verify-bringup IMG_NAME=ubuntu-desktop-verify-bringup.img scripts/desktop/make-rootimg.sh
scripts/desktop/check-rootimg.sh out/desktop/ubuntu-desktop-verify-bringup.img
```

Rezultat: ambele build-uri reușite (mmdebstrap ~12 min fiecare, rulate în paralel; arbore 2,5 GB, 998 de pachete),
ambele imagini trec `e2fsck -fn` și toate cele 57 de verificări din `check-rootimg.sh` (loguri:
`out/desktop/check-verify*.log`): nimic în afara `/home` deținut de un utilizator obișnuit, `/etc` 0755, cele 45 de
intrări din overlay prezente și identice cu repo-ul, unitățile activate, schema GSettings compilată cu valorile noastre,
`modules.dep` cu `extra/ctn730.ko`, firmware-ul la locul lui, nicio cheie SSH / adresă MAC / profil Wi-Fi / keyring cu
conținut, iar `sudo` fără parolă, autologin-ul, `--unsafe-mode` și keyring-ul prefăcut apar numai în imaginea `BRINGUP=1`.
Arborele `rootfs-verify` a rămas neatins de `make-rootimg.sh` (nu are `/usr/lib/modules`).

**Ce nu dovedește verificarea:** niciuna dintre cele două imagini nu a fost pornită pe tabletă.

## 7. Diferențe cunoscute față de tableta de dezvoltare

- Tableta este o instalare `BRINGUP` făcută de mână; imaginea implicită nu are cele patru elemente din secțiunea 3.
- Pe tabletă mai sunt pachete instalate ocazional, care **nu** intră în imagine: `glmark2-es2-wayland`, `ffmpeg`,
  `v4l-utils`, `gpiod`, `tailscale` și `google-chrome-stable` (din depozite terțe, instalate la 15:16, neconsemnate în jurnal), `gnome-remote-desktop` (instalat din greșeală, serverul e dezactivat), pachetele `-dev` și
  `git`/`meson`/`gcc` aduse de `setup-sensors.sh`.
- Pachetul `apparmor` este în `PKGS`, dar pe tabletă nu e instalat (kernelul are LSM-ul activ): o imagine nouă încarcă
  profilurile AppArmor ale Ubuntu, lucru **netestat pe tabletă**.
- Setări făcute doar la nivel de utilizator pe tabletă și nepuse în imagine: fus orar automat și servicii de localizare,
  ziua săptămânii în ceas, `monitors.xml` (scala 167 % este oricum cea implicită).
- Serviciul `q706f-ssh-hostkeys` și tastatura forțată pe greeter sunt noi (nu rulează pe tabletă): netestate pe dispozitiv.
