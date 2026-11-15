# RECUPERARE.md — moduri de pornire, backup și revenire la stock

Stare (12.11.2026): **backup EDL făcut și verificat**; deblocare trimisă cu `fastboot flashing unlock` (acceptată, tableta s-a șters); `unlocked:yes` de confirmat din fastboot. Se actualizează după fiecare pas făcut pe tabletă.

## Moduri (din wiki-ul Nura, de confirmat pe tabletă)
| Mod | Cum intri | Cum ieși |
|---|---|---|
| Fastboot | tableta oprită → ții **Power + Volum sus** | `fastboot reboot` sau Power lung |
| Recovery | din meniul fastboot | meniul recovery |
| EDL (9008) | tableta oprită → ții **Volum sus** și conectezi cablul USB (ecranul rămâne negru) | ții Power ~15 s |

Pentru EDL se recomandă port și cablu USB 2.0 (raportări de la Lenovo Y700).

## Plasele de siguranță, în ordinea în care le folosim
1. ~~Slotul A/B nefolosit cu Android~~ — **nu există pe această tabletă.** E Virtual A/B: în `super` (8 GB) încap
   doar partițiile slotului activ (`_b`, firmware S530352). Slotul `_a` are în LUN4 bootloaderul și boot-ul vechi
   (S530270), dar `system_a`/`vendor_a` din `super` au fost suprascrise la ultimul OTA. Slotul `a` nu pornește Android.
   Lucrăm deci pe slotul **`b`**; revenirea = rescrierea `boot_b` (și, la nevoie, `super`) din backup.
2. **`fastboot boot`** pentru primul test: nu scrie nimic.
3. **Imaginile stock** din `backup/stock-firmware/S530352/` (boot, recovery, dtbo, vbmeta): se pot scrie din fastboot după deblocare.
4. **Backup EDL propriu** (`scripts/backup-edl.sh`): toate partițiile în afară de `userdata`, ~10,6 GB, luate de pe
   exemplarul nostru înainte de orice modificare. Conține și datele unice: `persist`, `modemst1/2`, `fsg`, `fsc`, `devinfo`.
   Revenirea se face scriind înapoi partiția afectată, tot prin EDL.
5. **Firmware-ul QFIL complet** (`firmware/*.zip`): ultima soluție. Descriptorii `rawprogram*.x` / `patch*.x` sunt
   criptați (AES, format Lenovo). Există un utilitar comunitar de decriptare (XDA, mirror lolinet), **netestat** pe
   pachetul nostru și neverificat de noi. Nu ne bazăm pe el: punctul 4 acoperă același lucru fără decriptare.

## Backup prin EDL (doar citire)
1. Tableta oprită complet; ții Volum sus și conectezi cablul. Pe PC: `lsusb -d 05c6:9008` trebuie să arate dispozitivul.
2. `scripts/backup-edl.sh` — citește LUN 0–5 cu `bkerler/edl` și loader-ul stock `prog_firehose_ddr.elf`, scrie `SHA256SUMS`.
3. Ieșire din EDL: Power ținut ~15 s; tableta pornește normal în Android.

**Executat 12.11.2026:** `backup/edl-2026-11-12/` — 112 fișiere, 11 GB, `SHA256SUMS` verificat. Loader-ul stock
acceptă `bkerler/edl` fără autentificare. Intrarea în EDL s-a făcut cu `adb reboot edl`, ieșirea cu `edl reset`
(tableta a repornit singură în Android). Verificări: `boot_b` și `vbmeta_b` identice cu firmware-ul S530352;
`persist` e ext4 valid; `persist`, `modemst1/2`, `fsg`, `fsc`, `devinfo` citite a doua oară, cu același SHA-256.

## Deblocarea bootloader-ului (ȘTERGE TOATE DATELE — doar cu confirmare separată)
Raportări pentru TB-Q706F ROW (XDA, Android 11/12): merge direct `fastboot flashing unlock`, din fastboot-ul normal
(nu fastbootd), fără `sn.img`. `fastboot oem unlock-go` nu a mers la acei utilizatori. Pentru build-ul nostru
(Android 13, S530352) nu există raportări → neverificat.
1. Setări → Opțiuni dezvoltator → **OEM unlocking** activat (acum `sys.oem_unlock_allowed=0`).
2. `adb reboot bootloader`, apoi `fastboot getvar all` (doar citire) — salvăm ieșirea în `logs/`.
3. `fastboot flashing unlock` + confirmare cu tastele de volum pe tabletă.
4. Dacă refuză: `sn.img` de la https://www.zui.com/iunlock (cont Lenovo), `fastboot flash unlock sn.img`, `fastboot oem unlock-go`.

Consecințe cunoscute: datele se șterg; OTA-urile Lenovo nu se mai instalează (oricum nu mai apar); Widevine L1 a
rămas la cei care au raportat. **Nu se reblochează** bootloader-ul cu sistem modificat (risc de brick).

## Revenire la Android stock
- Dacă doar boot-ul e stricat: `fastboot flash boot_<slot> backup/stock-firmware/S530352/boot.img` (cu confirmare).
- Dacă slotul de test e compromis: `fastboot set_active <celălalt slot>`.
- Dacă nu mai intră în fastboot: EDL + scrierea înapoi a partițiilor din backup-ul propriu.
