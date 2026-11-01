# HTC-S-OFF-M8

**English** | [中文](README.zh-CN.md)

True **S-OFF** for the HTC One (M8) on **hboot 3.19.0.0000** — the bootloader the
community has treated as un-S-OFF-able since 2015.

This is not a new memory-corruption exploit. hboot protects the firmware
partitions with the eMMC's **power-on write protection**, which by design only
clears on a real power cycle of the card. Every userspace route to cycle that
rail is blocked, so the cycle is done from kernel context with a small module
that calls the PMIC regulator ops directly, followed by writing the one byte
hboot reads.

```
before                          after
------                          -----
secure_flag: 3                  secure_flag: 0
PVT SHIP S-ON                   PVT SHIP S-OFF
security: on                    security: off
CMD31: aaaaaaaa2aaaaaaa         CMD31: 0000000000000000   <- hboot stops arming WP
```

---

## Requirements

* [Unlock bootloader](http://www.htcdev.com/bootloader/). Then root, with Magisk,
  etc. or flash a firmware that ships root. The kernel has to be able to load
  modules: e.g. LineageOS 17.1 for m8 is disabled. Temporary root without
  unlocking BL works too, once S-OFF the BL is yours to unlock.
* The **exact kernel source** your firmware was built from.  HTC publishes the
  official one on [htcdev.com](https://www.htcdev.com/devcenter/downloads).
* A cross toolchain and a host that can run kbuild: Linux, or MSYS2/Git Bash
  (see [Windows](#windows)).
* Backups (see [Warnings](#warnings)).

---

## Quick start

```sh
# 0. pre-flight
adb shell id                                     # uid=0
adb shell getenforce                             # Permissive
adb shell cat /proc/sys/kernel/modules_disabled  # 0
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
adb shell 'mount -t debugfs none /sys/kernel/debug'

# 1. backups first - pg1fs, board_info, mfg, radio, misc
scripts/backup.sh

# 2. read the symbol addresses and the module_layout crc from the phone
scripts/gen_addr.sh

# 3. build the three modules against your prepared kernel tree
scripts/build.sh /path/to/kernel-tree

# 4. make sure the plumbing is right (no side effects)
adb push kmod/pwrsq_diag.ko /dev/
adb shell 'dmesg -c >/dev/null; insmod /dev/pwrsq_diag.ko; dmesg | grep pwrsq'
#    expect: rdev=... name=8941_l20 / consumer 'msm_sdcc.1' / mmc_host=...

# 5. stop the framework, flush, then cut and restore VCC
adb shell 'stop; sleep 8; sync'
scripts/powercycle.sh

# 6. confirm the write protection is gone, then set the flag
adb push tools/mmc_cmd /dev/ && adb shell chmod 755 /dev/mmc_cmd
adb shell '/dev/mmc_cmd wp'                      # expect all zeroes
scripts/write_flag.sh 0

# 7. verify from the bootloader
adb reboot bootloader && fastboot oem readsecureflag   # expect: 0
```

### Step by step, with expected output

**Pre-flight.** `ls /sys/kernel/debug/regulator/8941_l20/` should list
`consumers enable force_disable mode msm_sdcc.1-vdd open_count use_count voltage`.
If `insmod` is missing or `modules_disabled` is 1, stop: you need a rooted ROM
with module loading enabled.

**Diagnose.** Expected:

```
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` means the rail was found. `consumer 'msm_sdcc.1'` plus a
non-null `mmc_host` means the rescan path will work. `Failed to create debugfs
directory` is harmless (duplicate consumer dir). Remove with
`adb shell rmmod pwrsq_diag`.

**Quiesce.** The card is about to lose power; nothing may be writing to it.
`adb shell stop` takes the framework down and adbd stays up (class core). Then
`sync`. Optionally remount `/data` read-only:

```sh
adb shell 'for d in /mnt/runtime/*/emulated /data/media; do umount -l $d; done'
adb shell 'mount -o remount,ro /data'
```

On ROMs that keep a loop-mounted `/su` this fails with `Device or resource busy`
— then just make sure the framework is stopped and `sync` has run. `/data` is
mounted `errors=panic`, so a write during the outage panics the kernel.

**Power cycle.** `scripts/powercycle.sh` pushes both modules to `/dev` (tmpfs,
because anything still on `/data` is unreadable once the card is gone), runs
`pwrsq_off` then `pwrsq_on`. Expected:

```
--- power off / power on ---
SEQ_DONE
--- result ---
 179        2     121823 mmcblk0p2
...
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

If `/proc/partitions` has no `mmcblk0`, wait a few seconds and re-`insmod` the
`on` module (stage 2 is idempotent). Still nothing means a manual power cycle —
see [Recovery](#recovery).

**Write protection check.** Run `/dev/mmc_cmd wp`. It must be:

```
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

Do not continue if any group is listed.

**Write.** `scripts/write_flag.sh 0`:

```
before:
 03 00 00 00 48 54 43 55
after:
 00 00 00 00 48 54 43 55
```

The script does `dd` + `sync` + `drop_caches` before reading back, so the value
came off the card and not out of the page cache. That distinction matters: a
`dd` that "succeeds" against a write-protected card still updates the cache.

**Verify.**

```
$ fastboot oem readsecureflag
(bootloader) secure_flag: 0
$ fastboot getvar all | grep -Ei 'secure|misc'
(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

Boot Android again and confirm hboot no longer arms the protection:

```sh
adb shell '/dev/mmc_cmd wp'
# bitmap: 00 00 00 00 00 00 00 00
```

Why this is the real proof: [section 5](#5-why-it-stays-off).

---

## Device support

| item | verified value |
|---|---|
| device | HTC One (M8), `m8_ul` |
| MID / CID | `0P6B62000` / `HTCCN703` |
| firmware | 6.31.1402.1, Android 6.0.1 (MMB29M) |
| kernel | `3.4.0-perf-ga6393e1` (stock HTC, Jan 2016) |
| hboot | `3.19.0.0000` |
| privileges | adbd as root, SELinux permissive, `modules_disabled=0` |

Other M8 variants on a stock 3.4 kernel should behave the same way. Two things
are per-build and must be regenerated: the symbol addresses and the
`module_layout` crc (see [Building](#building)). The regulator name and MMC
platform device are compile-time parameters in `kmod/pwrsq_impl.h`.

---

## How it works

### 1. The wall

The S-OFF state is one byte in the `pg1fs` partition:

| offset | meaning | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag (u32 LE) | `03 00 00 00` | `00 00 00 00` |
| `0x8404` | tag | `"HTCU"` | `"HTCU"` |

`fastboot oem readsecureflag` reads exactly this value, and `getvar all` derives
`version-misc: PVT SHIP S-ON/S-OFF` and `security: on/off` from it.

Writing it as root fails, and the reason is neither SELinux nor the filesystem:
at every boot hboot sets the eMMC's **power-on write protection** on the
firmware groups. `CMD31` (SEND_WRITE_PROT_TYPE) reports 2 bits per group:

```
00 = not protected   01 = temporary   10 = power-on   11 = permanent
```

A stock, booted M8 answers:

```
CMD31 -> 0000000000000000 aaaaaaaa2aaaaaaa
                            groups 0..11 = 10b = power-on
```

Power-on protection is only cleared by a power cycle. `CMD29`
(CLEAR_WRITE_PROT) has no effect on it, and `dd` to `pg1fs` comes back with
`card status 0x400d00` — bit 22, `WP_ERASE_SKIP`.

So the problem reduces to: cut VCC to the eMMC and bring it back, without
rebooting the SoC.

### 2. Why userspace cannot do that

The rail is **PM8941 LDO20** (`8941_l20`, 2.95 V), managed through RPM-SMD. The
device tree node for the eMMC controller says:

```dts
&sdhc_1 {
	vdd-supply = <&pm8941_l20>;
	qcom,vdd-always-on;
	...
```

Three independent blockers:

1. **`qcom,vdd-always-on`** — `sdhci_msm` enables the rail at probe and never
   disables it.
2. **regulator core short-circuit** — after forcing the rail off via debugfs,
   `regulator_enable()` still refuses to call `->enable()`:

   ```c
   static int _regulator_enable(struct regulator_dev *rdev)
   {
           if (rdev->use_count == 0) {
                   ret = _regulator_is_enabled(rdev);
                   if (ret == -EINVAL || ret == 0) {
                           ...
                           ret = rdev->desc->ops->enable(rdev);
   ```

   `rpm_vreg_is_enabled()` returns the driver's cached request bit, which stays
   "on" for an always-on rail, so the core concludes the rail is already up and
   never touches the hardware. `echo 1 > .../enable` returns success and does
   nothing.
3. **No rescan hook** — `sdhci` has no userspace "rescan" attribute, unbinding
   the driver does not cut power, and `device_release_driver()` can block
   forever if a filesystem on that gendisk is still writable.

What does work from userspace is the first half only:

```sh
echo 1 > /sys/kernel/debug/regulator/8941_l20/force_disable   # VCC really drops
```

The card disappears, `mmcblk0*` vanish — and there is no way back except a
reboot. That is the wall.

### 3. The module

`kmod/pwrsq_impl.h` does four things:

1. **Resolve the regulator** — `regulator_get(NULL, "8941_l20")`. `struct
   regulator` is private to `drivers/regulator/core.c`, so the module carries a
   copy of the struct to reach `->rdev`.
2. **Call the driver ops directly** — `rdev->desc->ops->disable(rdev)` and later
   `->enable(rdev)`. This bypasses `_regulator_enable()` and therefore the
   `is_enabled()` short-circuit.
3. **Find the MMC host** — walk `rdev->consumer_list`, pick the entry whose
   device name is `msm_sdcc.1`, read its drvdata (which `sdhci_pltfm_init()`
   sets to the `sdhci_host`), and take `sdhci_host->mmc`.
4. **Ask for a rescan** — `mmc_detect_change(host, 0)` schedules `mmc_rescan()`,
   which re-runs card identification.

Three build variants come from the same source: `diag` (stage 3, read only),
`off` (stage 1) and `on` (stage 2, which sleeps 1.5 s first so the rail
discharges before power is restored).

The log these produce is shown in [Quick start](#quick-start); the two lines that
matter here are `ops->disable ret=0` and `ops->enable ret=0` - they mean the driver
ops really ran instead of being short-circuited by the core.  The `mmc_reinit_card`
pair at the end is HTC's own re-initialisation path in `sdhci_msm`: the card comes
back, with its partitions, without rebooting.

### 4. The write

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
```

`33792` is `0x8400`. Only the low byte changes (`03` -> `00`); the tag at
`0x8404` is already `HTCU` on shipping devices.  The before/after bytes and the
reason for the `drop_caches` afterwards are in [Quick start](#quick-start); what
this section is about is that the write is 4 bytes and nothing else in the record
has to move.

There is a second 4-byte field at `pg1fs + 0x424` that the old
`firewater`/Sunshine payload also writes. On this device it is **not** required:
the partition head (0..0x1000, including `0x424`) stayed byte-identical to the
pre-change backup after a successful S-OFF, and the phone booted normally. Leave
it alone.

### 5. Why it stays off

After the reboot hboot reads `secure_flag = 0` and takes its S-OFF path — which
includes **not arming the power-on write protection**. That is why a second
`CMD31` on the S-OFF device returns all zeroes, and why `pg1fs` stays writable
from then on. The protection was never "defeated"; it simply stopped being set.

### 6. Why the module loads at all

The kernel is built with `CONFIG_MODVERSIONS=y` and we do not have its
`Module.symvers`. Two consequences, both handled:

* every imported symbol would need a matching crc — so the module imports
  **none**: all function addresses come from `/proc/kallsyms` at build time
  (`kmod/addr.h`);
* `module_layout` is checked unconditionally, so the module carries its own
  `__versions` entry with the crc copied from a stock `.ko` on the device.

---

## stool.sh

`scripts/stool.sh` wraps everything above, plus the parameters that have nothing
to do with S-OFF.

```sh
scripts/stool.sh status                  # S state + every parameter (Android or fastboot)
scripts/stool.sh soff                    # full S-OFF: backup, diag, power cycle, write, verify
scripts/stool.sh son                     # back to S-ON
scripts/stool.sh backup                  # snapshot to backup/<YYYYmmdd-HHMMSS>.txt
scripts/stool.sh restore <snapshot>      # write a snapshot back
scripts/stool.sh set cid BS_US001
scripts/stool.sh set mid 0P6B12000
scripts/stool.sh set version 6.12.1540.4
scripts/stool.sh set tamper 0
scripts/stool.sh set secure 0|3
scripts/stool.sh lock bootloader         # BL magic -> locked   (S-OFF, no token)
scripts/stool.sh unlock bootloader       # BL magic -> unlocked (S-OFF, no token)
scripts/stool.sh noredtext               # blank the six dev-warning lines in hboot
scripts/stool.sh noredtext --restore <hboot.img>
scripts/stool.sh splash photo.png        # first boot screen, 1080x1920 by default
scripts/stool.sh splash photo.png --size=1440x2560     # other panels
scripts/stool.sh splash --restore <sp1.img>
```

Every command reads the S state first. Anything that writes takes a parameter
snapshot into `backup/<timestamp>.txt` before touching the card; the file holds
both a readable summary and a `raw:<part>:<offset>=<hex>` block that `restore`
replays byte for byte.

`set secure 0` refuses to run while S-ON: writing the flag needs the write
protection cleared, and clearing it is what `soff` does.

`lock bootloader` / `unlock bootloader` write the four bytes at `pg1fs` (p2) 0x8404 directly:
`HTCU` = unlocked, `00000000` = locked. That is the same magic hboot compares at
boot, so once the device is S-OFF no unlock token is involved. `fastboot oem lock`
is not used either — it only produces `RELOCKED`, and hboot 3.19 has no
`oem unlock` command at all (`[ERR] Command error`).

What a snapshot holds:

| file | content | size |
|---|---|---|
| `<ts>.txt` | every parameter, plus the exact byte ranges to restore | ~0.5 KB |
| `<ts>.board_info.img` | whole p3 — CID, IMEI, board data | 16 KB |
| `<ts>.mfg.img` | whole p5 — MID lives here | 256 KB |
| `<ts>.misc.img` | whole p24 — version-main lives here | 1 MB |

`set cid` goes through `fastboot oem writecid`, which is opaque, so the whole p3
image matters more than the 8 bytes in the txt. Radio (p20) is never written by
this tool; take it once with `scripts/backup.sh`, which dumps pg1fs, board_info,
mfg, radio and misc as full images.

| parameter | storage | how |
|---|---|---|
| CID | `board_info` (p3) @ 0x14, 8 chars | `fastboot oem writecid` (reboots to the bootloader) |
| MID | `mfg` (p5) @ 0x4000, 9 chars UTF-16LE | dd |
| version | `misc` (p24) @ 0xA0 | dd |
| tamper | `pg2fs` (p6) @ 0x511804 | dd |
| secure | `pg1fs` (p2) @ 0x8400 | dd, S-OFF only |
| lock / unlock | `pg1fs` (p2) @ 0x8404, `HTCU` / `00000000` | dd, S-OFF only |
| red text | `hboot` (p26), six strings located at run time | dd, S-OFF only |
| first screen | `sp1` (p12) @ 0, 1080x1920 RGB565 | dd, S-OFF only |

### Red text and the first screen

`noredtext` finds the six lines by content, not by a hard-coded offset.  It
dumps the whole 4 MB `hboot` partition, searches for the six strings, blanks
the first byte of each, writes them back and reads them back.  The offsets move
between builds - `0x8C340` on 6.12.1540.4, `0x8C3F8` on the 6.31.1402.1 dump,
`0x899CE` on the older m8_ul image - which is exactly why the search is dynamic.

Two things to know before running it:

- hboot carries the HTC signature.  Changing bytes breaks it; S-OFF is what
  makes the SBL skip the check.  Never run this while S-ON, and keep the dumped
  `<ts>.hboot.img` - `noredtext --restore` writes it straight back.
- On the 6.12.1540.4 hboot these six strings have **no static cross reference**
  in the image.  Every form was scanned: absolute address, raw file offset,
  low-20-bit match, ARM and Thumb `movw`/`movt`, and the literal pool of the
  code section.  The banner is assembled at run time, so blanking the strings is
  the only safe edit - there is no "draw function" with a patchable argument to
  find.

`splash` converts a PNG into what the `sp1` partition actually holds: little-endian
RGB565, 1080x1920 (4,147,200 bytes) unless `--size=WxH` says otherwise; the rest of
the partition is padding.  The frame size is checked against the partition size
before anything is written.

The conversion is done by `scripts/png2rgb565.py`, pure standard
library on purpose (a bare Windows box has no ffmpeg, no PIL, no ImageMagick).
It takes non-interlaced 8-bit PNG in grey, grey+alpha, RGB, RGBA or palette and
scales with bilinear filtering; anything else is rejected with a clear message
(JPEG included - re-save it as PNG first).

A source that is not 9:16 is handled by `--fit`, and the command says so:

| `--fit` | what happens |
|---|---|
| `contain` (default) | scale to fit, centre, pad the rest with `--bg=RRGGBB` (default black) |
| `cover` | scale to fill, centre-crop the overflow - no bars, edges lost |
| `stretch` | scale each axis independently - **distorts**, prints a warning |

The old behaviour was always `stretch`, which silently turned a 1920x1080 photo
into a squashed 1080x1920 one.  `contain` is the default now because a boot
screen with black bars is a smaller mistake than a stretched logo.

The converter checks the container, not the picture: it verifies the PNG is
readable, the colour type and bit depth are supported, the result is exactly
4,147,200 bytes, and the written bytes read back identical.  It cannot tell you
that the image is upside down, all black, all white, or too low resolution to
look good - that is on you.

Both commands need S-OFF, back up the whole target partition first, and verify
by reading the bytes back.

---

## Building

### 1. Get the source

HTC publishes it on [htcdev.com](https://www.htcdev.com/devcenter/downloads)
(Kernel Source Code). For the 6.0.1 M8 build the download is
`m8ul-3.4.0-perf-ga6393e1.zip`, containing `kernel570.tar.gz` (`kernel/`) and
`platform.tar.gz` (the rest of the tree). Only `kernel/` matters.

On Windows, NTFS is case-insensitive and the tree contains files that differ
only in case (`net/netfilter/xt_DSCP.c` vs `xt_dscp.c`). Either enable
per-directory case sensitivity (`fsutil file setCaseSensitiveInfo <dir> enable`,
needs admin) or extract with those paths excluded — they are netfilter drivers
and irrelevant here.

### 2. Get the exact config

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

### 3. Prepare the tree

```sh
cp m8.config kernel/.config
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- oldconfig
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- modules_prepare
```

Check `kernel/include/generated/utsrelease.h`:

```c
#define UTS_RELEASE "3.4.0-perf-ga6393e1"
```

If it does not match the phone's `uname -r` exactly, the module is rejected with
"version magic ... should be ...".

### 4. Toolchain workarounds

A 2016 kernel built with a modern toolchain on MSYS2 hits five things. All of
them are in `kernel-patches/`.

| symptom | fix |
|---|---|
| `scripts/gcc-wrapper.py` is Python 2 (`print "..."`) | override `CC=` so the wrapper is skipped |
| `fatal error: linux/compiler-gcc13.h: No such file` | copy `compiler-gcc4.h` to `compiler-gcc13.h` |
| `fixdep: error opening config file:` and random parse errors | MinGW gcc writes `.d` files with CRLF; patch fixdep to skip `\r` |
| `fixdep` segfaults on MSYS2 | replace its `mmap()` with `malloc()+read()` |
| `multiple definition of 'yylloc'` building dtc | `HOSTCFLAGS=-fcommon` |

```sh
cd kernel
git apply ../kernel-patches/0001-fixdep-crlf-and-no-mmap.patch
cp ../kernel-patches/compiler-gcc13.h include/linux/
```

The wrapper is only used because the top Makefile sets
`CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`; passing `CC=<cross>gcc` on
the command line overrides it. On Linux with an old toolchain none of this is
needed — the fixdep patch is still harmless.

### 5. Addresses and the module_layout crc

The module imports no symbols, so it needs no `Module.symvers`. Instead it needs
five addresses and one crc, all properties of the exact kernel build:

```sh
scripts/gen_addr.sh                 # reads /proc/kallsyms + a stock .ko
cat kmod/addr.h
```

* the five addresses are plain text symbols, visible even with
  `CONFIG_KALLSYMS_ALL=n` (make sure `kptr_restrict` is 0);
* `A_MODULE_LAYOUT_CRC` is read out of `__versions` of a stock module shipped on
  the device (`scripts/get_module_layout_crc.py`). It is the crc genksyms
  computed for `module_layout` when the kernel was built, so it cannot be
  guessed.

### 6. Build

```sh
scripts/build.sh /path/to/kernel-tree
# On Windows/MSYS2 pass a MSYS path (/d/kernel-src/kernel), not D:/...
# kbuild passes M= to make, and a drive-letter colon breaks the target.
```

The script prints the undefined-symbol list of each `.ko`; it must be empty:

```
pwrsq_diag: (no undefined symbols)
pwrsq_off: (no undefined symbols)
pwrsq_on: (no undefined symbols)
```

Anything listed there is a symbol the kernel will demand a version crc for, and
loading fails with `no symbol version for <sym>` or `disagrees about version of
symbol <sym>`.

Sanity checks before pushing anything to the phone:

```sh
readelf -S kmod/pwrsq_on.ko | grep __versions    # 64 bytes, non-empty
strings kmod/pwrsq_on.ko | grep vermagic=
nm -u kmod/pwrsq_on.ko                           # prints nothing
```

`__versions` must contain exactly one entry (`module_layout`). If it is empty,
the module was built without `addr.h` or the struct was optimised away.

### 7. Porting

Two things must match, and they fail independently: the kernel side (struct
layouts, symbol addresses) and the model side (rail name, device name, offsets,
partition names). Devices fall into four tiers.

| tier | devices | work required |
|---|---|---|
| **A** verified | `m8_ul` on 6.31.1402.1 (`ga6393e1`) and 6.12.1540.4 (`g708019f`) | none |
| **B** same generation | other M8 variants, E8 / Butterfly 2 / mini 2 off the same HTC 3.4 tree | `addr.h` + `module_layout` crc |
| **C** same era, new driver layer | M7 (msm8960), M9 (msm8994, 3.10), Desire (msm8x26 / msm8x10) | structs, rail, offsets |
| **D** HTC 10 and later | `pme` and everything after it | see below |

**A. Verified.** Both firmware branches of the same phone, four months apart in
HTC's build server. Only `addr.h` and the `module_layout` crc differ between
them, which is exactly what `scripts/gen_addr.sh` regenerates.

**B. Same generation.** The mechanism, the structures and the record layout all
hold; what has to be re-checked is only what is spelled out per board:

* `TARGET_VREG` and `TARGET_MMC_DEV` stay `8941_l20` and `msm_sdcc.1`. Both are
  board strings, not driver names: `board-8974.c` registers the `sdhci-msm`
  device under the name `msm_sdcc.1`, and the rail name comes from
  `msm-pm8x41-rpm-regulator.dtsi`.
* The security record keeps its shape - `{u32 flag; char magic[4]}` at pg1fs
  0x8400, reading `03 00 00 00` + `HTCU` on an S-ON device. Check those eight
  bytes before writing anything.
* `scripts/gen_addr.sh` plus a fresh `module_layout` crc is the whole job.

**C. Same era, driver layer must be redone.** The idea still applies, but four
things change at once and each one can silently produce a module that loads and
then does the wrong thing:

1. `struct regulator` is private to `drivers/regulator/core.c`; this file carries
   a copy, and it must be re-copied from the target tree.
2. drvdata: this kernel stores `sdhci_host`; variants that bind the older
   `msm_sdcc` driver store their own host struct, and reading `->mmc` off it is
   garbage.
3. The rail name follows the PMIC, not the SoC.
4. Every offset in the parameter table has to be re-derived.

`pwrsq_diag.ko` exists to answer 2 and 3 from the device instead of from a
guess: it resolves the regulator, prints every consumer and the mmc_host it
found, and writes nothing.

**D. HTC 10 and later.** Nothing carries over unchanged. Measured against a
`pme` partition dump:

| item | M8 | HTC 10 |
|---|---|---|
| bootloader | `hboot` | `aboot` |
| `board_info` | p3 | **p1** |
| `mfg` | p5 | **p2** |
| `pg1fs` | p2 | **p3** |
| `pg2fs` | p6 | **p4**, 23.6 MB instead of a few hundred KB |
| `sp1` | p12, 5 MB | **p21, 10 MB** |
| by-name | `/dev/block/bootdevice/by-name` | `/dev/block/platform/soc/7464900.sdhci/by-name` |
| kernel | 3.4.0 | **3.10.84 or 3.18.20** - HTC publishes both branches |
| panel | 1080x1920 | 1440x2560 |

So this tool would have to grow, in order of severity:

1. `struct regulator` re-copied per branch - 3.10 and 3.18 differ from 3.4 and
   from each other.
2. drvdata: newer kernels store `sdhci_pltfm_host` and expect
   `pltfm_host->host`.
3. Every offset in the parameter table re-derived; only the pg1fs record is
   likely to keep its shape.

Two items that used to be on this list are already gone: the by-name directory is
probed for instead of assumed (`detect_dev` in `stool.sh`), and `splash
--size=WxH` takes the panel geometry instead of hard-coding 1080x1920.

And from the U11 on, HTC ships UFS 2.1 instead of eMMC. There is no `mmcblk0` and
no CMD28/29/31 write-protect group, so the mechanism this tool is built on does
not exist on those phones regardless of how much of the rest is ported.

**One case needs no porting.** If the target arms no write protection in the
first place, skip the power cycle entirely: run `mmc_cmd wp` on the S-ON device
first. An all-zero bitmap means a plain `dd` is enough and the module is not
needed.

---

## Windows

The `.sh` files are POSIX shell scripts; Windows cannot execute them directly.
Use one of:

* **Git Bash** (ships with Git for Windows) or **MSYS2** — what this project was
  developed and verified with. Open the shell in the repo root:
  `./scripts/build.sh /d/kernel-src/kernel` or `sh scripts/build.sh ...`.
* **WSL** — works, but `adb`, `make` and the toolchain must exist inside the
  distro, and USB needs `usbipd`.
* **Cygwin** — untested.

Three things bite on Windows:

1. **Line endings.** A script saved with CRLF dies with
   `$'\r': command not found`. The repo pins `*.sh text eol=lf` in
   `.gitattributes`, so a fresh clone is fine; if you copy files around, run
   `sed -i 's/\r$//'`.
2. **Paths.** Git Bash understands `/d/...`; kbuild does not accept `D:/...` as
   `M=` because the colon looks like a make target separator. Pass MSYS paths to
   `scripts/build.sh`.
3. **PATH.** `adb`, `make` and `python3` must be visible from that shell. Git
   Bash does not bundle `make`; install MSYS2 or add it to `PATH`.

Toolchain actually used here: Git Bash (WorkBuddy bundle), GNU Make 4.4.1 from
MSYS2, Python 3.13, adb 1.0.41, `arm-none-linux-gnueabihf-gcc` 13.3.1 (MinGW
host build). The steps in this README were executed as the equivalent raw
commands; `scripts/gen_addr.sh` was additionally run end-to-end.

---

## Field evidence

Trimmed captures from the reference device. Serial and IMEI removed.

**Before**

```
(bootloader) version-bootloader: 3.19.0.0000
(bootloader) version-main: 6.31.1402.1
(bootloader) version-misc: PVT SHIP S-ON
(bootloader) product: m8_ul
(bootloader) modelid: 0P6B62000
(bootloader) cidnum: HTCCN703
(bootloader) security: on

$ fastboot oem readsecureflag
(bootloader) secure_flag: 3

$ mmc_cmd wp
bitmap: aa aa aa aa 2a aa aa aa      -> groups 0..11 power-on
```

**During the power cycle**

```
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: ops->disable ret=0
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: sdhci_cmd_irq: AUTO CMD err sts 0x00000002
mmc0: mmc_blk_issue_rw_rq status 4 retry 0
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

**After**

```
$ mmc_cmd wp
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all

00008400  00 00 00 00 48 54 43 55

$ fastboot oem readsecureflag
(bootloader) secure_flag: 0
(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

Two cold boots later both `readsecureflag` and `mmc_cmd wp` still report zero.

**Integrity of the rest of the partition.** `md5` of `pg1fs[0x0000..0x1000]`
before and after:

```
f22ff5ac41ac26e1a3ecd2997ba6ca3a   before (backup)
f22ff5ac41ac26e1a3ecd2997ba6ca3a   after
```

Identical, including the device-specific 4-byte field at `0x424`. Only `0x8400`
changed — which is why this tool writes exactly one byte.

---

## Recovery

Work through this in order.

**The card did not come back.** `SEQ_DONE` was printed but `/proc/partitions`
has no `mmcblk0`.

1. Wait 10 s — `mmc_detect_change()` runs on a workqueue.
2. `adb shell 'dmesg | tail -40'`. Look for `mmc_reinit_card`,
   `AUTO CMD err`, `Controller never released inhibit bit(s)`.
3. `adb shell 'insmod /dev/pwrsq_on.ko'` again; stage 2 is idempotent.
4. If adb is gone too, hold power ~10 s. The phone boots normally, the flag is
   unchanged, and you can retry.

Nothing is permanently damaged by a failed power cycle — the flag is only
written in the last step.

**The kernel panicked.** `/data` is mounted `errors=panic`, so any write that
reaches a dead card panics. The phone reboots by itself, the protection is
re-armed, the flag is untouched. Fix the cause (stop the framework, `sync`,
remount `/data` read-only) and retry.

**`dd` reports success but the byte does not change.** The write never reached
the card.

```sh
adb shell '/dev/mmc_cmd wp'                    # any non-zero group => still protected
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00` (bit 22, `WP_ERASE_SKIP`) — protection still active;
  the power cycle did not actually happen. `pwrsq: ops->disable ret=0` must
  appear in `dmesg`, and `cat /sys/kernel/debug/regulator/8941_l20/enable` must
  read 0 while the card is gone.
* no card-status error at all — you read back from the page cache. Always
  `sync` + `echo 3 > /proc/sys/vm/drop_caches` before verifying.

**Restoring a backup.** With S-OFF the firmware partitions are writable, so a
restore is a plain `dd`:

```sh
adb push backup-.../pg1fs.img /dev/pg1fs.img
adb shell 'dd if=/dev/pg1fs.img of=/dev/block/bootdevice/by-name/pg1fs bs=1048576'
adb shell 'sync; rm -f /dev/pg1fs.img'
adb reboot bootloader && fastboot oem readsecureflag
```

Same for `board_info` (p3), `mfg` (p5), `radio` (p20) and `misc` (p24).
Restoring `pg1fs.img` puts `0x8400` back to `03` — i.e. S-ON.

**Do not**

* **`fastboot flash` a firmware partition.** hboot verifies signatures on every
  one of them and refuses — that is the behaviour this tool works around, and
  also what protects you from a bad image.
* **Write anything in `pg1fs` other than `0x8400`.** The header at `0x400`
  describes three records (`security`, `simlock`, `simunlock`); the 4 bytes at
  `0x424`/`0x824`/`0xc24` are device-specific and were left untouched here on
  purpose.
* **Run the power cycle while `/data` is being written.** The panic is
  recoverable; a half-written ext4 journal is not always.

**If the phone will not boot at all**, enter the bootloader (volume down +
power). If hboot comes up, `fastboot getvar all`: still S-ON means nothing was
modified and a normal ROM flash recovers you; S-OFF with a dead Android can be
fixed with any matching RUU. If hboot does not come up, the problem is not in
`pg1fs` — this procedure never touches `hboot`, `sbl1` or `tz`.

---

## Undo

```sh
scripts/write_flag.sh 3 && adb reboot bootloader && fastboot oem readsecureflag
```

`3` restores S-ON. The write protection comes back on the next boot, as does the
inability to write `pg1fs`. S-ON with an unlocked bootloader is a supported
state; S-ON with a modified `hboot` is not — flash a stock `hboot` first if you
ever replaced it.

---

## Warnings

* Remount `/data` read-only or stop the framework before the power cycle.
  `/data` is `errors=panic`; a write to a dead card panics the kernel.
* If the card does not re-enumerate, the phone will not boot until it is power
  cycled by hand. Nothing is lost, but you need physical access.
* `scripts/backup.sh` exists because "should not happen" is not a recovery plan.
  Keep the images on a PC, not on the phone.
* Writing `pg1fs` is the point of the tool and the only irreversible step.
  `0x8400`: `00` = S-OFF, `03` = S-ON. Do not touch anything else.

No warranty. If you brick it, you own both halves.

---

## Repository layout

```
kmod/              the power-cycle module (three build variants + addr.h)
tools/             mmc_cmd: CMD31 write-protection query
scripts/           stool.sh control tool, backup, address generation, build, power cycle
kernel-patches/    fixes needed to build a 3.4 tree with a modern toolchain
```

---

## Credits

* HTC for publishing the kernel source, and for the `mmc_reinit_card` path that
  makes the card come back without a reboot.
* The XDA/ARHD community for the RUU/CID/MID knowledge this relies on.
* The `firewater`/Sunshine era research for documenting what the S-OFF flag is.

---

## License

GPL-2.0. The kernel module in `kmod/` links against a GPL-2.0-only kernel and
declares `MODULE_LICENSE("GPL")`; it cannot be relicensed.

---

## Disclaimer

For security research and maintenance on devices you own. Cutting power to an
eMMC while Android is running is not a supported operation; make sure you have a
recovery path before you start. No warranty of any kind; the authors are not
responsible for bricks, data loss or voided warranties.
