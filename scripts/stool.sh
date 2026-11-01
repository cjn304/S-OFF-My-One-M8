#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# stool.sh - HTC One M8 S-OFF control tool
#
#   stool.sh status                 show S state and every parameter
#   stool.sh soff                   full S-OFF (power cycle + write flag)
#   stool.sh son                    back to S-ON
#   stool.sh backup                 snapshot all parameters to backup/<time>.txt
#   stool.sh restore <snapshot>     write a snapshot back
#   stool.sh lock bootloader       write the BL magic = locked   (S-OFF only)
#   stool.sh unlock bootloader     write the BL magic = unlocked (S-OFF only)
#   stool.sh set <param> [value]    change one parameter (backs up first)
#   stool.sh noredtext              blank the six "This build is for ..." lines in hboot
#   stool.sh splash <image.png> [--size=WxH] [--fit=...]   first boot screen
#   stool.sh splash --restore <f>   write a saved sp1 image back
#
#   params: cid <8 chars> | mid <9 chars> | version <x.y.z.w> |
#           tamper <0-255> | secure <0|3>
#
# Every command reads the current S state first.  `set` (and soff/son) take a
# full parameter snapshot into backup/<YYYYmmdd-HHMMSS>.txt before touching
# anything; the file is both human readable and restorable.
#
# The parameter table, with the offsets this script uses:
#
#   CID       board_info (p3)  @ 0x0014   8 chars, ASCII
#   MID       mfg        (p5)  @ 0x4000   9 chars, UTF-16LE
#   version   misc       (p24) @ 0x00A0   ASCII
#   tamper    pg2fs      (p6)  @ 0x511804 u32 LE
#   secure    pg1fs      (p2)  @ 0x8400   u32 LE  (0 = S-OFF, 3 = S-ON)
#   bl lock   pg1fs      (p2)  @ 0x8404   4 chars ("HTCU" = unlocked, 00000000 = locked)
#
# Two commands touch partitions that are not part of that table:
#
#   noredtext hboot      (p26)  six NUL terminated lines, located at run time
	#   splash    sp1        (p12)  little-endian RGB565, 1080x1920 unless
	#                               --size=WxH says otherwise
#
# Both need S-OFF and a full backup; noredtext rewrites hboot, which is the only
# way to brick this device.  It always dumps the 4 MB hboot partition first.
#
# Licensed GPL-2.0.
set -u

VERSION=1.0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=
BACKUP_DIR=${BACKUP_DIR:-$ROOT/backup}
STOOL_TMP=$ROOT/.stool.tmp

OFF_CID=20            # 0x0014
OFF_MID=16384         # 0x4000
OFF_VER=160           # 0x00A0
OFF_SECURE=33792      # 0x8400
OFF_BLMAGIC=33796     # 0x8404
OFF_TAMPER=5314564    # 0x511804

say()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- environment

find_tool() { # $1 = name, $2.. = fallbacks
	name=$1; shift
	if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
	for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return; }; done
	return 1
}

ADB=${ADB:-$(find_tool adb C:/adb/adb.exe "$HOME/AppData/Local/Android/Sdk/platform-tools/adb.exe" || true)}
FB=${FB:-$(find_tool fastboot C:/adb/fastboot.exe "$HOME/AppData/Local/Android/Sdk/platform-tools/fastboot.exe" || true)}
PY=${PY:-$(find_tool python3 python || true)}

[ -n "$ADB" ] || ADB=adb
[ -n "$FB" ] || FB=fastboot
[ -n "$PY" ] || die "python3 is required"

device_mode() {
	# adb devices both starts the server and waits for it, unlike get-state which
	# fails immediately when the server is not up yet ("cannot connect to daemon").
	i=0
	while [ $i -lt 3 ]; do
		if "$ADB" devices 2>/dev/null | tr -d '\r' | grep -qE '[[:space:]]device$'; then
			printf android; return
		fi
		sleep 1; i=$((i + 1))
	done
	if "$FB" devices 2>/dev/null | grep -q fastboot; then
		printf fastboot; return
	fi
	if "$FB" devices 2>/dev/null | grep -q fastboot; then
		printf fastboot; return
	fi
	printf none
}

# adbd is root in TWRP; on a booted system Magisk's su has to wrap the command.
# DEV_SU: 0 = adbd already root, 1 = use su -c, 2 = no root at all.
DEV_SU=
detect_root() {
	[ -n "$DEV_SU" ] && { [ "$DEV_SU" -ne 2 ]; return; }
	u=$("$ADB" shell id -u 2>/dev/null | tr -d '\r')
	if [ "$u" = 0 ]; then DEV_SU=0; return 0; fi
	if "$ADB" shell "su -c 'id -u'" 2>/dev/null | tr -d '\r' | grep -qx 0; then
		DEV_SU=1; return 0
	fi
	DEV_SU=2
	return 1
}

