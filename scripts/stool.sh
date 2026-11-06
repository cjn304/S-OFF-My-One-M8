#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# stool.sh - HTC One M8 S-OFF control tool
#
#   stool.sh status                 show S state and every parameter
#   stool.sh soff                   full S-OFF (power cycle + write flag)
#   stool.sh son                    back to S-ON
#   stool.sh backup [partition]     all of it, or one partition as one image
#   stool.sh restore <partition> <file.img>
#                                   write one saved image back
#   stool.sh lock                  write the BL magic = locked
#   stool.sh unlock                write the BL magic = unlocked
#   stool.sh set <param> [value]    change one parameter
#   stool.sh nowarn                blank the six "This build is for ..." lines in hboot
#   stool.sh splash <image.png> [--size=WxH] [--fit=...]   first boot screen
#
#   params: cid <8 chars> | mid <9 chars> | version <x.y.z.w> |
#           tamper <0-255> | secure <0|3>
#
# Every command reads the current S state first, and every command that writes
# is refused while S-ON.  Nothing is backed up automatically: `backup` writes
# one image per partition plus a txt of what `status` prints and the command
# that restores each image, and `restore` writes one named image back.
#
# Where each parameter lives is not fixed here.  targets.conf holds one section
# per partition layout and the script picks one by comparing the sizes the
# device reports in /sys/class/block/*/uevent; no match means no run, rather than
# writing at the M8 offsets on a phone that is not an M8.  The M8 section:
#
#   CID       board_info (p3)  @ 0x0014   8 chars, ASCII
#   MID       mfg        (p5)  @ 0x4000   9 chars, UTF-16LE
#   version   misc       (p24) @ 0x00A0   ASCII
#   tamper    pg2fs      (p6)  @ 0x511804 u32 LE
#   secure    pg1fs      (p2)  @ 0x8400   u32 LE  (0 = S-OFF, 3 = S-ON)
#   bl lock   pg1fs      (p2)  @ 0x8404   4 chars ("HTCU" = unlocked, 00000000 = locked)
#
# Two commands touch partitions that are not part of that layout:
#
#   nowarn hboot      (p26)  six NUL terminated lines, located at run time
#   splash    sp1        (p12)  little-endian RGB565, 1080x1920 unless --size=WxH
#
# Both need S-OFF; nowarn rewrites hboot, which is the only way to brick
# this device.  It always dumps the whole hboot partition first.
#
# Licensed GPL-2.0.
set -u

VERSION=1.0
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=
BACKUP_DIR=${BACKUP_DIR:-$ROOT/backup}
STOOL_TMP=$ROOT/.stool.tmp

# Where each parameter lives is a property of the partition layout, so it is not
# hard-coded here: targets.conf holds one section per layout and the values below
# are filled in by load_target() once the sizes match.  They stay empty until
# then, which is deliberate - a command that reached a read with no target would
# dd from an empty partition name and fail loudly instead of writing at the M8
# offsets on a phone that is not an M8.
TARGET= LAYOUT_MAP= OBSERVED_LAYOUT=
PART_CID= PART_MID= PART_VER= PART_TAMPER= PART_SECURE= PART_BLMAGIC=
PART_HBOOT= PART_SPLASH=
OFF_CID= OFF_MID= OFF_VER= OFF_TAMPER= OFF_SECURE= OFF_BLMAGIC= OFF_SPLASH=
LEN_CID= LEN_MID= LEN_VER= LEN_TAMPER= LEN_SECURE= LEN_BLMAGIC=
HB_BYTES=0 SCREEN=1080x1920 DUMP= FV=

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
	# stdin from /dev/null: adb shell forwards its own stdin to the device, so a
	# call inside a `while read` loop eats the rest of the loop's input.
	if [ "$DEV_SU" = 1 ]; then
		"$ADB" shell "su -c '$1'" </dev/null
	else
		"$ADB" shell "$1" </dev/null
	fi
}

# ---------------------------------------------------------------- targets

CONF=${CONF:-$ROOT/targets.conf}

