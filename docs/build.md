# Building the modules

The module is out-of-tree: it needs the **exact** kernel source and config of
the running build, prepared for external modules.

## 1. Get the source

HTC publishes it on htcdev.com (Kernel Source Code). For the 6.0.1 M8 build the
download is `m8ul-3.4.0-perf-ga6393e1.zip`, which contains:

```
Readme.txt
kernel570.tar.gz      -> kernel/
platform.tar.gz       -> the rest of the AOSP tree
```

Only `kernel/` matters. Extract it somewhere with a case-sensitive filesystem;
if you are on Windows, note that the tree contains files that differ only in
case (`net/netfilter/xt_DSCP.c` vs `xt_dscp.c`) and NTFS will silently merge
them. Either enable per-directory case sensitivity (`fsutil file
setCaseSensitiveInfo <dir> enable`, needs admin) or extract with those paths
excluded — they are netfilter drivers and irrelevant to this module.

## 2. Get the exact config

Do **not** trust `arch/arm/configs/m8_defconfig`; HTC ships many variants from
one tree. The phone carries its own config inside the kernel image
(`CONFIG_IKCONFIG=y`, `CONFIG_IKCONFIG_PROC` off):

```sh
adb shell dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot.img bs=4096
adb pull /sdcard/boot.img

python3 - <<'EOF'
import struct, zlib
raw = open('boot.img','rb').read()
ks, ka, rs, ra, ss, sa, tags, page = struct.unpack('<8I', raw[8:40])
k = raw[page:page+ks]
i = k.find(b'\x1f\x8b\x08')
open('vmlinux.bin','wb').write(zlib.decompressobj(31).decompress(k[i:]))
EOF

sh kernel/scripts/extract-ikconfig vmlinux.bin > m8.config
grep -E 'CONFIG_MODULES|CONFIG_MODVERSIONS|CONFIG_LOCALVERSION' m8.config
```

`UTS_RELEASE` has to end up as `3.4.0-perf-ga6393e1`. Because the tarball has no
git history, `setlocalversion` cannot append the `-ga6393e1` suffix, so put it
in the config:

```sh
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-perf-ga6393e1"/' m8.config
```

## 3. Prepare the tree

```sh
cp m8.config kernel/.config
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- oldconfig
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- modules_prepare
```

Check `kernel/include/generated/utsrelease.h`:

```c
#define UTS_RELEASE "3.4.0-perf-ga6393e1"
```

If it does not match the phone's `uname -r` exactly, the module will be
rejected with "version magic ... should be ...".

## 4. Toolchain workarounds

A 2016 kernel built with a modern toolchain on MSYS2 hits five things. All of
them are in `kernel-patches/`.

| symptom | fix |
|---|---|
| `scripts/gcc-wrapper.py` is Python 2 (`print "..."`) | override `CC=` so the wrapper is skipped |
| `fatal error: linux/compiler-gcc13.h: No such file` | copy `compiler-gcc4.h` to `compiler-gcc13.h` |
| `fixdep: error opening config file: ` and random parse errors | MinGW gcc writes `.d` files with CRLF; patch fixdep to skip `\r` |
| `fixdep` segfaults on MSYS2 | replace its `mmap()` with `malloc()+read()` |
| `multiple definition of 'yylloc'` building dtc | `HOSTCFLAGS=-fcommon` |

```sh
cd kernel
git apply ../kernel-patches/0001-fixdep-crlf-and-no-mmap.patch
cp ../kernel-patches/compiler-gcc13.h include/linux/
```

The `gcc-wrapper` is only used because the top Makefile sets
`CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`; passing `CC=<cross>gcc` on
the command line overrides it. On Linux with an old toolchain none of this is
needed — the fixdep patch is still harmless.

## 5. Addresses and the module_layout crc

The module imports no symbols, so it needs no `Module.symvers`. Instead it needs
five addresses and one crc, which are properties of the exact kernel build:

```sh
scripts/gen_addr.sh                 # reads /proc/kallsyms + a stock .ko
cat kmod/addr.h
```

* the five addresses are plain text symbols, visible even with
  `CONFIG_KALLSYMS_ALL=n` (make sure `kptr_restrict` is 0);
* `A_MODULE_LAYOUT_CRC` is read out of `__versions` of a stock module shipped on
  the device (`scripts/get_module_layout_crc.py`). It is the crc genksyms
  computed for `module_layout` when the kernel was built, which is why it cannot
  be guessed.

## 6. Build

```sh
scripts/build.sh /path/to/kernel-tree
# on Windows/MSYS2 the tree must be a MSYS path, e.g. /d/kernel-src/kernel:
#   kbuild passes M= to make, and a drive-letter colon breaks the target
```

The script prints the undefined-symbol list of each `.ko`; it must be empty:

```
pwrsq_diag: (no undefined symbols)
pwrsq_off: (no undefined symbols)
pwrsq_on: (no undefined symbols)
```

Anything listed there is a symbol the kernel will demand a version crc for, and
loading will fail with `no symbol version for <sym>` or `disagrees about version
of symbol <sym>`.

Useful sanity checks before pushing anything to the phone:

```sh
readelf -S kmod/pwrsq_on.ko | grep __versions      # must be 64 bytes, non-empty
strings kmod/pwrsq_on.ko | grep vermagic=
nm -u kmod/pwrsq_on.ko                             # must print nothing
```

`__versions` must contain exactly one entry (`module_layout`). If it is empty,
the module was built without `addr.h` or the struct was optimised away.

## 7. Porting to another kernel/device

* `TARGET_VREG` and `TARGET_MMC_DEV` in `kmod/pwrsq_impl.h` name the rail and the
  MMC platform device. On other msm8974 HTC devices they are usually still
  `8941_l20` and `msm_sdcc.1`, but verify with
  `/sys/kernel/debug/regulator/*/consumers`.
* Re-run `scripts/gen_addr.sh`; addresses and crc change with every kernel
  build.
* If the kernel has `CONFIG_MODULE_SIG_FORCE=y`, none of this works — the module
  must be signed with a key the kernel trusts.
