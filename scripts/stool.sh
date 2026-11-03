#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# stool.sh - HTC One M8 S-OFF control tool
#
#   stool.sh status                 show S state and every parameter
#   stool.sh soff                   full S-OFF (power cycle + write flag)
#   stool.sh son                    back to S-ON
#   stool.sh backup                 snapshot all parameters to backup/<time>.txt
#   stool.sh restore <timestamp>    write backup/<ts>.*.img back
#   stool.sh lock                  write the BL magic = locked   (S-OFF only)
#   stool.sh unlock                write the BL magic = unlocked (S-OFF only)
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
#   noredtext hboot      (p26)  six NUL terminated lines, located at run time
#   splash    sp1        (p12)  little-endian RGB565, 1080x1920 unless --size=WxH
#
# Both need S-OFF and a full backup; noredtext rewrites hboot, which is the only
# way to brick this device.  It always dumps the whole hboot partition first.
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
TARGET= TARGET_DEVICE= TARGET_HBOOT= LAYOUT_MAP= OBSERVED_LAYOUT=
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
	TARGET_DEVICE=$(conf_get "$DUMP" "$TARGET" device)
	TARGET_HBOOT=$(conf_get "$DUMP" "$TARGET" hboot)
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
	field_req hbootpart
	IFS=: read -r PART_HBOOT _ _ _ <<EOF
$FV
EOF
	field_req splash
	IFS=: read -r PART_SPLASH OFF_SPLASH _ _ <<EOF
$FV
EOF
	SCREEN=$(conf_get "$DUMP" "$TARGET" screen)
	[ -n "$SCREEN" ] || SCREEN=1080x1920
	# hboot image size, so noredtext does not carry 4194304 as a literal
	hs=$(part_sectors "$PART_HBOOT")
	case "$hs" in
	"" | - | *[!0-9]*) HB_BYTES=0 ;;
	*) HB_BYTES=$((hs * 512)) ;;
	esac
}

target_find() { # 0 when a section's layout matches this device; no side effects
	[ -n "$TARGET" ] && return 0
	[ -f "$CONF" ] || die "missing $CONF"
	layout_probe || return 1
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
	target_find && return 0
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

require_android() { # $1 = "ro" for commands that never write: skips target_check
	case "$(device_mode)" in
	android) ;;
	fastboot)
		die "device is sitting in the bootloader - run 'fastboot reboot' first (or use a fastboot path)" ;;
	*)
		die "no device found: check the cable and that adb debugging is on" ;;
	esac
	detect_root || die "adb shell is neither root nor able to run su - install Magisk or use a userdebug build"
	load_target
	detect_dev || die "no by-name directory containing $PART_SECURE (looked in bootdevice, by-name and platform/*)"
	[ "${1:-}" = ro ] || target_check
}

# The by-name directory moved between SoCs and Android releases:
#   m8    /dev/block/bootdevice/by-name
#   pme   /dev/block/platform/soc/7464900.sdhci/by-name
# probe for a directory that actually contains pg1fs instead of assuming.
detect_dev() {
	[ -n "$DEV" ] && return 0
	want=${PART_SECURE:-pg1fs}
	for c in /dev/block/bootdevice/by-name /dev/block/by-name; do
		if devsh "test -e $c/$want && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok; then
			DEV=$c
			return 0
		fi
	done
	for c in $(devsh "ls -d /dev/block/platform/*/by-name /dev/block/platform/*/*/by-name 2>/dev/null" |
		tr -d '\r'); do
		if devsh "test -e $c/$want && echo ok" 2>/dev/null | tr -d '\r' | grep -qx ok; then
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
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing $PART_SECURE"
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
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing $PART_SECURE"
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
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing $PART_SECURE"
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
p_secure()  { le32      "$(hex_at "$PART_SECURE" "$OFF_SECURE" "$LEN_SECURE")"; }
p_bl()      { h=$(hex_at "$PART_BLMAGIC" "$OFF_BLMAGIC" "$LEN_BLMAGIC")
	case "$h" in 48544355) printf "HTCU (unlocked)";;
	             00000000) printf "00000000 (locked)";;
	             *) printf "%s" "$h";; esac; }

raw_line() { # part offset len -> the replayable line `restore` consumes
	printf 'raw:%s:0x%x=%s\n' "$1" "$(( $2 ))" "$(hex_at "$1" "$2" "$3")"
}

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