conf_dump() { # every line as section|key|value; comments and blanks dropped
	# No die here: the caller runs this inside $( ), where an exit only ends the
	# subshell.  target_find checks the file exists first.
	[ -f "$CONF" ] || return 1
	awk '
	{ sub(/\r$/, "") }
	/^[ \t]*#/ { next }
	/^[ \t]*$/ { next }
	# trailing comment after a value: a "#" that follows whitespace is never
	# part of a value here, and single-field keys like blpart would otherwise
	# swallow it whole
	{ sub(/[ \t]+#.*$/, "") }
	/^\[/ {
		s = $0
		sub(/^\[[ \t]*/, "", s)
		sub(/[ \t]*\].*$/, "", s)
		next
	}
	{
		i = index($0, "=")
		if (i == 0) next
		k = substr($0, 1, i - 1); gsub(/[ \t]+$/, "", k)
		v = substr($0, i + 1)
		sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
		if (s != "") printf "%s|%s|%s\n", s, k, v
	}
	' "$CONF"
}

conf_get() { # dump section key -> value, empty when absent
	printf '%s\n' "$1" | awk -F'|' -v s="$2" -v k="$3" \
		'$1 == s && $2 == k { print $3; exit }'
}

# Sets FV.  It has to run in the calling shell: a die inside a $( ) only ends
# the subshell, and the caller would carry on with an empty value.
field_req() { # key
	FV=$(conf_get "$DUMP" "$TARGET" "$1")
	[ -n "$FV" ] || die "targets.conf: [$TARGET] is missing '$1'"
	case "$FV" in
	"" | :* | *: | *::*)
		die "targets.conf: [$TARGET] '$1' must be <partition>:<offset>:<length>:<encoding>" ;;
	esac
}

# /sys/class/block/*/uevent carries PARTNAME and size (512-byte sectors) and is
# world-readable, so the layout can be read before root and before $DEV.  Both
# matter: the table decides which partition to look for, so it cannot come from
# detect_dev, and this has to work on a phone whose names we do not know yet.
layout_probe() {
	[ -n "$LAYOUT_MAP" ] && return 0
	LAYOUT_MAP=$("$ADB" shell 'for f in /sys/class/block/*/uevent; do
		n=
		while IFS="=" read -r k v; do [ "$k" = PARTNAME ] && n=$v; done < "$f"
		[ -n "$n" ] && printf "%s %s\n" "$n" "$(cat "${f%/uevent}/size" 2>/dev/null)"
	done' 2>/dev/null | tr -d '\r')
	[ -n "$LAYOUT_MAP" ]
}

part_sectors() { # name -> sectors, "-" when the partition is absent
	printf '%s\n' "$LAYOUT_MAP" | awk -v n="$1" \
		'$1 == n { print $2; f = 1 } END { if (!f) print "-" }'
}

target_apply() { # dump section - fills the PART_/OFF_ variables
	DUMP=$1
	TARGET=$2
	field_req cid
	IFS=: read -r PART_CID OFF_CID LEN_CID _ <<EOF
$FV
EOF
	field_req mid
	IFS=: read -r PART_MID OFF_MID LEN_MID _ <<EOF
$FV
EOF
	field_req version
	IFS=: read -r PART_VER OFF_VER LEN_VER _ <<EOF
$FV
EOF
	field_req tamper
	IFS=: read -r PART_TAMPER OFF_TAMPER LEN_TAMPER _ <<EOF
$FV
EOF
	field_req secure
	IFS=: read -r PART_SECURE OFF_SECURE LEN_SECURE _ <<EOF
$FV
EOF
	field_req blmagic
	IFS=: read -r PART_BLMAGIC OFF_BLMAGIC LEN_BLMAGIC _ <<EOF
$FV
EOF
	field_req blpart
	IFS=: read -r PART_HBOOT _ _ _ <<EOF
$FV
EOF
	field_req splash
	IFS=: read -r PART_SPLASH OFF_SPLASH _ _ <<EOF
$FV
EOF
	SCREEN=$(conf_get "$DUMP" "$TARGET" screen)
	[ -n "$SCREEN" ] || SCREEN=1080x1920
	# hboot image size, so nowarn does not carry 4194304 as a literal
	hs=$(part_sectors "$PART_HBOOT")
	case "$hs" in
	"" | - | *[!0-9]*) HB_BYTES=0 ;;
	*) HB_BYTES=$((hs * 512)) ;;
	esac
}

target_find() { # 0 when a section's layout matches this device; no side effects
	[ -n "$TARGET" ] && return 0
	[ -f "$CONF" ] || die "missing $CONF"
	# 2, not 1: nothing came back from /sys at all, which is not a layout mismatch
	layout_probe || return 2
	dump=$(conf_dump)
	secs=$(printf '%s\n' "$dump" | cut -d'|' -f1 | awk '!seen[$0]++')
	for s in $secs; do
		lay=$(conf_get "$dump" "$s" layout)
		[ -n "$lay" ] || continue
		ok=1
		for pair in $lay; do
			want=${pair##*:}
			got=$(part_sectors "${pair%:*}")
			[ "$got" = "$want" ] || { ok=0; break; }
		done
		[ "$ok" = 1 ] && { target_apply "$dump" "$s"; return 0; }
	done
	# Report the sizes the sections ask about, so the line below can be pasted
	# into targets.conf as-is.
	names=$(printf '%s\n' "$dump" |
		awk -F'|' '$2 == "layout" { n = split($3, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, ":"); print b[1] } }' |
		awk '!seen[$0]++')
	OBSERVED_LAYOUT=
	for n in $names; do
		OBSERVED_LAYOUT="$OBSERVED_LAYOUT $n:$(part_sectors "$n")"
	done
	return 1
}

load_target() {
	target_find
	case $? in
	0) return 0 ;;
	2)
		die "could not read the partition table from the device (no /sys/class/block/*/uevent) - adb hiccup? nothing was written"
		;;
	esac
	die "no section in targets.conf matches this device.
  observed:$OBSERVED_LAYOUT
  add a [name] section holding that layout and the offsets from README section 6.
  Nothing has been written."
}

# The layout being right is a strong hint but not proof: two partitions can have
# the same size and a different internal record.  These two reads are the ones
# whose result is a closed set, so they double as a check of the offsets.
target_check() {
	s=$(p_secure)
	case "$s" in
	0 | 3) ;;
	*) die "secure flag at $PART_SECURE+$OFF_SECURE reads '$s', expected 0 or 3 - these offsets do not fit this device" ;;
	esac
	m=$(hex_at "$PART_BLMAGIC" "$OFF_BLMAGIC" 4)
	case "$m" in
	48544355 | 00000000) ;;
	*) die "BL magic at $PART_BLMAGIC+$OFF_BLMAGIC reads '$m', expected HTCU or 00000000 - these offsets do not fit this device" ;;
	esac
}

in_recovery() { # 0 if adbd is a recovery ramdisk rather than Android
	# Property, not `adb shell test`: on this Android version adb shell exits 0
	# whatever the remote command returns.
	[ -n "$("$ADB" shell 'getprop ro.twrp.version' 2>/dev/null | tr -d '\r')" ]
}

# require_android [mode] - the four modes, from the point of view of writing:
#   (unset)  writes, so S-OFF is required
#   ro       never writes; no target_check either
#   any      works off the on-device table, so targets.conf is not needed
#   s-on     may run while S-ON: soff, son and `set secure 0`
require_android() {
	case "$(device_mode)" in
	android) ;;
	fastboot)
		die "device is sitting in the bootloader - run 'fastboot reboot' first (or use a fastboot path)" ;;
	*)
		die "no device found: check the cable and that adb debugging is on" ;;
	esac
	detect_root || die "adb shell is neither root nor able to run su - install Magisk or use a userdebug build"
	# "any" is for commands that work off the device's own partition table - a
	# whole-partition backup needs no offsets, so it runs on a phone targets.conf
	# has never heard of
	if [ "${1:-}" = any ]; then
		layout_probe ||
			die "could not read the partition table from the device - adb hiccup? nothing was written"
	else
		load_target
	fi
	detect_dev || die "no by-name directory${PART_SECURE:+ holding $PART_SECURE} on this device"
	# Commands that write are gated here, before any dump or write, so an S-ON
	# phone is refused up front instead of after a backup or a refused dd.
	# soff, son and `set secure 0` opt out: they are how S-ON gets turned off.
	case "${1:-}" in
	ro | any) return 0 ;;
	s-on) target_check ;;
	*)
		target_check
		[ "$(secure_state)" = off ] ||
			die "this device is S-ON - the eMMC write protection is still armed.
  Run 'stool.sh soff' first, or 'stool.sh set secure 0' on an old hboot that
  never armed it.  Nothing was written."
		;;
	esac
}