devsh() { # run one command on the device as root; $1 must not contain single quotes
	if [ "$DEV_SU" = 1 ]; then
		"$ADB" shell "su -c '$1'"
	else
		"$ADB" shell "$1"
	fi
}

require_android() {
	case "$(device_mode)" in
	android) ;;
	fastboot)
		die "device is sitting in the bootloader - run 'fastboot reboot' first (or use a fastboot path)" ;;
	*)
		die "no device found: check the cable and that adb debugging is on" ;;
	esac
	detect_root || die "adb shell is neither root nor able to run su - check Magisk/TWRP"
	detect_dev || die "no by-name directory containing pg1fs (looked in bootdevice, by-name and platform/*)"
}

# The by-name directory moved between SoCs and Android releases:
#   m8    /dev/block/bootdevice/by-name
#   pme   /dev/block/platform/soc/7464900.sdhci/by-name
# probe for a directory that actually contains pg1fs instead of assuming.
detect_dev() {
	[ -n "$DEV" ] && return 0
	for c in /dev/block/bootdevice/by-name /dev/block/by-name; do
		if devsh "test -e $c/pg1fs && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok; then
			DEV=$c
			return 0
		fi
	done
	for c in $(devsh "ls -d /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name 2>/dev/null" |
		tr -d '\r'); do
		if devsh "test -e $c/pg1fs && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok; then
			DEV=$c
			return 0
		fi
	done
	return 1
}

wait_fastboot() {
	i=0
	while [ $i -lt 60 ]; do
		"$FB" devices 2>/dev/null | grep -q fastboot && return 0
		sleep 1; i=$((i + 1))
	done
	die "device did not enter fastboot"
}

