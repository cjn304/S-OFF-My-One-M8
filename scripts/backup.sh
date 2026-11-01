#!/bin/sh
# Back up every partition this procedure can touch.
#
#   scripts/backup.sh [output-dir]
#
# pg1fs  - secure flag (0x8400) lives here
# board_info (p3) - HTC-BOARD-INFO + CID + IMEI
# mfg (p5)        - model ID at 0x4000 (UTF-16LE)
# radio (p20)     - baseband image
# misc (p24)      - version-main at 0xA0
#
# Keep the result off the phone: if the eMMC does not come back after a power
# cycle these images are your only way back.
set -e

ADB=${ADB:-adb}
OUT=${1:-./backup-$(date +%Y%m%d-%H%M%S)}

mkdir -p "$OUT"
echo "backing up to $OUT"

for part in pg1fs board_info mfg radio misc; do
	printf '  %-11s ' "$part"
	$ADB shell "dd if=/dev/block/bootdevice/by-name/$part of=/data/local/tmp/$part.img bs=1048576" >/dev/null 2>&1
	$ADB pull "/data/local/tmp/$part.img" "$OUT/$part.img" >/dev/null 2>&1
	$ADB shell "rm -f /data/local/tmp/$part.img" >/dev/null 2>&1
	echo "$(wc -c < "$OUT/$part.img") bytes"
done

( cd "$OUT" && md5sum ./*.img > MD5SUMS )
echo "done - checksums in $OUT/MD5SUMS"