# The by-name directory moved between SoCs and Android releases:
#   m8    /dev/block/bootdevice/by-name
#   pme   /dev/block/platform/soc/7464900.sdhci/by-name
# probe for a directory that actually contains pg1fs instead of assuming.
dev_has() { # dir -> 0 when it is a usable by-name directory
	if [ -n "${PART_SECURE:-}" ]; then
		devsh "test -e $1/$PART_SECURE && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok
	else
		# no targets.conf: nothing in particular to look for, so any directory
		# works and the caller names the partition it wants
		devsh "test -d $1 && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok
	fi
}

detect_dev() {
	[ -n "$DEV" ] && return 0
	for c in /dev/block/bootdevice/by-name /dev/block/by-name; do
		if dev_has "$c"; then
			DEV=$c
			return 0
		fi
	done
	for c in $(devsh "ls -d /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name 2>/dev/null" |
		tr -d '\r'); do
		if dev_has "$c"; then
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
	[ -n "$DEV" ] || detect_dev || die "no by-name directory on this device"
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
	part=$1; off=$(( $2 )); hx=$3
	[ -n "$part" ] || die "write_hex: no partition given"
	[ -n "$DEV" ] || detect_dev || die "no by-name directory on this device"
	n=$(( ${#hx} / 2 ))
	"$PY" - "$hx" > "$STOOL_TMP" <<'EOF'
import sys, binascii
sys.stdout.buffer.write(binascii.unhexlify(sys.argv[1]))
EOF
	"$ADB" push "$STOOL_TMP" //data/local/tmp/stool.bin >/dev/null 2>&1 </dev/null || die "adb push failed"
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
	[ -n "$DEV" ] || detect_dev || die "no by-name directory on this device"
	# The double slash is for Git Bash: a single leading /data/... gets
	# rewritten into a Windows path before adb ever sees it.
	devsh "dd if=$DEV/$1 of=/data/local/tmp/stool_$1.img bs=4096" >/dev/null 2>&1
	devsh "chmod 644 /data/local/tmp/stool_$1.img" >/dev/null 2>&1
	"$ADB" pull "//data/local/tmp/stool_$1.img" "$2" >/dev/null 2>&1 </dev/null
	devsh "rm -f /data/local/tmp/stool_$1.img" >/dev/null 2>&1
	[ -s "$2" ]
}

# ---------------------------------------------------------------- parameters

p_cid()     { hex2str   "$(hex_at "$PART_CID"    "$OFF_CID"    "$LEN_CID")"; }
p_mid()     { hex2utf16 "$(hex_at "$PART_MID"    "$OFF_MID"    "$LEN_MID")"; }
p_version() { hex2str   "$(hex_at "$PART_VER"    "$OFF_VER"    "$LEN_VER")"; }
p_tamper()  { le32      "$(hex_at "$PART_TAMPER" "$OFF_TAMPER" "$LEN_TAMPER")"; }
p_status()  { # what hboot prints after "Software status:", from that byte
	case "$(p_tamper)" in
	0) printf Official ;;
	*) printf Modified ;;
	esac; }
p_secure()  { le32      "$(hex_at "$PART_SECURE" "$OFF_SECURE" "$LEN_SECURE")"; }
p_bl()      { h=$(hex_at "$PART_BLMAGIC" "$OFF_BLMAGIC" "$LEN_BLMAGIC")
	case "$h" in 48544355) printf "HTCU";;
	             00000000) printf "00000000";;
	             *) printf "%s" "$h";; esac; }

check_param() { # param value - dies on a value that could never be written
	# Runs before require_android and before the snapshot, so a typo costs
	# nothing.  The one thing it cannot check is the write protection, which
	# needs the device.
	case "$1" in
	cid)
		[ ${#2} -eq 8 ] || die "CID must be exactly 8 characters (got '$2')"
		;;
	mid)
		[ ${#2} -eq 9 ] || die "MID must be exactly 9 characters (got '$2')"
		;;
	version)
		[ -n "$2" ] || die "version must not be empty"
		[ ${#2} -le 15 ] || die "version too long (max 15 chars)"
		;;
	tamper)
		case "$2" in
		'' | *[!0-9]*) die "tamper takes a decimal number (0-255)" ;;
		esac
		[ "$2" -le 255 ] || die "tamper out of range"
		;;
	secure)
		case "$2" in 0 | 3) ;; *) die "secure takes 0 (S-OFF) or 3 (S-ON)" ;; esac
		;;
	esac
}

secure_state() { # "off" | "on"
	[ "$(p_secure)" = 0 ] && printf off || printf on
}

bl_state() { # "unlocked" | "locked"
	case "$(hex_at "$PART_BLMAGIC" "$OFF_BLMAGIC" 4)" in
	48544355) printf unlocked ;;
	*) printf locked ;;
	esac
}

# kernel.modules_disabled is the inverse of what the reader wants to know: 1
# means insmod is refused for the rest of this boot, which is why soff cannot
# run.  Report the capability, not the raw flag.
modules_state() { # "enabled" | "disabled"
	case "$(devsh "cat /proc/sys/kernel/modules_disabled 2>/dev/null" | tr -d '\r')" in
	0) printf enabled ;;
	1) printf disabled ;;
	*) printf unknown ;;
	esac
}

