#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Write the HTC secure flag: pg1fs offset 0x8400 = 0  (S-OFF).
#
#   scripts/write_flag.sh [0|3]
#
# 0 = S-OFF (what this tool is for), 3 = S-ON (undo).
#
# The eMMC power-on write protection must already be cleared, i.e. run this
# right after scripts/powercycle.sh in the same boot.  If the write silently
# does not stick, the protection is still active - see the Recovery section of README.md.
set -e

ADB=${ADB:-adb}
VAL=${1:-0}
OFF=33792          # 0x8400
DEV=/dev/block/bootdevice/by-name/pg1fs

case "$VAL" in
0) BIN='\000' ;;
3) BIN='\003' ;;
*) echo "usage: $0 [0|3]" >&2; exit 2 ;;
esac

echo "before:"
$ADB shell "dd if=$DEV bs=1 skip=$OFF count=8 2>/dev/null | od -An -tx1"

printf "$BIN" > /tmp/flag.bin
$ADB push /tmp/flag.bin //dev/flag.bin >/dev/null
$ADB shell "dd if=/dev/flag.bin of=$DEV bs=1 seek=$OFF count=1; sync; echo 3 > /proc/sys/vm/drop_caches"
$ADB shell "rm -f /dev/flag.bin"

echo "after:"
$ADB shell "dd if=$DEV bs=1 skip=$OFF count=8 2>/dev/null | od -An -tx1"

echo
echo "Verify from the bootloader:  fastboot oem readsecureflag   (expect: 0)"