wait_android() {
	"$ADB" wait-for-device
	i=0
	while [ $i -lt 60 ]; do
		[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && return 0
		sleep 1; i=$((i + 1))
	done
	warn "boot_completed never became 1"
}

# ---------------------------------------------------------------- byte access

hex_at() { # part offset len -> lowercase hex, no separators
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing pg1fs"
	# dd on the device wants decimal; callers may pass 0x...
	off=$(( $2 ))
	devsh "dd if=$DEV/$1 bs=1 skip=$off count=$3 2>/dev/null" |
		od -An -v -tx1 | tr -d ' \r\n'
}

hex2str() { # ascii, up to first NUL
	"$PY" - "$1" <<'EOF'
import sys, binascii
d = binascii.unhexlify(sys.argv[1])
sys.stdout.write(d.split(b'\x00')[0].decode('latin1'))
EOF
}

hex2utf16() {
	"$PY" - "$1" <<'EOF'
import sys, binascii
d = binascii.unhexlify(sys.argv[1])
sys.stdout.write(d.decode('utf-16-le', 'replace').split('\x00')[0])
EOF
}

str2hex()  { "$PY" -c 'import sys,binascii;sys.stdout.write(binascii.hexlify(sys.argv[1].encode("ascii")).decode())' "$1"; }
utf2hex()  { "$PY" -c 'import sys,binascii;sys.stdout.write(binascii.hexlify(sys.argv[1].encode("utf-16-le")).decode())' "$1"; }
le32()     { "$PY" -c 'import sys,binascii;print(int.from_bytes(binascii.unhexlify(sys.argv[1]),"little"))' "$1"; }
u32hex()   { "$PY" -c 'import sys,struct;print(struct.pack("<I",int(sys.argv[1])).hex())' "$1"; }

write_hex() { # part offset hexstring
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing pg1fs"
	part=$1; off=$(( $2 )); hx=$3
	n=$(( ${#hx} / 2 ))
	"$PY" - "$hx" > "$STOOL_TMP" <<'EOF'
import sys, binascii
sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))
EOF
	"$ADB" push "$STOOL_TMP" //data/local/tmp/stool.bin >/dev/null 2>&1 || die "adb push failed"
	devsh "dd if=/data/local/tmp/stool.bin of=$DEV/$part bs=1 seek=$off count=$n 2>&1 | tail -1" >&2
	devsh "rm -f /data/local/tmp/stool.bin" >/dev/null 2>&1
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	rm -f "$STOOL_TMP"
}

verify_hex() { # part offset hexstring -> 0 if the card returns the same bytes
	want=$3
	got=$(hex_at "$1" "$2" $(( ${#want} / 2 )))
	[ "$want" = "$got" ] || die "read-back mismatch at $1+$2: wrote $want, read $got"
}

dump_part() { # part dest-file  (whole partition, pulled to the PC)
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing pg1fs"
	# The double slash is for Git Bash: a single leading /data/... gets
	# rewritten into a Windows path before adb ever sees it.
	devsh "dd if=$DEV/$1 of=/data/local/tmp/stool_$1.img bs=4096" >/dev/null 2>&1
	devsh "chmod 644 /data/local/tmp/stool_$1.img" >/dev/null 2>&1
	"$ADB" pull "//data/local/tmp/stool_$1.img" "$2" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_$1.img" >/dev/null 2>&1
	[ -s "$2" ]
}

# ---------------------------------------------------------------- parameters

p_cid()     { hex2str   "$(hex_at board_info $OFF_CID 8)"; }
p_mid()     { hex2utf16 "$(hex_at mfg        $OFF_MID 18)"; }
p_version() { hex2str   "$(hex_at misc       $OFF_VER 16)"; }
p_tamper()  { le32      "$(hex_at pg2fs      $OFF_TAMPER 4)"; }
p_secure()  { le32      "$(hex_at pg1fs      $OFF_SECURE 4)"; }
p_bl()      { h=$(hex_at pg1fs $OFF_BLMAGIC 4)
	case "$h" in 48544355) printf "HTCU (unlocked)";;
	             00000000) printf "00000000 (locked)";;
	             *) printf "%s" "$h";; esac; }

secure_state() { # "off" | "on"
	[ "$(p_secure)" = 0 ] && printf off || printf on
}

bl_state() { # "unlocked" | "locked"
	case "$(hex_at pg1fs $OFF_BLMAGIC 4)" in
	48544355) printf unlocked ;;
	*) printf locked ;;
	esac
}

print_state() {
	case "$(device_mode)" in
	android)
		if ! detect_root; then
			say "S state : unknown (no root - TWRP, adb root or Magisk su needed)"
			return 0
		fi
		if ! detect_dev; then
			say "S state : unknown (no by-name directory contains pg1fs -"
			say "          this looks like a device this tool does not cover)"
			return 0
		fi
		st=$(secure_state)
		if [ "$st" = off ]; then say "S state : S-OFF (secure_flag 0)"
		else say "S state : S-ON  (secure_flag $(p_secure))"; fi
		say "BL state: $(bl_state) (pg1fs 0x8404 = $(p_bl))"
		;;
	fastboot)
		sf=$("$FB" oem readsecureflag 2>&1 | sed -n 's/.*secure_flag: //p' | tr -d '\r')
		case "$sf" in
		0) say "S state : S-OFF (secure_flag 0)" ;;
		"") say "S state : unknown (could not read secure_flag)" ;;
		*) say "S state : S-ON  (secure_flag $sf)" ;;
		esac
		bl=$("$FB" oem refurbish unlockstatus 2>&1 | tr -d '\r')
		case "$bl" in
		*"device unlocked"*) say "BL state: unlocked" ;;
		*"device locked"*)   say "BL state: locked" ;;
		*) say "BL state: unknown" ;;
		esac
		;;
	*)
		die "no device found (adb or fastboot)"
		;;
	esac
}

# ---------------------------------------------------------------- snapshot

snapshot_write() { # target file
	f=$1
	{
		printf '# S-OFF-My-One-M8 parameter snapshot\n'
		printf '# time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '# kernel=%s\n' "$("$ADB" shell uname -r 2>/dev/null | tr -d '\r')"
		printf '# device=%s\n' "$("$ADB" shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
		printf 'state=%s\n' "$(secure_state)"
		printf 'cid=%s\n' "$(p_cid)"
		printf 'mid=%s\n' "$(p_mid)"
		printf 'version=%s\n' "$(p_version)"
		printf 'tamper=%s\n' "$(p_tamper)"
		printf 'secure=%s\n' "$(p_secure)"
		printf 'bl=%s\n'     "$(bl_state)"
		printf '# raw bytes, restorable with: stool.sh restore <this file>\n'
		printf 'raw:board_info:0x%04x=%s\n' $OFF_CID    "$(hex_at board_info $OFF_CID 8)"
		printf 'raw:mfg:0x%04x=%s\n'        $OFF_MID    "$(hex_at mfg        $OFF_MID 18)"
		printf 'raw:misc:0x%04x=%s\n'       $OFF_VER    "$(hex_at misc       $OFF_VER 16)"
		printf 'raw:pg2fs:0x%x=%s\n'        $OFF_TAMPER "$(hex_at pg2fs      $OFF_TAMPER 4)"
		printf 'raw:pg1fs:0x%x=%s\n'        $OFF_SECURE "$(hex_at pg1fs      $OFF_SECURE 4)"
		printf 'raw:pg1fs:0x%x=%s\n'        $OFF_BLMAGIC "$(hex_at pg1fs     $OFF_BLMAGIC 4)"
	} > "$f"
}