print_state() {
	case "$(device_mode)" in
	android)
		if ! detect_root; then
			say "target: unknown"
			say "Secure state: unknown (no root - TWRP, adb root or Magisk su needed)"
			return 0
		fi
		if ! target_find; then
			say "target: unknown - no targets.conf section matches"
			say "  observed:$OBSERVED_LAYOUT"
			return 0
		fi
		if ! detect_dev; then
			say "target: $TARGET (layout ok) but no by-name directory holds $PART_SECURE"
			return 0
		fi
		say "target: $TARGET"
		sn=$(device_serial)
		[ -n "$sn" ] || sn=unknown
		say "serial: $sn"
		# The build hboot reports about itself; getvar answers with the same
		# string, so both modes print one line in the same place.
		hb=$("$ADB" shell getprop ro.boot.bootloader 2>/dev/null | tr -d '\r')
		[ -n "$hb" ] || hb=unknown
		say "hboot: $hb"
		case "$(secure_state)" in
		off) say "Secure state: OFF" ;;
		*)   say "Secure state: ON" ;;
		esac
		say "BL state: $(bl_state)"
		# The bootloader prints this line from the tamper byte: 0 is Official,
		# anything else is Modified.  Reading the same byte keeps the two in step.
		say "Software status: $(p_status)"
		# Last two are the prerequisites soff checks: modules_disabled must be 0
		# for insmod, and SELinux only warns.  Printed as the state they mean,
		# not as the raw sysctl value.
		say "modules: $(modules_state)"
		se=$("$ADB" shell getenforce 2>/dev/null | tr -d '\r')
		[ -n "$se" ] || se=unknown
		say "selinux: $se"
		;;
	fastboot)
		sn=$("$FB" getvar serialno 2>&1 | sed -n 's/.*serialno: //p' | tr -d '\r')
		[ -n "$sn" ] || sn=unknown
		say "serial: $sn"
		hb=$("$FB" getvar version-bootloader 2>&1 | sed -n 's/.*version-bootloader: //p' | tr -d '\r')
		[ -n "$hb" ] || hb=unknown
		say "hboot: $hb"
		sf=$("$FB" oem readsecureflag 2>&1 | sed -n 's/.*secure_flag: //p' | tr -d '\r')
		case "$sf" in
		0) say "Secure state: OFF" ;;
		"") say "Secure state: unknown (could not read secure_flag)" ;;
		*) say "Secure state: ON" ;;
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

device_serial() { # serial number, used to keep two phones' backups apart
	_s=$(devsh "getprop ro.serialno 2>/dev/null" | tr -d '\r')
	[ -n "$_s" ] || _s=$(devsh "getprop ro.boot.serialno 2>/dev/null" | tr -d '\r')
	printf '%s' "$_s" | tr -cd 'A-Za-z0-9'
}

device_tag() { # filename-safe identity, never empty
	_t=$(device_serial)
	printf '%s' "${_t:-noserial}"
}

