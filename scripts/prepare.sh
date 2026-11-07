#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Point a kernel tree at the phone.
#
#   scripts/prepare.sh <kernel-tree> [--force]
#
# Does what the Building section used to spell out as a dozen copy-pasted
# commands: dump boot, pull the compiled-in .config out of it, read the five
# symbols and the module_layout crc into kmod/addr.h, check the vermagic the
# config will produce against a stock module, then configure and prepare the
# tree so scripts/build.sh can use it.
#
# Refuses to continue when:
#   - the phone is in recovery (kallsyms and boot belong to another kernel)
#   - the tree looks like a Windows path (kbuild reads M= as a make target)
#   - oldconfig reports more than 20 new symbols and --force was not given
#
# Requires: adb, root on the device, python3 (or python), make, and a cross
# compiler.  Run it on the phone as it normally boots - if boot was flashed
# after the last boot, the config you get is not the kernel you are reading
# symbols from.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CFG="$ROOT/m8.config"
STOOL="$ROOT/scripts/stool.sh"
ADB=${ADB:-adb}
CROSS=${CROSS:-arm-none-linux-gnueabihf-}
MAKE=${MAKE:-make}
NEW_LIMIT=20

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

# Both oldconfig and modules_prepare compile host tools, so both can hit the
# 2016-tree-versus-modern-toolchain problems on MSYS2.  Same hint either way.
toolchain_hint() {
	case "$(uname -s)" in
	MSYS*|MINGW*|CYGWIN*)
		warn ""
		warn "on MSYS2 this is almost always the toolchain, not the tree:"
		warn "  cd $KDIR && patch -p1 < $ROOT/kernel-patches/0001-fixdep-crlf-and-no-mmap.patch"
		warn "  cp $ROOT/kernel-patches/compiler-gcc13.h include/linux/"
		warn "then run this script again"
		;;
	esac
}

KDIR=
FORCE=0
for a in "$@"; do
	case "$a" in
	--force) FORCE=1 ;;
	-h|--help) usage; exit 0 ;;
	-*) die "unknown option $a" ;;
	*) [ -z "$KDIR" ] || die "one tree at a time"; KDIR=$a ;;
	esac
done
[ -n "$KDIR" ] || { usage; exit 1; }

case "$KDIR" in
[A-Za-z]:*) die "pass a MSYS path (/d/...), not $KDIR
  kbuild reads M= as a make target and the drive-letter colon breaks it" ;;
esac
[ -f "$KDIR/Makefile" ] && [ -d "$KDIR/scripts/kconfig" ] ||
	die "$KDIR is not a kernel tree"

command -v "$ADB" >/dev/null 2>&1 || die "adb not found"
command -v "$MAKE" >/dev/null 2>&1 ||
	die "$MAKE not found - on Windows run this from the MSYS2 shell, not cmd.exe"
command -v "${CROSS}gcc" >/dev/null 2>&1 ||
	die "${CROSS}gcc not found - set CROSS to your toolchain prefix"

PY=
for c in python3 python; do
	if command -v "$c" >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || die "python3 not found"

# Output, not status: adb shell on this Android always returns 0.
[ -z "$($ADB shell 'getprop ro.twrp.version' 2>/dev/null | tr -d '\r')" ] ||
	die "the phone is in recovery - boot Android and run this again
  in recovery /proc/kallsyms belongs to the recovery kernel, and the boot
  partition is not the kernel that is running"

REL=$($ADB shell 'uname -r' | tr -d '\r')
[ -n "$REL" ] || die "could not read uname -r - is the phone connected?"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT

say "== 1/6 boot image =="
IMG=$("$STOOL" backup boot | tr -d '\r' | awk '/\.img$/ { p = $0 } END { print p }')
[ -s "$IMG" ] || die "backup boot did not produce an image"
say "$IMG"

say ""
say "== 2/6 config =="
"$PY" "$ROOT/scripts/extract_config.py" "$IMG" > "$CFG.tmp"
[ -s "$CFG.tmp" ] || die "extracted config is empty"
grep -q '^CONFIG_MODULES=y$' "$CFG.tmp" ||
	die "this kernel has modules disabled - the module cannot be built for it"

# The part of uname -r after the release number becomes CONFIG_LOCALVERSION,
# so the .ko carries the same string the phone reports.  Read, never typed.
case "$REL" in
*-*) SUFFIX="-${REL#*-}" ;;
*)   SUFFIX="" ;;
esac
sed -e "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"$SUFFIX\"|" \
	-e 's|^CONFIG_LOCALVERSION_AUTO=.*|CONFIG_LOCALVERSION_AUTO=n|' \
	"$CFG.tmp" > "$CFG"
rm -f "$CFG.tmp"
grep -q "^CONFIG_LOCALVERSION=\"$SUFFIX\"$" "$CFG" ||
	die "$CFG has no CONFIG_LOCALVERSION line to set"
say "$CFG  $(grep -c '^CONFIG_' "$CFG") symbols, localversion \"$SUFFIX\""