cmd_backup() {
	require_android
	mkdir -p "$BACKUP_DIR"
	ts=$(date +%Y%m%d-%H%M%S)
	f=$BACKUP_DIR/$ts.txt
	snapshot_write "$f"
	[ -s "$f" ] || die "backup failed"

	# The txt only holds the bytes this tool writes.  `set cid` goes through
	# `fastboot oem writecid`, which is opaque to us, so keep whole images of
	# the three metadata partitions as well - they are 1.3 MB together.
	for part in board_info mfg misc; do
		img=$BACKUP_DIR/$ts.$part.img
		dump_part "$part" "$img" || warn "could not dump $part"
	done

	printf '%s\n' "$f"
}

# ---------------------------------------------------------------- status

cmd_status() {
	say "== state =="
	print_state
	mode=$(device_mode)
	if [ "$mode" = fastboot ]; then
		say ""
		say "== parameters (bootloader view) =="
		printf '%-9s %s\n' CID      "$("$FB" getvar cidnum 2>&1 | sed -n 's/.*cidnum: //p' | tr -d '\r')"
		printf '%-9s %s\n' MID      "$("$FB" getvar modelid 2>&1 | sed -n 's/.*modelid: //p' | tr -d '\r')"
		printf '%-9s %s\n' version  "$("$FB" getvar version-main 2>&1 | sed -n 's/.*version-main: //p' | tr -d '\r')"
		printf '%-9s %s\n' hboot    "$("$FB" getvar version-bootloader 2>&1 | sed -n 's/.*version-bootloader: //p' | tr -d '\r')"
		blv=$("$FB" oem refurbish unlockstatus 2>&1 | tr -d '\r')
		case "$blv" in
		*"device unlocked"*) blv=unlocked ;;
		*"device locked"*)   blv=locked ;;
		*) blv=unknown ;;
		esac
		printf '%-9s %s\n' "BL lock" "$blv"
		return 0
	fi
	# print_state already explained why it could not read anything
	detect_root && detect_dev || return 0
	require_android
	say ""
	say "== parameters =="
	printf '%-9s %-12s %s\n' CID      "$(p_cid)"     "board_info p3 @ 0x14"
	printf '%-9s %-12s %s\n' MID      "$(p_mid)"     "mfg p5 @ 0x4000 (UTF-16LE)"
	printf '%-9s %-12s %s\n' version  "$(p_version)" "misc p24 @ 0xA0"
	printf '%-9s %-12s %s\n' tamper   "$(p_tamper)"  "pg2fs p6 @ 0x511804"
	printf '%-9s %-12s %s\n' secure   "$(p_secure)"  "pg1fs p2 @ 0x8400"
	printf '%-9s %-12s %s\n' "BL lock" "$(bl_state)" "pg1fs p2 @ 0x8404"
	say ""
	printf '%-9s %s\n' modules  "$(devsh "cat /proc/sys/kernel/modules_disabled 2>/dev/null" | tr -d '\r') (0 = allowed)"
	printf '%-9s %s\n' selinux  "$("$ADB" shell getenforce 2>/dev/null | tr -d '\r')"
}

# ---------------------------------------------------------------- set