# The txt is the status output plus the commands that put the images back, so
# it needs no second format to keep in sync: whatever `status` reports is what
# the file records.  Called after the dump, with the images that actually
# landed, so no listed restore command can point at a missing file.
snapshot_write() { # target file tag [saved-image ...]
	f=$1
	tag=$2
	shift 2
	{
		printf '# S-OFF-My-One-M8 backup  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '# serial %s\n' "$tag"
		printf '#\n'
		status_show
		printf '\n'
		printf '== restore ==\n'
		if [ $# -eq 0 ]; then
			printf '  no image from this run landed - nothing to restore\n'
		else
			printf '  stool.sh restore <partition> <file>   (bare filename = look in backup/)\n'
			for one in "$@"; do
				nm=${one##*/}
				pn=${nm%.img}
				pn=${pn##*.}
				printf '  stool.sh restore %-11s %s\n' "$pn" "$nm"
			done
		fi
	} > "$f"
}

refuse_fs_part() { # name - Android's filesystems are not firmware to dump or write
	case "$1" in
	system | cache | userdata)
		die "$1 is an Android filesystem partition - this tool only backs up and restores firmware partitions"
		;;
	esac
}

target_parts() { # partitions a backup covers, deduped (pg1fs carries two fields)
	printf '%s\n' "$PART_SECURE" "$PART_CID" "$PART_MID" "$PART_TAMPER" "$PART_VER" |
		awk 'NF && !seen[$0]++'
}

dump_one() { # part dest-file -> one line on stderr, fails when the dump did not land
	want=$(devsh "blockdev --getsize64 $DEV/$1 2>/dev/null" | tr -d '\r')
	dump_part "$1" "$2" || return 1
	got=$(wc -c < "$2" | tr -d ' ')
	printf '  %-11s %10s bytes\n' "$1" "$got" >&2
	if [ -n "${want:-}" ] && [ "$want" != "$got" ]; then
		warn "$1: expected $want bytes, got $got"
	fi
}

cmd_backup() { # [partition] - every partition plus the txt, or just the one
	[ $# -le 1 ] || die "usage: stool.sh backup [partition]"
	# one partition needs no targets.conf - the name and the size both come from
	# the device - so it also runs on a phone whose layout has no section yet
	if [ -n "${1:-}" ]; then
		refuse_fs_part "$1"
		require_android any
	else
		require_android ro
	fi
	mkdir -p "$BACKUP_DIR"
	tag=$(device_tag)
	[ "$tag" != noserial ] ||
		warn "serial number not readable - the filename cannot tell phones apart"
	ts=$(date +%Y%m%d-%H%M%S)

	# one partition: a single image, no txt - this is also what nowarn and
	# splash call before they overwrite theirs
	if [ -n "${1:-}" ]; then
		b=$(part_bytes "$1")
		[ -n "$b" ] || die "no partition named $1 on this device"
		img=$BACKUP_DIR/$tag-$ts.$1.img
		dump_one "$1" "$img" || die "could not dump $1"
		printf '%s\n' "$img"
		return 0
	fi

	f=$BACKUP_DIR/$tag-$ts.txt

	# Whole images of every partition this tool writes: the one carrying the
	# secure flag is the largest (pg1fs, ~119 MB on the M8), the tamper flag has
	# its own.  Radio is never written here, so it is not dumped.  The names come
	# from targets.conf; pg1fs appears twice there (flag and BL magic), so dedupe.
	# The txt is written afterwards and lists only what landed, so it never
	# carries a restore command for a file the dump failed to produce.
	set --
	for part in $(target_parts); do
		img=$BACKUP_DIR/$tag-$ts.$part.img
		if dump_one "$part" "$img"; then
			set -- "$@" "$img"
		else
			rm -f "$img"
			warn "could not dump $part"
		fi
	done

	snapshot_write "$f" "$tag" "$@"
	[ -s "$f" ] || die "backup failed"

	printf '%s\n' "$f"
}

# ---------------------------------------------------------------- status

# status_show prints everything `status` prints and nothing else.  The backup
# txt is written from this same function, so the file and the screen can never
# drift apart: one source, two destinations.
status_show() {
	say "== state =="
	print_state
	mode=$(device_mode)
	if [ "$mode" = fastboot ]; then
		# Only the three hboot can answer for.  BLmagic and secure are
		# readable here too, but they are storage offsets, and this mode has no
		# partition-table match, so the block stays to the getvar values.
		say "== parameters =="
		printf '%-11s %s\n' CID     "$("$FB" getvar cidnum 2>&1 | sed -n 's/.*cidnum: //p' | tr -d '\r')"
		printf '%-11s %s\n' MID     "$("$FB" getvar modelid 2>&1 | sed -n 's/.*modelid: //p' | tr -d '\r')"
		printf '%-11s %s\n' version "$("$FB" getvar version-main 2>&1 | sed -n 's/.*version-main: //p' | tr -d '\r')"
		return 0
	fi
	# print_state already explained why it could not read anything
	detect_root && detect_dev || return 0
	require_android ro
	say "== parameters =="
	printf '%-11s %-11s %s @ 0x%x\n' CID      "$(p_cid)"     "$PART_CID"     "$((OFF_CID))"
	printf '%-11s %-11s %s @ 0x%x\n' MID      "$(p_mid)"     "$PART_MID"     "$((OFF_MID))"
	printf '%-11s %-11s %s @ 0x%x\n' version  "$(p_version)" "$PART_VER"     "$((OFF_VER))"
	printf '%-11s %-11s %s @ 0x%x\n' BLmagic "$(p_bl)"      "$PART_BLMAGIC" "$((OFF_BLMAGIC))"
	printf '%-11s %-11s %s @ 0x%x\n' secure  "$(p_secure)"   "$PART_SECURE"  "$((OFF_SECURE))"
	printf '%-11s %-11s %s @ 0x%x\n' tamper   "$(p_tamper)"  "$PART_TAMPER"  "$((OFF_TAMPER))"
}

cmd_status() {
	status_show
}

# ---------------------------------------------------------------- set

cmd_set() {
	param=${1:-}; val=${2:-}
	[ -n "$param" ] || die "usage: stool.sh set <cid|mid|version|tamper|secure> [value]"

	case "$param" in
	cid|mid|version|tamper)
		check_param "$param" "$val"
		require_android
		;;
	secure)
		check_param "$param" "$val"
		# 0 is the old-hboot escape hatch: allowed while S-ON, wp_probe decides
		if [ "$val" = 0 ]; then require_android s-on; else require_android; fi
		;;
	*)
		die "unknown parameter: $param"
		;;
	esac

	say "== state before =="
	print_state
	say ""

	case "$param" in
	cid)
		hx=$(str2hex "$val")
		say "CID: $(p_cid) -> $val"
		write_hex "$PART_CID" "$OFF_CID" "$hx"
		verify_hex "$PART_CID" "$OFF_CID" "$hx"
		say "now: $(p_cid)"
		;;
	mid)
		hx=$(utf2hex "$val" | sed 's/\(..\)/\1/g')
		hx=$("$PY" -c 'import sys;h=sys.argv[1];print((h+"00"*16)[:36])' "$hx")
		say "MID: $(p_mid) -> $val"
		write_hex "$PART_MID" "$OFF_MID" "$hx"
		verify_hex "$PART_MID" "$OFF_MID" "$hx"
		say "ok"
		;;
	version)
		hx=$(str2hex "$val")
		hx=$("$PY" -c 'import sys;h=sys.argv[1];print((h+"00"*16)[:32])' "$hx")
		say "version: $(p_version) -> $val"
		write_hex "$PART_VER" "$OFF_VER" "$hx"
		verify_hex "$PART_VER" "$OFF_VER" "$hx"
		say "ok"
		;;
	tamper)
		hx=$(u32hex "$val")
		say "tamper: $(p_tamper) -> $val"
		write_hex "$PART_TAMPER" "$OFF_TAMPER" "$hx"
		verify_hex "$PART_TAMPER" "$OFF_TAMPER" "$hx"
		say "ok"
		;;
	secure)
		if [ "$val" = 0 ] && [ "$(secure_state)" != off ]; then
			# Not fatal by itself: an old hboot may never have armed the
			# protection, and then a plain write works (Porting, case A).
			wp_probe ||
				die "writing 0 while S-ON needs the write protection cleared - run 'stool.sh soff'"
		fi
		hx=$(u32hex "$val")
		say "secure: $(p_secure) -> $val"
		write_hex "$PART_SECURE" "$OFF_SECURE" "$hx"
		verify_hex "$PART_SECURE" "$OFF_SECURE" "$hx"
		say "ok"
		;;
	esac
}

# ---------------------------------------------------------------- BL lock

cmd_bl() { # locked | unlocked
	want=$1
	# 0x8404 sits in the same eMMC write-protected range as the S flag, so the
	# S-OFF gate inside require_android covers it.
	require_android
	say "== state before =="
	print_state
	say ""

	if [ "$want" = locked ]; then
		hx=00000000
	else
		hx=48544355
	fi
	say ""
	say "BL lock: $(bl_state) -> $want   ($PART_BLMAGIC 0x$(printf '%x' "$((OFF_BLMAGIC))") = $hx)"
	write_hex "$PART_BLMAGIC" "$OFF_BLMAGIC" "$hx"
	verify_hex "$PART_BLMAGIC" "$OFF_BLMAGIC" "$hx"
	say "ok - reboot to the bootloader to see it"
}