# One pull serves both jobs: addr.h wants a __versions entry out of it, and the
# vermagic check wants the flags out of the same .modinfo.
say ""
say "== 3/6 addr.h =="
# kallsyms prints zeros to anyone but root until this is 0.  Two ways in: the
# phone's own shell is already root on userdebug images, otherwise go through
# su.  Failures are left to gen_addr.sh, which explains them precisely.
if [ "$($ADB shell 'cat /proc/sys/kernel/kptr_restrict' 2>/dev/null | tr -d '\r')" != 0 ]; then
	$ADB shell 'echo 0 > /proc/sys/kernel/kptr_restrict' >/dev/null 2>&1 || true
	$ADB shell 'su -c "echo 0 > /proc/sys/kernel/kptr_restrict"' >/dev/null 2>&1 || true
fi
KO=$TMP/stock.ko
$ADB pull //system/lib/modules/ansi_cprng.ko "$KO" >/dev/null 2>&1 || true
if [ ! -s "$KO" ]; then
	alt=$($ADB shell 'ls /system/lib/modules/*.ko 2>/dev/null | head -n 1' | tr -d '\r')
	[ -n "$alt" ] || die "no stock .ko under /system/lib/modules - pass one:
  scripts/gen_addr.sh /path/to/any-stock.ko"
	$ADB pull "$alt" "$KO" >/dev/null 2>&1 || die "could not pull $alt"
fi
sh "$ROOT/scripts/gen_addr.sh" "$KO" >/dev/null
sed -n 's/^#define A_MODULE_LAYOUT_CRC  /crc /p' "$ROOT/kmod/addr.h"

say ""
say "== 4/6 vermagic =="
"$PY" "$ROOT/scripts/check_vermagic.py" "$CFG" "$KO" ||
	die "the config and the running kernel disagree about the flags
  a module built from this config would be rejected by insmod"

say ""
say "== 5/6 configure the tree =="
# A copy that is interrupted half way leaves a truncated file behind, and a
# 0-byte .config.save looks like a backup while being worthless.  Write beside
# it and rename.
if [ -s "$KDIR/.config" ] && ! cmp -s "$KDIR/.config" "$CFG" &&
	[ ! -e "$KDIR/.config.save" ]; then
	cp "$KDIR/.config" "$KDIR/.config.save.tmp" &&
		mv "$KDIR/.config.save.tmp" "$KDIR/.config.save"
	say "previous .config kept as $KDIR/.config.save"
fi
cp "$CFG" "$KDIR/.config"

LOG=$TMP/oldconfig.log
if ! yes "" | "$MAKE" -C "$KDIR" ARCH=arm oldconfig > "$LOG" 2>&1; then
	tail -n 20 "$LOG" >&2
	toolchain_hint
	die "oldconfig failed"
fi
NEW=$(grep -c ' (NEW)' "$LOG" 2>/dev/null || true)
[ -n "$NEW" ] || NEW=0
if [ "$NEW" -gt 0 ]; then
	warn "$NEW symbol(s) exist in the tree but not in the phone's config:"
	grep ' (NEW)' "$LOG" | head -n 10 | sed 's/^/  /' >&2
	[ "$NEW" -le "$NEW_LIMIT" ] || [ "$FORCE" -eq 1 ] ||
		die "$NEW > $NEW_LIMIT - the tree is too far from this build
  oldconfig fills the gaps with defaults, and a struct with a defaulted field
  is the kind of mismatch that loads fine and crashes later.  Get the tree
  matching $REL, or pass --force to accept the risk"
fi

say ""
say "== 6/6 modules_prepare =="
# -fcommon is for scripts/dtc: it has a tentative definition that modern gcc
# puts in .bss twice, and the link then fails with "multiple definition of
# yylloc".  Overriding HOSTCFLAGS drops the tree's -O2/-Wall for host tools,
# which costs nothing but compile time.
if ! "$MAKE" -C "$KDIR" ARCH=arm CROSS_COMPILE="$CROSS" CC="${CROSS}gcc" \
	HOSTCFLAGS="-fcommon" modules_prepare > "$LOG" 2>&1; then
	tail -n 25 "$LOG" >&2
	toolchain_hint
	die "modules_prepare failed"
fi

UTS=$(sed -n 's/^#define UTS_RELEASE "\(.*\)"$/\1/p' \
	"$KDIR/include/generated/utsrelease.h")
[ "$UTS" = "$REL" ] ||
	warn "warning: the tree will report \"$UTS\", the phone reports \"$REL\"
  harmless for loading (the kernel skips this half when the module has
  __versions), but re-run this script if you meant them to match"

say ""
say "== summary =="
say "kernel      $REL"
say "tree        $KDIR"
say "config      $CFG"
say "addr.h      $ROOT/kmod/addr.h"
say ""
say "next:"
say "  scripts/build.sh $KDIR"
say "  adb push kmod/pwrsq_diag.ko //data/local/tmp/ && adb shell 'su -c \"insmod /data/local/tmp/pwrsq_diag.ko; dmesg | grep pwrsq\"'"
say "  look for name=8941_l20 before trusting the build"