cmd_set() {
	param=${1:-}; val=${2:-}
	[ -n "$param" ] || die "usage: stool.sh set <cid|mid|version|tamper|secure> [value]"

	case "$param" in
	cid|mid|version|tamper|secure)
		require_android
		;;
	*)
		die "unknown parameter: $param"
		;;
	esac

	say "== state before =="
	print_state
	say ""
	say "== backup =="
	say "saved: $(cmd_backup)"

	cur_st=$(secure_state 2>/dev/null || printf "?")
	say ""

	case "$param" in
	cid)
		[ ${#val} -eq 8 ] || die "CID must be exactly 8 characters (got '$val')"
		say "CID: $(p_cid) -> $val   (fastboot oem writecid)"
		"$ADB" reboot bootloader
		wait_fastboot
		"$FB" oem writecid "$val" || die "writecid failed (needs S-OFF)"
		"$FB" reboot-bootloader >/dev/null 2>&1 || true
		wait_fastboot
		say "now: $("$FB" getvar cidnum 2>&1 | sed -n 's/.*cidnum: //p' | tr -d '\r')"
		"$FB" reboot
		;;
	mid)
		[ ${#val} -eq 9 ] || die "MID must be exactly 9 characters (got '$val')"
		hx=$(utf2hex "$val" | sed 's/\(..\)/\1/g')
		hx=$("$PY" -c 'import sys;h=sys.argv[1];print((h+"00"*16)[:36])' "$hx")
		say "MID: $(p_mid) -> $val"
		write_hex mfg $OFF_MID "$hx"
		verify_hex mfg $OFF_MID "$hx"
		say "ok"
		;;
	version)
		[ -n "$val" ] || die "version must not be empty"
		[ ${#val} -le 15 ] || die "version too long (max 15 chars)"
		hx=$(str2hex "$val")
		hx=$("$PY" -c 'import sys;h=sys.argv[1];print((h+"00"*16)[:32])' "$hx")
		say "version: $(p_version) -> $val"
		write_hex misc $OFF_VER "$hx"
		verify_hex misc $OFF_VER "$hx"
		say "ok"
		;;
	tamper)
		case "$val" in ''|*[!0-9]*) die "tamper takes a decimal number (0-255)";; esac
		[ "$val" -le 255 ] || die "tamper out of range"
		hx=$(u32hex "$val")
		say "tamper: $(p_tamper) -> $val"
		write_hex pg2fs $OFF_TAMPER "$hx"
		verify_hex pg2fs $OFF_TAMPER "$hx"
		say "ok"
		;;
	secure)
		case "$val" in 0|3) ;; *) die "secure takes 0 (S-OFF) or 3 (S-ON)";; esac
		if [ "$val" = 0 ] && [ "$cur_st" != off ]; then
			die "writing 0 while S-ON needs the eMMC write protection cleared - run 'stool.sh soff'"
		fi
		hx=$(u32hex "$val")
		say "secure: $(p_secure) -> $val"
		write_hex pg1fs $OFF_SECURE "$hx"
		verify_hex pg1fs $OFF_SECURE "$hx"
		say "ok"
		;;
	esac
}

# ---------------------------------------------------------------- BL lock

cmd_bl() { # locked | unlocked
	want=$1
	require_android
	say "== state before =="
	print_state
	say ""
	say "== backup =="
	say "saved: $(cmd_backup)"

	# 0x8404 sits in the same eMMC write-protected range as the S flag.
	[ "$(secure_state)" = off ] ||
		die "writing the BL magic needs the eMMC write protection cleared - run 'stool.sh soff'"

	if [ "$want" = locked ]; then
		hx=00000000
	else
		hx=48544355
	fi
	say ""
	say "BL lock: $(bl_state) -> $want   (pg1fs 0x8404 = $hx)"
	write_hex pg1fs $OFF_BLMAGIC "$hx"
	verify_hex pg1fs $OFF_BLMAGIC "$hx"
	say "ok - reboot to the bootloader to see it"
}

# ---------------------------------------------------------------- soff / son

push_module() { # diag|off|on
	src=$ROOT/kmod/pwrsq_$1.ko
	[ -f "$src" ] || die "missing $src - build first (scripts/build.sh)"
	"$ADB" push "$src" "//dev/pwrsq_$1.ko" >/dev/null || die "adb push failed"
}

check_write_protection() {
	bin=$ROOT/tools/mmc_cmd
	[ -x "$bin" ] || { warn "tools/mmc_cmd not built - skipping the write-protection check"; return 0; }
	"$ADB" push "$bin" //dev/mmc_cmd >/dev/null 2>&1
	"$ADB" shell 'chmod 755 /dev/mmc_cmd'
	out=$("$ADB" shell '/dev/mmc_cmd wp' 2>&1 | tr -d '\r')
	printf '%s\n' "$out" | sed 's/^/  /'
	printf '%s\n' "$out" | grep -q 'no write protection' ||
		die "eMMC write protection is still active - power cycle did not take effect"
}

