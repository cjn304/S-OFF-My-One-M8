#!/bin/sh
# Cut and restore VCC to the eMMC, then let the MMC core re-scan the card.
#
#   scripts/powercycle.sh
#
# The modules are copied to /dev (tmpfs) first: once the eMMC is unpowered any
# file still living on /data is unreadable, and insmod would block.
#
# Before running this: stop the framework and get the eMMC idle
# (`adb shell stop; adb shell sync`) - see README.md, Quick start.
set -e

ADB=${ADB:-adb}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

for m in diag off on; do
	[ -f "$ROOT/kmod/pwrsq_$m.ko" ] || {
		echo "kmod/pwrsq_$m.ko missing - build first" >&2
		exit 1
	}
	$ADB push "$ROOT/kmod/pwrsq_$m.ko" "/dev/pwrsq_$m.ko" >/dev/null
done

echo "--- diagnostic ---"
$ADB shell 'dmesg -c >/dev/null; insmod /dev/pwrsq_diag.ko; sleep 1; dmesg | grep pwrsq'
$ADB shell 'rmmod pwrsq_diag'

echo "--- power off / power on ---"
$ADB shell 'insmod /dev/pwrsq_off.ko; insmod /dev/pwrsq_on.ko; echo SEQ_DONE'

sleep 3
echo "--- result ---"
$ADB shell 'cat /proc/partitions | grep -E "mmcblk0 |mmcblk0p2"; dmesg | grep -iE "pwrsq|mmc_reinit_card" | tail -20'