# ---------------------------------------------------------------- soff / son

push_dev() { # src name - place a file in /dev, which survives the power cycle
	# adb push cannot write /dev (devtmpfs, adbd runs as shell), so it goes to
	# /data/local/tmp first and root copies it across while the eMMC is still up
	"$ADB" push "$1" "//data/local/tmp/$2" >/dev/null 2>&1 </dev/null ||
		die "adb push failed: $1"
	[ "$(devsh "cp /data/local/tmp/$2 /dev/$2 && chmod 755 /dev/$2 && rm -f /data/local/tmp/$2 && echo ok" |
		tr -d '\r')" = ok ] ||
		die "could not put $2 in /dev - adb shell must be able to run commands as root"
}

push_module() { # diag|off|on
	src=$ROOT/kmod/pwrsq_$1.ko
	[ -f "$src" ] || die "missing $src - build first (scripts/build.sh)"
	push_dev "$src" "pwrsq_$1.ko"
}

wp_probe() { # 0 when the eMMC reports no write protection at all
	bin=$ROOT/tools/mmc_cmd
	[ -f "$bin" ] ||
		die "missing $bin - build first (make -C tools CROSS=arm-none-linux-gnueabihf-)"
	push_dev "$bin" mmc_cmd
	out=$(devsh '/dev/mmc_cmd wp' 2>&1 | tr -d '\r')
	printf '%s\n' "$out" | sed 's/^/  /' >&2
	printf '%s\n' "$out" | grep -q 'no write protection'
}

check_write_protection() {
	wp_probe || die "eMMC write protection is still active - power cycle did not take effect"
}

cmd_soff() {
	require_android s-on
	if in_recovery; then
		die "running in recovery - kmod only loads into the Android kernel; boot Android and retry"
	fi
	say "== state before =="
	print_state
	[ "$(secure_state)" = off ] && { say ""; say "already S-OFF, nothing to do"; return 0; }

	[ "$(devsh "cat /proc/sys/kernel/modules_disabled 2>/dev/null" | tr -d '\r')" = 0 ] ||
		die "module loading is disabled on this kernel"
	[ "$("$ADB" shell getenforce 2>/dev/null | tr -d '\r')" = Permissive ] ||
		warn "SELinux is not permissive - loading the module may be denied"
	# Failed here rather than after the power cycle: without mmc_cmd there is no
	# way to tell whether the cut cleared the write protection.
	# It is an ARM binary: the host never runs it, adb pushes it and push_dev
	# chmods it on the phone, so "exists" is the whole test.
	[ -f "$ROOT/tools/mmc_cmd" ] ||
		die "missing tools/mmc_cmd - build first (make -C tools CROSS=arm-none-linux-gnueabihf-)"

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
	# Two insmods, not one: the rail has to stay down long enough for the card
	# to drop its latched power-on protection, and how long that takes is a
	# property of the eMMC.  PWRSQ_OFF_SEC overrides the default.
	"$ADB" shell 'insmod /dev/pwrsq_off.ko; echo OFF_DONE' | tr -d '\r'
	sleep "${PWRSQ_OFF_SEC:-8}"
	"$ADB" shell 'insmod /dev/pwrsq_on.ko; echo ON_DONE' | tr -d '\r'

	# The rescan runs on a workqueue, and a rail that stayed down for several
	# seconds comes back slowly: the host first reports runtime_error -110 and
	# the block nodes appear a minute or two later.  Poll for ~2.5 minutes
	# instead of trusting one fixed delay.  adb shell always exits 0 on this
	# Android version, so ask for output.
	# Ask for the secure partition by name: its p-number is not portable, and on
	# another model it is not p2.
	n=0
	while [ "$n" -lt "${PWRSQ_WAIT_TRIES:-120}" ]; do
		[ "$(devsh "test -b $DEV/$PART_SECURE && echo present")" = present ] && break
		sleep 1
		n=$((n + 1))
	done
	[ "$(devsh "test -b $DEV/$PART_SECURE && echo present")" = present ] ||
		die "eMMC did not come back within ~2 min - it is still recovering.
  Wait until $PART_SECURE appears, then 'adb reboot': framework is stopped
  and nothing has been written to the secure flag."

	say ""
	say "== write protection =="
	check_write_protection

	say ""
	say "== write secure flag =="
	write_hex "$PART_SECURE" "$OFF_SECURE" "$(u32hex 0)"
	verify_hex "$PART_SECURE" "$OFF_SECURE" 00000000
	say "$PART_SECURE 0x$(printf '%x' "$((OFF_SECURE))") = 0"

	say ""
	say "== verify from bootloader =="
	"$ADB" reboot bootloader
	wait_fastboot
	sf=$("$FB" oem readsecureflag 2>&1 | sed -n 's/.*secure_flag: //p' | tr -d '\r')
	sec=$("$FB" getvar security 2>&1 | sed -n 's/.*security: //p' | tr -d '\r' |
		tr 'A-Z' 'a-z')
	say "secure_flag: $sf   security: $sec"
	[ "$sf" = 0 ] || die "secure_flag is $sf, expected 0"
	case $sec in
	off) ;;
	"") warn "could not read 'getvar security' - relying on secure_flag" ;;
	*) die "security is $sec, expected off - hboot still reports S-ON" ;;
	esac
	"$FB" reboot
	wait_android
	say ""
	say "done - S-OFF"
}

