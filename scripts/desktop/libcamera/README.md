# libcamera pentru q706f

Ubuntu 26.04 livrează libcamera 0.7.0-1ubuntu2 fără `CameraSensorHelper` pentru senzorii tabletei
(ov13b10 spate principal, s5k5e9 spate secundar, ov8856 față). Fără helper, ISP-ul software al
pipeline-ului „simple” lucrează cu codurile brute de amplificare și pozele ies întunecate.

| Fișier | Rol |
|---|---|
| `0001-libipa-add-ov13b10-ov8856-s5k5e9-sensor-helpers.patch` | modelele de amplificare (și nivelul de negru pentru ov8856); antetul explică valorile și sursa lor |
| `build-libcamera.sh` | reconstruiește tot pachetul sursă Ubuntu (arm64, container `ubuntu:26.04` prin qemu) cu patch-urile `NNNN-*.patch`; rezultat în `out/desktop/libcamera/debs/`, versiunea `0.7.0-1ubuntu2+q706f1` |
| `camtest.sh` | test pe tabletă: 60 de cadre per cameră, ultimul AnalogueGain/ExposureTime, luminozitatea medie, JPEG mic |

Se reconstruiește tot pachetul (nu doar `ipa_soft_simple.so`) pentru că modulele IPA sunt semnate cu o
cheie generată la build și verificată de `libcamera.so`; dacă semnăturile nu se potrivesc, IPA rulează izolat.

## Instalare pe tabletă

Pe tabletă se instalează doar pachetele binare care erau deja instalate din sursa `libcamera`:
`libcamera0.7`, `libcamera-ipa`, `libcamera-tools`, `libcamera-v4l2`, `gstreamer1.0-libcamera`.
Pachetele sunt fixate cu `apt-mark hold`, ca un `apt upgrade` să nu le înlocuiască pe tăcute cu cele din Ubuntu.
Atenție: cât timp sunt fixate, nici actualizările de securitate Ubuntu pentru libcamera nu se instalează;
la o versiune nouă în arhivă, se reface build-ul cu `UBUNTU_VER=<versiunea nouă>`.

Originalele sunt salvate pe tabletă în `/var/lib/q706f/pkg-backups/libcamera-0.7.0-1ubuntu2/`.

## Revenire la pachetele Ubuntu

```sh
sudo apt-mark unhold libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera
sudo dpkg -i /var/lib/q706f/pkg-backups/libcamera-0.7.0-1ubuntu2/*.deb
# sau, cu rețea: sudo apt-get install --no-install-recommends --allow-downgrades \
#   libcamera0.7=0.7.0-1ubuntu2 libcamera-ipa=0.7.0-1ubuntu2 libcamera-tools=0.7.0-1ubuntu2 \
#   libcamera-v4l2=0.7.0-1ubuntu2 gstreamer1.0-libcamera=0.7.0-1ubuntu2
XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart wireplumber   # ca utilizator ubuntu
```

Verificare: `dpkg -l 'libcamera*' gstreamer1.0-libcamera` arată din nou `0.7.0-1ubuntu2`.