cmd_soff() {
	require_android
	say "== state before =="
	print_state
	[ "$(secure_state)" = off ] && { say ""; say "already S-OFF, nothing to do"; return 0; }

	[ "$(devsh "cat /proc/sys/kernel/modules_disabled 2>/dev/null" | tr -d '\r')" = 0 ] ||
		die "module loading is disabled on this kernel"
	[ "$("$ADB" shell getenforce 2>/dev/null | tr -d '\r')" = Permissive ] ||
		warn "SELinux is not permissive - loading the module may be denied"

	say ""
	say "== backup =="
	say "saved: $(cmd_backup)"

	say ""
	say "== diagnostic (no side effects) =="
	push_module diag
	out=$("$ADB" shell 'dmesg -c >/dev/null; insmod /dev/pwrsq_diag.ko; sleep 1; dmesg | grep pwrsq' 2>&1 | tr -d '\r')
	printf '%s\n' "$out"
	printf '%s\n' "$out" | grep -q 'name=8941_l20' ||
		die "regulator 8941_l20 not found - wrong device/kernel?"
	"$ADB" shell 'rmmod pwrsq_diag' >/dev/null 2>&1 || true

	say ""
	say "== quiesce =="
	"$ADB" shell 'stop; sleep 8; sync; sync'
	say "framework stopped, caches flushed"

	say ""
	say "== power cycle =="
	push_module off
	push_module on
	"$ADB" shell 'insmod /dev/pwrsq_off.ko; insmod /dev/pwrsq_on.ko; echo SEQ_DONE' | tr -d '\r'
	sleep 3

	"$ADB" shell 'test -b /dev/block/mmcblk0p2' ||
		die "eMMC did not come back - hold power ~10s, then retry"

	say ""
	say "== write protection =="
	check_write_protection

	say ""
	say "== write secure flag =="
	write_hex pg1fs $OFF_SECURE "$(u32hex 0)"
	verify_hex pg1fs $OFF_SECURE 00000000
	say "pg1fs 0x8400 = 0"

	say ""
	say "== verify from bootloader =="
	"$ADB" reboot bootloader
	wait_fastboot
	sf=$("$FB" oem readsecureflag 2>&1 | sed -n 's/.*secure_flag: //p' | tr -d '\r')
	sec=$("$FB" getvar security 2>&1 | sed -n 's/.*security: //p' | tr -d '\r')
	say "secure_flag: $sf   security: $sec"
	[ "$sf" = 0 ] || die "secure_flag is $sf, expected 0"
	"$FB" reboot
	wait_android
	say ""
	say "done - S-OFF"
}

cmd_son() {
	require_android
	say "== state before =="
	print_state
	[ "$(secure_state)" = on ] && { say ""; say "already S-ON, nothing to do"; return 0; }

	say ""
	say "== backup =="
	say "saved: $(cmd_backup)"

	say ""
	say "== write secure flag =="
	write_hex pg1fs $OFF_SECURE "$(u32hex 3)"
	verify_hex pg1fs $OFF_SECURE 03000000
	say "pg1fs 0x8400 = 3"

	say ""
	say "== verify from bootloader =="
	"$ADB" reboot bootloader
	wait_fastboot
	sf=$("$FB" oem readsecureflag 2>&1 | sed -n 's/.*secure_flag: //p' | tr -d '\r')
	say "secure_flag: $sf"
	[ "$sf" = 3 ] || warn "expected 3, got $sf"
	"$FB" reboot
	wait_android
	say ""
	say "done - S-ON (write protection comes back on the next boot)"
}

# ---------------------------------------------------------------- restore

