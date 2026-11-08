#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the three modules against a prepared kernel tree.
#
#   scripts/build.sh <kernel-tree> [cross-compile-prefix]
#
# <kernel-tree> must already be configured + prepared for this exact kernel
# build (see the Building section of README.md).  CROSS_COMPILE defaults to
# arm-none-linux-gnueabihf- and can be overridden.
#
# After linking, each module is checked here rather than on the phone: no
# undefined symbols, one 64-byte __versions entry for module_layout, and a
# vermagic that agrees with the kernel recorded in kmod/addr.h.  Any failure
# makes the script exit non-zero.
#
# On Windows/MSYS2 pass the kernel tree as a MSYS path (/d/...), not D:/...:
# kbuild reads M= as a make target and a drive-letter colon breaks it.
set -e

KDIR=${1:?usage: build.sh <kernel-tree> [cross-prefix]}
CROSS=${2:-arm-none-linux-gnueabihf-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ -f "$ROOT/kmod/addr.h" ] || {
	echo "kmod/addr.h is missing - run scripts/prepare.sh first (it calls gen_addr.sh)" >&2
	exit 1
}
grep -q '0x00000000UL' "$ROOT/kmod/addr.h" && {
	echo "kmod/addr.h still has placeholder addresses" >&2
	exit 1
}

make -C "$KDIR" M="$ROOT/kmod" ARCH=arm \
	CROSS_COMPILE="$CROSS" CC="${CROSS}gcc" \
	modules

fail=0
for m in pwrsq_diag pwrsq_off pwrsq_on; do
	ko=$ROOT/kmod/$m.ko
	undef=$("${CROSS}nm" -u "$ko")
	if [ -n "$undef" ]; then
		printf '%s: undefined symbols\n%s\n' "$m" "$undef"
		fail=1
		continue
	fi

	# With CONFIG_MODVERSIONS the kernel wants exactly one modversion_info for
	# module_layout: 64 bytes on a 32-bit kernel.  An empty section still links,
	# and the load then fails on the phone instead of here.
	size=$("${CROSS}readelf" -S -W "$ko" |
		awk '{ for (i = 1; i <= NF; i++) if ($i == "__versions") { print $(i + 4); exit } }')
	entries=$("${CROSS}readelf" -p __versions "$ko" 2>/dev/null | grep -c module_layout || true)
	if [ "$size" != 000040 ] || [ "$entries" != 1 ]; then
		printf '%s: __versions is %s with %s module_layout entry, wanted 000040 and 1\n' \
			"$m" "${size:-absent}" "$entries"
		fail=1
		continue
	fi

	printf '%s: (no undefined symbols), __versions 64 bytes, 1 entry\n' "$m"
done

# The whole point of addr.h is that it describes the kernel the phone runs; a
# module built against a tree for another build carries a different string.
vm=$("${CROSS}strings" "$ROOT/kmod/pwrsq_on.ko" | sed -n 's/^vermagic=//p')
[ -n "$vm" ] || {
	echo "no vermagic= in kmod/pwrsq_on.ko - modinfo is missing" >&2
	exit 1
}
printf 'vermagic: %s\n' "$vm"
rel=$(sed -n 's/^ \* Kernel: Linux version \([^ ]*\).*/\1/p' "$ROOT/kmod/addr.h")
case "$vm" in
"$rel "*) ;;
*) printf 'warning: built for %s, addr.h describes %s - rebuild or re-run prepare.sh\n' \
	"${vm%% *}" "$rel" >&2 ;;
esac

[ "$fail" -eq 0 ] || exit 1