print_state() {
	case "$(device_mode)" in
	android)
		if ! detect_root; then
			say "S state : unknown (no root - TWRP, adb root or Magisk su needed)"
			return 0
		fi
		if ! target_find; then
			say "target  : unknown - no targets.conf section matches"
			say "  observed:$OBSERVED_LAYOUT"
			return 0
		fi
		if ! detect_dev; then
			say "target  : $TARGET (layout ok) but no by-name directory holds $PART_SECURE"
			return 0
		fi
		say "target  : $TARGET  [$TARGET_DEVICE, hboot $TARGET_HBOOT]"
		st=$(secure_state)
		if [ "$st" = off ]; then say "S state : S-OFF (secure_flag 0)"
		else say "S state : S-ON  (secure_flag $(p_secure))"; fi
		say "BL state: $(bl_state) ($PART_BLMAGIC 0x$(printf '%x' "$((OFF_BLMAGIC))") = $(p_bl))"
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
		printf '# target=%s\n' "$TARGET"
		printf 'state=%s\n' "$(secure_state)"
		printf 'cid=%s\n' "$(p_cid)"
		printf 'mid=%s\n' "$(p_mid)"
		printf 'version=%s\n' "$(p_version)"
		printf 'tamper=%s\n' "$(p_tamper)"
		printf 'secure=%s\n' "$(p_secure)"
		printf 'bl=%s\n'     "$(bl_state)"
		printf '# exact bytes at the six offsets, for reference\n'
		printf '# whole images: %s.*.img, restorable with: stool.sh restore %s\n' \
			"${f##*/}" "$(printf '%s' "${f##*/}" | sed 's/\.txt$//')" 
		raw_line "$PART_CID"     "$OFF_CID"     "$LEN_CID"
		raw_line "$PART_MID"     "$OFF_MID"     "$LEN_MID"
		raw_line "$PART_VER"     "$OFF_VER"     "$LEN_VER"
		raw_line "$PART_TAMPER"  "$OFF_TAMPER"  "$LEN_TAMPER"
		raw_line "$PART_SECURE"  "$OFF_SECURE"  "$LEN_SECURE"
		raw_line "$PART_BLMAGIC" "$OFF_BLMAGIC" "$LEN_BLMAGIC"
	} > "$f"
}

target_parts() { # partitions a backup covers, deduped (pg1fs carries two fields)
	printf '%s\n' "$PART_SECURE" "$PART_CID" "$PART_MID" "$PART_TAMPER" "$PART_VER" |
		awk 'NF && !seen[$0]++'
}