cmd_restore() {
	f=${1:-}
	[ -n "$f" ] || die "usage: stool.sh restore <snapshot.txt>"
	[ -f "$f" ] || die "no such file: $f"
	require_android

	say "== state now =="
	print_state
	say ""
	say "== safety snapshot =="
	say "saved: $(cmd_backup)"
	say ""
	say "== restoring $f =="

	grep '^raw:' "$f" > "$STOOL_TMP.list"
	while IFS= read -r line; do
		key=${line%%=*}
		val=${line#*=}
		rest=${key#raw:}
		part=${rest%%:*}
		off=${rest#*:}
		case "$part" in
		pg1fs|board_info|mfg|pg2fs|misc) ;;
		*) warn "skip unknown partition '$part'"; continue ;;
		esac
		say "  $part @ $off = $val"
		write_hex "$part" "$off" "$val"
		verify_hex "$part" "$off" "$val"
	done < "$STOOL_TMP.list"
	rm -f "$STOOL_TMP.list"

	say ""
	say "done - values from the snapshot are back on the card"
}

# ---------------------------------------------------------------- hboot / splash

winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

flash_part() { # part src-file  (write a whole image, used by the --restore paths)
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing pg1fs"
	say "writing $(wc -c < "$2" | tr -d ' ') bytes to $1"
	"$ADB" push "$2" //data/local/tmp/stool_flash.img >/dev/null 2>&1 || die "adb push failed"
	devsh "dd if=/data/local/tmp/stool_flash.img of=$DEV/$1 bs=4096 2>&1 | tail -2" >&2
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_flash.img" >/dev/null 2>&1
}

cmd_noredtext() {
	if [ "${1:-}" = --restore ]; then
		src=${2:-}
		[ -n "$src" ] && [ -f "$src" ] || die "usage: stool.sh noredtext --restore <hboot.img>"
		require_android
		[ "$(secure_state)" = off ] || die "writing hboot needs S-OFF"
		[ "$(wc -c < "$src" | tr -d ' ')" = 4194304 ] || die "not a 4 MB hboot image: $src"
		flash_part hboot "$src"
		say "ok - reboot to see it"
		return 0
	fi

	require_android
	say "== state before =="
	print_state
	say ""
	[ "$(secure_state)" = off ] ||
		die "writing hboot needs S-OFF - the partition is write protected while S-ON"

	say "== backup =="
	pf=$(cmd_backup)
	say "params : $pf"
	ts=$(date +%Y%m%d-%H%M%S)
	hb=$BACKUP_DIR/$ts.hboot.img
	dump_part hboot "$hb" || die "could not dump the hboot partition"
	sz=$(wc -c < "$hb" | tr -d ' ')
	say "hboot  : $hb ($sz bytes)"
	[ "$sz" = 4194304 ] || die "hboot dump is $sz bytes, expected 4194304 - aborting"

	say ""
	say "== locate =="
	offs=$(cat "$hb" | "$PY" "$(winpath "$ROOT/scripts/find_redtext.py")") ||
		die "the six red-text lines were not found in this hboot"

	for o in $offs; do
		b=$(hex_at hboot "$o" 1)
		say "  0x$(printf '%06x' "$o")  first byte = $b"
	done

	say ""
	say "== patch =="
	printf '\000' > "$STOOL_TMP.zero"
	printf '#!/system/bin/sh\n' > "$STOOL_TMP.nr.sh"
	for o in $offs; do
		printf 'dd if=/data/local/tmp/stool_zero.bin of=%s/hboot bs=1 seek=%s count=1 || exit 1\n' \
			"$DEV" "$o" >> "$STOOL_TMP.nr.sh"
	done
	printf 'sync\n' >> "$STOOL_TMP.nr.sh"

	"$ADB" push "$STOOL_TMP.zero"  //data/local/tmp/stool_zero.bin >/dev/null 2>&1 || die "adb push failed"
	"$ADB" push "$STOOL_TMP.nr.sh" //data/local/tmp/stool_nr.sh   >/dev/null 2>&1 || die "adb push failed"
	devsh "sh /data/local/tmp/stool_nr.sh" >&2
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_zero.bin /data/local/tmp/stool_nr.sh" >/dev/null 2>&1
	rm -f "$STOOL_TMP.zero" "$STOOL_TMP.nr.sh"

	say ""
	say "== verify =="
	for o in $offs; do
		verify_hex hboot "$o" 00
		say "  0x$(printf '%06x' "$o")  ok"
	done

	say ""
	say "six bytes blanked.  Reboot and look at the first screen."
	say "undo   : stool.sh noredtext --restore $hb"
}

cmd_splash() {
	if [ "${1:-}" = --restore ]; then
		src=${2:-}
		[ -n "$src" ] && [ -f "$src" ] || die "usage: stool.sh splash --restore <sp1.img>"
		require_android
		[ "$(secure_state)" = off ] || die "writing sp1 needs S-OFF"
		flash_part sp1 "$src"
		say "ok - reboot to see it"
		return 0
	fi

	img=${1:-}
	[ -n "$img" ] || die "usage: stool.sh splash <image.png> [--size=WxH] [--fit=cover|stretch]   or   stool.sh splash --restore <sp1.img>"
	[ -f "$img" ] || die "no such file: $img"
	shift
	# --size is ours; everything else goes to the converter
	size=1080x1920
	fitarg=
	for a in "$@"; do
		case $a in
		--size=*) size=${a#--size=} ;;
		*)        fitarg="$fitarg $a" ;;
		esac
	done
	w=${size%x*}
	h=${size#*x}
	case "${w}${h}" in
	''|*[!0-9]*) die "bad --size '$size', expected --size=WxH" ;;
	esac
	exp=$((w * h * 2))
	say "size   : ${w}x${h} -> $exp bytes per frame"
	require_android

	say "== convert =="
	raw=$STOOL_TMP.splash
	"$PY" "$(winpath "$ROOT/scripts/png2rgb565.py")" "$(winpath "$img")" "$(winpath "$raw")" \
		--width="$w" --height="$h" $fitarg ||
		die "conversion failed - PNG only, see the message above"
	sz=$(wc -c < "$raw" | tr -d ' ')
	say "raw    : $sz bytes"
	[ "$sz" = "$exp" ] || die "converted image is $sz bytes, expected $exp"
	# check before dumping 10 MB of partition that we cannot use anyway
	psz=$(devsh "blockdev --getsize64 $DEV/sp1 2>/dev/null" | tr -d '\r')
	if [ -n "$psz" ] && [ "$exp" -gt "$psz" ]; then
		die "a ${w}x${h} frame is $exp bytes but sp1 is only $psz bytes"
	fi

	say ""
	say "== backup =="
	pf=$(cmd_backup)
	say "params : $pf"
	ts=$(date +%Y%m%d-%H%M%S)
	sp=$BACKUP_DIR/$ts.sp1.img
	dump_part sp1 "$sp" || die "could not dump the sp1 partition"
	say "sp1    : $sp ($(wc -c < "$sp" | tr -d ' ') bytes)"

	say ""
	say "== write =="
	"$ADB" push "$raw" //data/local/tmp/stool_splash.raw >/dev/null 2>&1 || die "adb push failed"
	devsh "dd if=/data/local/tmp/stool_splash.raw of=$DEV/sp1 bs=4096 2>&1 | tail -2" >&2
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_splash.raw" >/dev/null 2>&1

	say ""
	say "== verify =="
	cnt=$(( (exp + 4095) / 4096 ))
	devsh "dd if=$DEV/sp1 of=/data/local/tmp/stool_chk.img bs=4096 count=$cnt" >/dev/null 2>&1
	devsh "chmod 644 /data/local/tmp/stool_chk.img" >/dev/null 2>&1
	"$ADB" pull "//data/local/tmp/stool_chk.img" "$STOOL_TMP.chk" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_chk.img" >/dev/null 2>&1
	[ -s "$STOOL_TMP.chk" ] || die "could not read sp1 back"

	a=$("$PY" -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read(int(sys.argv[2]))).hexdigest())" "$(winpath "$raw")" "$exp")
	b=$("$PY" -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read(int(sys.argv[2]))).hexdigest())" "$(winpath "$STOOL_TMP.chk")" "$exp")
	rm -f "$STOOL_TMP.chk" "$raw"
	[ "$a" = "$b" ] || die "read-back mismatch: wrote $a, read $b"
	say "  md5 $a  ok"

	say ""
	say "first screen replaced.  Reboot to see it."
	say "undo   : stool.sh splash --restore $sp"
}