cmd_son() {
	require_android s-on
	say "== state before =="
	print_state
	[ "$(secure_state)" = on ] && { say ""; say "already S-ON, nothing to do"; return 0; }

	# A nowarn-patched hboot only boots while S-OFF: SBL skips the signature
	# check now, but once this flag is 3 it verifies again, fails, and stops
	# before hboot runs - no fastboot, no RUU, only EDL.  Refuse before writing.
	hb=$(cmd_backup "$PART_HBOOT")
	"$PY" "$(winpath "$ROOT/scripts/find_redtext.py")" < "$hb" >/dev/null 2>&1 || {
		rm -f "$hb"
		die "hboot no longer carries the six banner strings - it was patched (nowarn).
  S-ON would make SBL reject it and the phone would never reach fastboot.
  Restore the dump nowarn saved first: stool.sh restore hboot <stamp>.hboot.img"
	}
	rm -f "$hb"

	say ""
	say "== write secure flag =="
	write_hex "$PART_SECURE" "$OFF_SECURE" "$(u32hex 3)"
	verify_hex "$PART_SECURE" "$OFF_SECURE" 03000000
	say "$PART_SECURE 0x$(printf '%x' "$((OFF_SECURE))") = 3"

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

part_bytes() { # name -> size in bytes; fails when the partition is absent
	pb_sectors=$(part_sectors "$1")
	case "$pb_sectors" in
	"" | - | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$(( pb_sectors * 512 ))"
}

cmd_restore() { # <partition> <file.img> - write one saved partition image back
	part=${1:-}
	img=${2:-}
	if [ -z "$part" ] || [ -z "$img" ]; then
		say "usage: stool.sh restore <partition> <file.img>"
		say "  e.g. restore pg2fs HT495WM00193-20261104-045201.pg2fs.img"
		say ""
		files=$(ls -1 "$BACKUP_DIR"/*.img 2>/dev/null)
		if [ -n "$files" ]; then
			say "in $BACKUP_DIR:"
			printf '%s\n' "$files" | sed 's#.*/##; s/^/  /'
		else
			say "no .img in $BACKUP_DIR - run 'stool.sh backup' first"
		fi
		exit 2
	fi
	# a bare filename is looked up in backup/; anything with a slash is a path
	case "$img" in
	*/*) ;;
	*) img=$BACKUP_DIR/$img ;;
	esac
	refuse_fs_part "$part"
	[ -f "$img" ] || die "no such file: $img"

	name=${img##*/}
	fsize=$(wc -c < "$img" | tr -d ' ')

	# no targets.conf: the name and the size come from the device, and a write the
	# card refuses shows up in the read-back below
	require_android any

	# The partition is named, never inferred: an image is one whole partition, so
	# its length has to be that partition's length, and nothing else is checked.
	b=$(part_bytes "$part")
	[ -n "$b" ] || die "no partition named $part on this device"
	[ "$b" = "$fsize" ] ||
		die "$part is $b bytes and $name is $fsize - refusing a mismatched image"

	# by-name is how the device node is found; a partition that only exists on an
	# inserted SD card has no entry here
	[ "$(devsh "test -e $DEV/$part && echo ok" | tr -d '\r')" = ok ] ||
		die "$part is not a partition of this phone's eMMC"

	tag=$(device_tag)
	base=${name%.img}
	pfx=${base%%-*}
	case "$pfx" in
	'' | *[!A-Za-z0-9]*) img_tag= ;;
	[A-Za-z][A-Za-z]*) img_tag=$pfx ;;
	*) img_tag= ;;
	esac
	[ -z "$img_tag" ] || [ "$img_tag" = "$tag" ] ||
		die "$name was taken from $img_tag; this phone is $tag - refusing to write another phone's image"
	[ -n "$img_tag" ] ||
		say "note: filename has no serial - cannot verify which phone it came from"

	say "== $part =="
	printf '  %s  %s bytes  %s\n' "$part" "$fsize" "$name"
	flash_part "$part" "$img"

	# the image is the truth here: read the partition back and compare
	a=$("$PY" -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$(winpath "$img")")
	b=$(devsh "md5sum $DEV/$part 2>/dev/null" | tr -d '\r' | awk '{print $1}')
	[ "$a" = "$b" ] ||
		die "$part read-back mismatch: wrote $a, read $b
  dd reports success either way.  If dmesg shows 'card status 0x400d00' the card
  refused the write, which is what an S-ON phone does to the partitions its
  bootloader protects; S-OFF stops arming that."
	say "  md5 $a  ok"

	case "$part" in
	"${PART_HBOOT:-hboot}" | "${PART_SPLASH:-sp1}")
		say ""
		say "reboot to see it"
		;;
	esac
}


# ---------------------------------------------------------------- hboot / splash

winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

flash_part() { # part src-file  (write a whole image; used by restore)
	[ -n "$DEV" ] || detect_dev || die "no by-name directory on this device"
	say "  writing $(wc -c < "$2" | tr -d ' ') bytes to $1"
	"$ADB" push "$2" //data/local/tmp/stool_flash.img >/dev/null 2>&1 </dev/null || die "adb push failed"
	# sed runs here, not on the device: devsh forbids single quotes inside $1
	devsh "dd if=/data/local/tmp/stool_flash.img of=$DEV/$1 bs=4096 2>&1 | tail -n 2" 2>&1 |
		sed 's/^/  /' >&2
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_flash.img" >/dev/null 2>&1
}

