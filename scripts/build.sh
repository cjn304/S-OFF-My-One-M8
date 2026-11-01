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
# On Windows/MSYS2 pass the kernel tree as a MSYS path (/d/...), not D:/...:
# kbuild reads M= as a make target and a drive-letter colon breaks it.
set -e

KDIR=${1:?usage: build.sh <kernel-tree> [cross-prefix]}
CROSS=${2:-arm-none-linux-gnueabihf-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

[ -f "$ROOT/kmod/addr.h" ] || {
	echo "kmod/addr.h is missing - run scripts/gen_addr.sh first" >&2
	exit 1
}
grep -q '0x00000000UL' "$ROOT/kmod/addr.h" && {
	echo "kmod/addr.h still has placeholder addresses" >&2
	exit 1
}

make -C "$KDIR" M="$ROOT/kmod" ARCH=arm \
	CROSS_COMPILE="$CROSS" CC="${CROSS}gcc" \
	modules

for m in pwrsq_diag pwrsq_off pwrsq_on; do
	undef=$("${CROSS}nm" -u "$ROOT/kmod/$m.ko")
	if [ -n "$undef" ]; then
		printf '%s:\n%s\n' "$m" "$undef"
	else
		printf '%s: (no undefined symbols)\n' "$m"
	fi
done