cmd_backup() {
	require_android ro
	mkdir -p "$BACKUP_DIR"
	ts=$(date +%Y%m%d-%H%M%S)
	f=$BACKUP_DIR/$ts.txt
	snapshot_write "$f"
	[ -s "$f" ] || die "backup failed"

	# The txt only holds the bytes this tool writes - six small ranges.  Keep
	# whole images of every partition this tool writes: the one carrying the
	# secure flag is the largest (pg1fs, ~119 MB on the M8), the tamper flag has
	# its own.  Radio is never written here, so it is not dumped.  The names come
	# from targets.conf; pg1fs appears twice there (flag and BL magic), so dedupe.
	for part in $(target_parts); do
		img=$BACKUP_DIR/$ts.$part.img
		want=$(devsh "blockdev --getsize64 $DEV/$part 2>/dev/null" | tr -d '\r')
		if ! dump_part "$part" "$img"; then
			warn "could not dump $part"
			continue
		fi
		got=$(wc -c < "$img" | tr -d ' ')
		printf '  %-11s %10s bytes\n' "$part" "$got" >&2
		if [ -n "${want:-}" ] && [ "$want" != "$got" ]; then
			warn "$part: expected $want bytes, got $got"
		fi
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
	require_android ro
	say ""
	say "== parameters =="
	printf '%-9s %-12s %s @ 0x%x\n' CID      "$(p_cid)"     "$PART_CID"    "$((OFF_CID))"
	printf '%-9s %-12s %s @ 0x%x\n' MID      "$(p_mid)"     "$PART_MID"    "$((OFF_MID))"
	printf '%-9s %-12s %s @ 0x%x\n' version  "$(p_version)" "$PART_VER"    "$((OFF_VER))"
	printf '%-9s %-12s %s @ 0x%x\n' tamper   "$(p_tamper)"  "$PART_TAMPER" "$((OFF_TAMPER))"
	printf '%-9s %-12s %s @ 0x%x\n' secure   "$(p_secure)"  "$PART_SECURE" "$((OFF_SECURE))"
	printf '%-9s %-12s %s @ 0x%x\n' "BL lock" "$(bl_state)" "$PART_BLMAGIC" "$((OFF_BLMAGIC))"
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
		check_param "$param" "$val"
		require_android
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
	require_android
	say "== state before =="
	print_state
	say ""

	# 0x8404 sits in the same eMMC write-protected range as the S flag.
	[ "$(secure_state)" = off ] ||
		die "writing the BL magic needs the eMMC write protection cleared - run 'stool.sh soff'"

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

push_module() { # diag|off|on
	src=$ROOT/kmod/pwrsq_$1.ko
	[ -f "$src" ] || die "missing $src - build first (scripts/build.sh)"
	"$ADB" push "$src" "//dev/pwrsq_$1.ko" >/dev/null || die "adb push failed"
}

wp_probe() { # 0 when the eMMC reports no write protection at all
	bin=$ROOT/tools/mmc_cmd
	[ -x "$bin" ] ||
		die "missing $bin - build first (make -C tools CROSS=arm-none-linux-gnueabihf-)"
	"$ADB" push "$bin" //dev/mmc_cmd >/dev/null 2>&1
	"$ADB" shell 'chmod 755 /dev/mmc_cmd'
	out=$("$ADB" shell '/dev/mmc_cmd wp' 2>&1 | tr -d '\r')
	printf '%s\n' "$out" | sed 's/^/  /' >&2
	printf '%s\n' "$out" | grep -q 'no write protection'
}

check_write_protection() {
	wp_probe || die "eMMC write protection is still active - power cycle did not take effect"
}

cmd_soff() {
	require_android
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
	[ -x "$ROOT/tools/mmc_cmd" ] ||
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
	"$ADB" shell 'insmod /dev/pwrsq_off.ko; insmod /dev/pwrsq_on.ko; echo SEQ_DONE' | tr -d '\r'
	sleep 3

	# adb shell always exits 0 on this Android version, so ask for output.
	[ "$(devsh 'test -b /dev/block/mmcblk0p2 && echo present')" = present ] ||
		die "eMMC did not come back - hold power ~10s, then retry"

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
	require_android
	say "== state before =="
	print_state
	[ "$(secure_state)" = on ] && { say ""; say "already S-ON, nothing to do"; return 0; }

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

cmd_restore() { # <timestamp> - write backup/<ts>.*.img back to the card
	ts=${1:-}
	if [ -z "$ts" ]; then
		say "usage: stool.sh restore <timestamp>    e.g. restore 20261102-222222"
		say ""
		stamps=$(ls -1 "$BACKUP_DIR"/*.img 2>/dev/null |
			sed 's#.*/##; s#\.[^.]*\.img$##' | sort -u)
		if [ -n "$stamps" ]; then
			say "in $BACKUP_DIR:"
			printf '%s\n' "$stamps" | sed 's/^/  /'
		else
			say "no .img files in $BACKUP_DIR - run 'stool.sh backup' first"
		fi
		exit 2
	fi
	base=${ts##*/}
	case "$ts" in
	*.txt)
		die "restore writes whole images now - pass the timestamp: stool.sh restore ${base%.txt}" ;;
	*/*) prefix=$ts ;;
	*) prefix=$BACKUP_DIR/$ts ;;
	esac
	[ -n "$(ls -1 "$prefix".*.img 2>/dev/null)" ] || die "no .img files match $prefix"

	require_android
	[ "$(secure_state)" = off ] ||
		die "restoring whole partitions needs S-OFF - they are write protected while S-ON"

	say "== plan =="
	plan=
	for img in "$prefix".*.img; do
		[ -f "$img" ] || continue
		name=${img##*/}
		part=${name#*.}
		part=${part%.img}
		case "$part" in
		"$PART_SECURE" | "$PART_CID" | "$PART_MID" | "$PART_TAMPER" | "$PART_VER") ;;
		*)
			warn "skip $name - $part is not a partition this tool writes"
			continue
			;;
		esac
		want=$(devsh "blockdev --getsize64 $DEV/$part 2>/dev/null" | tr -d '\r')
		got=$(wc -c < "$img" | tr -d ' ')
		[ -z "$want" ] || [ "$got" = "$want" ] ||
			die "$name is $got bytes but $part is $want - refusing a mismatched image"
		printf '  %-11s %10s bytes  %s\n' "$part" "$got" "$name"
		plan="$plan $part:$img"
	done
	[ -n "$plan" ] || die "nothing to restore from $prefix - no image matches a partition this tool writes"

	for part in $(target_parts); do
		case " $plan " in
		*" $part:"*) ;;
		*) warn "no image for $part - left untouched" ;;
		esac
	done

	say ""
	say "== write =="
	for entry in $plan; do
		part=${entry%%:*}
		img=${entry#*:}
		flash_part "$part" "$img"
		# the image is the truth here: read the partition back and compare
		a=$("$PY" -c 'import hashlib,sys;print(hashlib.md5(open(sys.argv[1],"rb").read()).hexdigest())' "$(winpath "$img")")
		b=$(devsh "md5sum $DEV/$part 2>/dev/null" | tr -d '\r' | awk '{print $1}')
		[ "$a" = "$b" ] || die "$part read-back mismatch: wrote $a, read $b"
		say "  $part  md5 $a  ok"
	done

	say ""
	say "== state after =="
	print_state
	say ""
	say "done"
}

