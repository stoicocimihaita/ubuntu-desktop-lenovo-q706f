#!/bin/sh
# Fingerprint stages 3+4 (approved 16.11.2026). Run ONLY on the 7.3.4-fp kernel booted from RAM.
# Stage 3: drivers + supplicant with an empty state dir. Stage 4: load the goodixfp TA once (GO/NO-GO).
# Nothing here writes to partitions or chip flash. Never sends sensor commands.
L=/var/log/q706f-fp-stage34.log
exec > $L 2>&1
set -x
uname -r | grep -q -- '-fp$' || { echo "not the fp kernel, abort"; exit 1; }
dmesg -c >/dev/null
modprobe goodix_fp_spi; modprobe qseecomtee
ls -la /dev/goodix_fp /dev/tee0 /dev/teepriv0
cat /sys/class/tee/tee0/implementation_id 2>/dev/null
mkdir -p /var/lib/qsee-supplicant
/usr/local/sbin/qsee-supplicant --state-dir /var/lib/qsee-supplicant > /var/log/q706f-qsee-supplicant.log 2>&1 &
SP=$!; sleep 3
cat /var/log/q706f-qsee-supplicant.log
# --- stage 4 ---
timeout 60 /usr/local/sbin/qsee-app-loader goodixfp > /var/log/q706f-qsee-app-loader.log 2>&1 &
AL=$!; sleep 20
cat /var/log/q706f-qsee-app-loader.log
dmesg
kill $AL 2>/dev/null; sleep 2; kill $SP 2>/dev/null
echo done
