#!/bin/sh
# Fingerprint stage 5 (approved 16.11.2026): bring the sensor up through the TA and list
# enrolled fingers (expected: none). Run ONLY on the 7.3.4-fp kernel booted from RAM.
# Sends only DETECT_SENSOR 1000, INIT 1001, INIT_FINISHED 1005, GET_DEV_INFO 1089 and
# ENUMERATE 1015. No capture/test commands (1097/1098), never 1003/1004/1053-1056.
L=/var/log/q706f-fp-stage5.log
exec > $L 2>&1
set -x
uname -r | grep -q -- '-fp$' || { echo "not the fp kernel, abort"; exit 1; }
dmesg -c >/dev/null
modprobe goodix_fp_spi; modprobe qseecomtee
ls -la /dev/goodix_fp /dev/tee0 /dev/teepriv0
mkdir -p /var/lib/goodix-fp
/usr/local/sbin/gfharness --supp 0 serve > /var/log/q706f-gfh-supp.log 2>&1 &
SP=$!; sleep 3
sleep 300 | /usr/local/sbin/gfharness --load goodixfp > /var/log/q706f-gfh-load.log 2>&1 &
LD=$!; sleep 5
cat /var/log/q706f-gfh-supp.log /var/log/q706f-gfh-load.log
sync
timeout 60 /usr/local/sbin/gfharness --enumerate goodixfp
echo "rc=$?"
sync
cat /var/log/q706f-gfh-supp.log
dmesg
ls -laR /var/lib/goodix-fp | head -40
pkill -x gfharness; sleep 2
echo done