# ---------------------------------------------------------------- hboot / splash

winpath() { cygpath -w "$1" 2>/dev/null || printf '%s' "$1"; }

flash_part() { # part src-file  (write a whole image, used by the --restore paths)
	[ -n "$DEV" ] || detect_dev || die "no by-name directory containing $PART_SECURE"
	say "writing $(wc -c < "$2" | tr -d ' ') bytes to $1"
	"$ADB" push "$2" //data/local/tmp/stool_flash.img >/dev/null 2>&1 </dev/null || die "adb push failed"
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
		[ -n "$HB_BYTES" ] && [ "$HB_BYTES" -gt 0 ] ||
			die "targets.conf does not give a size for $PART_HBOOT"
		[ "$(wc -c < "$src" | tr -d ' ')" = "$HB_BYTES" ] ||
			die "not a $HB_BYTES-byte $PART_HBOOT image: $src"
		flash_part "$PART_HBOOT" "$src"
		say "ok - reboot to see it"
		return 0
	fi

	require_android
	say "== state before =="
	print_state
	say ""
	[ "$(secure_state)" = off ] ||
		die "writing hboot needs S-OFF - the partition is write protected while S-ON"

	say "== dump =="
	mkdir -p "$BACKUP_DIR"
	ts=$(date +%Y%m%d-%H%M%S)
	hb=$BACKUP_DIR/$ts.$PART_HBOOT.img
	dump_part "$PART_HBOOT" "$hb" || die "could not dump the $PART_HBOOT partition"
	sz=$(wc -c < "$hb" | tr -d ' ')
	say "hboot  : $hb ($sz bytes)"
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
	say "undo   : stool.sh noredtext --restore $hb"
}

cmd_splash() {
	if [ "${1:-}" = --restore ]; then
		src=${2:-}
		[ -n "$src" ] && [ -f "$src" ] || die "usage: stool.sh splash --restore <sp1.img>"
		require_android
		[ "$(secure_state)" = off ] || die "writing $PART_SPLASH needs S-OFF"
		flash_part "$PART_SPLASH" "$src"
		say "ok - reboot to see it"
		return 0
	fi

	img=${1:-}
	[ -n "$img" ] || die "usage: stool.sh splash <image.png> [--size=WxH] [--fit=cover|stretch]   or   stool.sh splash --restore <sp1.img>"
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
	mkdir -p "$BACKUP_DIR"
	ts=$(date +%Y%m%d-%H%M%S)
	sp=$BACKUP_DIR/$ts.$PART_SPLASH.img
	dump_part "$PART_SPLASH" "$sp" || die "could not dump the $PART_SPLASH partition"
	say "$PART_SPLASH : $sp ($(wc -c < "$sp" | tr -d ' ') bytes)"

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
  stool.sh lock                    write the BL magic = locked   (S-OFF only)
  stool.sh unlock                  write the BL magic = unlocked (S-OFF only)
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
lock)    [ $# -eq 0 ] || die "usage: stool.sh lock"
         cmd_bl locked ;;
unlock)  [ $# -eq 0 ] || die "usage: stool.sh unlock"
         cmd_bl unlocked ;;
noredtext) cmd_noredtext "$@" ;;
splash)    cmd_splash "$@" ;;
-h|--help|help) usage ;;
*) usage; exit 2 ;;
esac