cmd_nowarn() {
	# it used to take --restore; without this guard that word would fall through
	# to the normal path and patch hboot
	[ $# -eq 0 ] ||
		die "nowarn takes no arguments.  To put a saved hboot back: stool.sh restore hboot <stamp>.hboot.img"

	require_android
	say "== state before =="
	print_state
	say ""

	say "== dump =="
	hb=$(cmd_backup "$PART_HBOOT")
	sz=$(wc -c < "$hb" | tr -d ' ')
	say "saved  : $hb"
	[ "$sz" = "$HB_BYTES" ] || die "$PART_HBOOT dump is $sz bytes, expected $HB_BYTES - aborting"

	say ""
	say "== locate =="
	offs=$(cat "$hb" | "$PY" "$(winpath "$ROOT/scripts/find_redtext.py")") ||
		die "the six red-text lines were not found in this hboot"

	for o in $offs; do
		b=$(hex_at "$PART_HBOOT" "$o" 1)
		say "  0x$(printf '%06x' "$o")  first byte = $b"
	done

	say ""
	say "== patch =="
	printf '\000' > "$STOOL_TMP.zero"
	printf '#!/system/bin/sh\n' > "$STOOL_TMP.nr.sh"
	for o in $offs; do
		printf 'dd if=/data/local/tmp/stool_zero.bin of=%s/%s bs=1 seek=%s count=1 || exit 1\n' \
			"$DEV" "$PART_HBOOT" "$o" >> "$STOOL_TMP.nr.sh"
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
		verify_hex "$PART_HBOOT" "$o" 00
		say "  0x$(printf '%06x' "$o")  ok"
	done

	say ""
	say "six bytes blanked.  Reboot and look at the first screen."
	say "undo   : stool.sh restore $PART_HBOOT $hb"
}

cmd_splash() {
	img=${1:-}
	[ -n "$img" ] || die "usage: stool.sh splash <image.png> [--size=WxH] [--fit=cover|stretch]"
	[ "$img" != --restore ] ||
		die "splash --restore is gone.  To put a saved sp1 back: stool.sh restore sp1 <stamp>.sp1.img"
	[ -f "$img" ] || die "no such file: $img"
	require_android
	shift
	# --size is ours; everything else goes to the converter.  The default comes
	# from targets.conf, so a 1440x2560 panel does not need --size every time.
	size=$SCREEN
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

	say "== convert =="
	raw=$STOOL_TMP.splash
	"$PY" "$(winpath "$ROOT/scripts/png2rgb565.py")" "$(winpath "$img")" "$(winpath "$raw")" \
		--width="$w" --height="$h" $fitarg ||
		die "conversion failed - PNG only, see the message above"
	sz=$(wc -c < "$raw" | tr -d ' ')
	say "raw    : $sz bytes"
	[ "$sz" = "$exp" ] || die "converted image is $sz bytes, expected $exp"
	# check before dumping 10 MB of partition that we cannot use anyway
	psz=$(devsh "blockdev --getsize64 $DEV/$PART_SPLASH 2>/dev/null" | tr -d '\r')
	if [ -n "$psz" ] && [ "$exp" -gt "$psz" ]; then
		die "a ${w}x${h} frame is $exp bytes but $PART_SPLASH is only $psz bytes"
	fi

	say ""
	say "== dump =="
	sp=$(cmd_backup "$PART_SPLASH")
	say "saved  : $sp"

	say ""
	say "== write =="
	"$ADB" push "$raw" //data/local/tmp/stool_splash.raw >/dev/null 2>&1 || die "adb push failed"
	devsh "dd if=/data/local/tmp/stool_splash.raw of=$DEV/$PART_SPLASH bs=4096 2>&1 | tail -2" >&2
	devsh "sync; echo 3 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_splash.raw" >/dev/null 2>&1

	say ""
	say "== verify =="
	cnt=$(( (exp + 4095) / 4096 ))
	devsh "dd if=$DEV/$PART_SPLASH of=/data/local/tmp/stool_chk.img bs=4096 count=$cnt" >/dev/null 2>&1
	devsh "chmod 644 /data/local/tmp/stool_chk.img" >/dev/null 2>&1
	"$ADB" pull "//data/local/tmp/stool_chk.img" "$STOOL_TMP.chk" >/dev/null 2>&1
	devsh "rm -f /data/local/tmp/stool_chk.img" >/dev/null 2>&1
	[ -s "$STOOL_TMP.chk" ] || die "could not read $PART_SPLASH back"

	a=$("$PY" -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read(int(sys.argv[2]))).hexdigest())" "$(winpath "$raw")" "$exp")
	b=$("$PY" -c "import hashlib,sys;print(hashlib.md5(open(sys.argv[1],'rb').read(int(sys.argv[2]))).hexdigest())" "$(winpath "$STOOL_TMP.chk")" "$exp")
	rm -f "$STOOL_TMP.chk" "$raw"
	[ "$a" = "$b" ] || die "read-back mismatch: wrote $a, read $b"
	say "  md5 $a  ok"

	say ""
	say "first screen replaced.  Reboot to see it."
	say "undo   : stool.sh restore $PART_SPLASH $sp"
}

# ---------------------------------------------------------------- main


usage() {
	cat <<EOF
stool.sh $VERSION - HTC One M8 S-OFF control tool

  stool.sh status
  stool.sh soff
  stool.sh son
  stool.sh backup [partition]
  stool.sh restore <partition> <file.img>
                                   write one saved image back
  stool.sh set cid <8 chars>
  stool.sh set mid <9 chars>
  stool.sh set version <x.y.z.w>
  stool.sh set tamper <0-255>
  stool.sh set secure <0|3>
  stool.sh lock                    write the BL magic = locked
  stool.sh unlock                  write the BL magic = unlocked
  stool.sh nowarn                  blank the six "This build is for ..." lines
  stool.sh splash <image.png> [--size=WxH] [--fit=cover|stretch]
                                   replace the first boot screen

Every command starts by reading the current S state, and anything that writes
is refused while S-ON.  Nothing is backed up automatically: run
'stool.sh backup' first if you want a way back.

Every command accepts -h / --help: it prints this text and touches nothing.

Environment: ADB, FB, PY, BACKUP_DIR.
EOF
}

[ $# -ge 1 ] || { usage; exit 2; }
cmd=$1; shift

case "$cmd" in
-h|--help|help) usage; exit 0 ;;
esac

# Every command answers -h/--help with the same usage and touches nothing.
# Without this, `soff --help` would run the power cycle: cmd_soff ignores
# arguments, so the flag would never be seen.
for a in "$@"; do
	case "$a" in
	-h|--help) usage; exit 0 ;;
	esac
done

case "$cmd" in
status)  [ $# -eq 0 ] || die "usage: stool.sh status"
         cmd_status ;;
soff)    [ $# -eq 0 ] || die "usage: stool.sh soff"
         cmd_soff ;;
son)     [ $# -eq 0 ] || die "usage: stool.sh son"
         cmd_son ;;
backup)  cmd_backup "$@" ;;
restore) cmd_restore "$@" ;;
set)     cmd_set "$@" ;;
lock)    [ $# -eq 0 ] || die "usage: stool.sh lock"
         cmd_bl locked ;;
unlock)  [ $# -eq 0 ] || die "usage: stool.sh unlock"
         cmd_bl unlocked ;;
nowarn) cmd_nowarn "$@" ;;
splash)    cmd_splash "$@" ;;
-h|--help|help) usage ;;
*) usage; exit 2 ;;
esac