# ---------------------------------------------------------------- main


usage() {
	cat <<EOF
stool.sh $VERSION - HTC One M8 S-OFF control tool

  stool.sh status
  stool.sh soff
  stool.sh son
  stool.sh backup
  stool.sh restore <snapshot.txt>
  stool.sh set cid <8 chars>
  stool.sh set mid <9 chars>
  stool.sh set version <x.y.z.w>
  stool.sh set tamper <0-255>
  stool.sh set secure <0|3>
  stool.sh lock bootloader         write the BL magic = locked   (S-OFF only)
  stool.sh unlock bootloader       write the BL magic = unlocked (S-OFF only)
  stool.sh noredtext               blank the six "This build is for ..." lines
  stool.sh noredtext --restore <hboot.img>
  stool.sh splash <image.png> [--size=WxH] [--fit=cover|stretch]
                                   replace the first boot screen (default 1080x1920)
  stool.sh splash --restore <sp1.img>

Every command starts by reading the current S state.  Anything that writes
takes a full parameter snapshot into backup/<YYYYmmdd-HHMMSS>.txt first.

Environment: ADB, FB, PY, BACKUP_DIR.
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd=$1; shift

case "$cmd" in
status)  cmd_status ;;
soff)    cmd_soff ;;
son)     cmd_son ;;
backup)  cmd_backup ;;
restore) cmd_restore "$@" ;;
set)     cmd_set "$@" ;;
lock)    [ "${1:-}" = bootloader ] || die "usage: stool.sh lock bootloader"
         cmd_bl locked ;;
unlock)  [ "${1:-}" = bootloader ] || die "usage: stool.sh unlock bootloader"
         cmd_bl unlocked ;;
noredtext) cmd_noredtext "$@" ;;
splash)    cmd_splash "$@" ;;
-h|--help|help) usage ;;
*) usage; exit 2 ;;
esac
