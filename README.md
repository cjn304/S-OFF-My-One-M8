# S-OFF-My-One-M8

**English** | [中文](README.zh-CN.md)

Since Firewater and Sunshine stopped being available, there has been no working
HTC S-OFF tool.

This is not a memory-corruption exploit. hboot protects the firmware partitions
with the eMMC's power-on write protection, which by design only clears on a real
power cycle. Every userspace route to cycle that rail is blocked, so
the cycle is done from kernel context with a small module that calls the PMIC
regulator ops directly, followed by writing the one byte hboot reads.

[Tested](#field-evidence) on the HTC One M8, hboot 3.19.0.0000
(other devices: see [Porting](#8-porting)).

---

## Requirements

* [Unlock bootloader](http://www.htcdev.com/bootloader/). Then root, with Magisk,
  etc. or flash a firmware that ships root. The kernel has to be able to load
  modules: e.g. LineageOS 17.1 for M8 is disabled. Temporary root without
  unlocking BL works too, once S-OFF the BL is yours to unlock.
* The kernel source your firmware was close to.  HTC publishes the official
  ones on [htcdev.com](https://www.htcdev.com/devcenter/downloads).
* A cross toolchain and a host that can run kbuild: Linux, or MSYS2/Git Bash
  (see [Windows](#windows)).
* Backups (see [Warnings](#warnings)) and [Building](#building).

---

## Quick start

The commands below assume `adb shell` is root: a userdebug or eng ROM, where
`adb root` works, or a rooted stock ROM, where every `adb shell ...` becomes
`adb shell 'su -c "..."'`. The quoting matters - the redirection has to sit
inside the su command, or the non-root shell performs it first and fails with
`Permission denied`. `stool.sh status`, `soff` and `son` find root on their own;
`gen_addr.sh` needs none: once `kptr_restrict` is 0, `/proc/kallsyms` is
world-readable.
[Expected output and troubleshooting](#expected-output-and-troubleshooting).

```sh
# 0. check root, S state, modules_disabled, SELinux
scripts/stool.sh status

# 1. kallsyms hides addresses until kptr_restrict is 0; then read them
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
scripts/gen_addr.sh

# 2. build the three modules and the mmc_cmd helper
scripts/build.sh /path/to/kernel-tree
make -C tools CROSS=arm-none-linux-gnueabihf-

# 3. mount debugfs, then backup, diagnose, power cycle, write, verify
adb shell 'mount -t debugfs none /sys/kernel/debug'
scripts/stool.sh soff

# 4. undo: back to S-ON; the write protection returns on the next boot
scripts/stool.sh son
```

---

## stool.sh

`scripts/stool.sh` is the entry point for every command below. All of them
need S-OFF except `status`, `backup`, `soff` itself, and `set secure 0` on a
phone whose hboot never armed the protection.

```sh
scripts/stool.sh status                  # S state + every parameter (Android or fastboot)
scripts/stool.sh soff                    # full S-OFF: backup, diag, power cycle, write, verify
scripts/stool.sh son                     # back to S-ON
scripts/stool.sh backup                  # five partitions + parameters, ~144 MB
scripts/stool.sh restore <snapshot>      # write a snapshot back
scripts/stool.sh set cid <cid>           # 8 chars, 11111111 = SuperCID
scripts/stool.sh set mid <mid>           # 9 chars, e.g. 0P6B12000
scripts/stool.sh set version <version>   # e.g. 6.12.1540.4, max 15
scripts/stool.sh set tamper <0|4>        # 0 = Official, 4 = Modified
scripts/stool.sh set secure <0|3>        # 0 = S-OFF, 3 = S-ON
scripts/stool.sh lock                    # BL magic -> locked
scripts/stool.sh unlock                  # BL magic -> unlocked
scripts/stool.sh noredtext               # blank the six dev-warning lines in hboot
scripts/stool.sh noredtext --restore <hboot.img>
scripts/stool.sh splash photo.png        # first boot screen, 1080x1920 by default
scripts/stool.sh splash photo.png --size=1440x2560     # other panels
scripts/stool.sh splash --restore <sp1.img>
```

Where each parameter lives, and which partitions get dumped, comes from
`targets.conf`: one section per partition layout, matched against the sizes the
device reports in `/sys/class/block/*/uevent`. A phone whose layout has no
section is refused before anything is written - see
[section 6](#6-parameter-offsets) to add one.

Every command reads the S state first. Anything that writes saves a snapshot
into `backup/<timestamp>.{txt,img}` before touching the eMMC: five whole
partitions, plus a txt with a readable summary and a
`raw:<part>:<offset>=<hex>` block that `restore` replays byte for byte.

`set tamper` takes any decimal 0..255, but only `0` and `4` mean anything.
That byte is the only input to hboot's `Software status:` line: `04` prints
`*** Software status: Modified ***`, `00` prints
`*** Software status: Official ***`.

`set secure` is the write from the last stage of `soff`, on its own: a snapshot
first, then `00` or `03` at `0x8400`, then a read-back - no power cycle and no
reboot. `00` while S-ON is refused unless `mmc_cmd wp` reports no write
protection, which is the old-hboot case in [Porting](#8-porting); there it is
the plain write that sets the flag. On an S-OFF phone it re-applies `00` after a
`pg1fs.img` restore.

`lock` / `unlock` write the four bytes at `pg1fs` (p2)
0x8404 directly: `HTCU` = unlocked, `00000000` = locked. That is the same magic
hboot compares at boot, so once the device is S-OFF no htcdev-issued unlock
code is needed. `fastboot oem lock` is not used either — it only produces
`RELOCKED`, and hboot 3.19 has no `oem unlock` command at all
(`[ERR] Command error`).

What a snapshot holds:

| file | content | size |
|---|---|---|
| `<ts>.txt` | every parameter, plus the exact byte ranges to restore | ~0.5 KB |
| `<ts>.pg1fs.img` | whole p2 — the secure flag lives here | 119 MB |
| `<ts>.board_info.img` | whole p3 — CID, IMEI, board data | 16 KB |
| `<ts>.mfg.img` | whole p5 — MID lives here | 256 KB |
| `<ts>.pg2fs.img` | whole p6 — the tamper flag lives here | 24 MB |
| `<ts>.misc.img` | whole p24 — version-main lives here | 1 MB |

`set cid` writes its 8 bytes at `board_info` 0x14 with `dd`, like the rest;
hboot reads it at boot, so `getvar cidnum` only changes after a reboot. The
whole p3 image is still kept - the CID sits next to the IMEI and board data this
tool never touches. Radio (p20) is never written, so it is not dumped. The whole
set is ~144 MB and takes about a minute over USB.

### CID, MID and flashing

MID names the model variant - `0P6B62000` is the China Unicom M8, `0P6B12000`
the Dev Edition - and CID names the carrier or region (`HTCCN703` for China
Unicom). An RUU checks both against the image and refuses to flash when either
does not match, which is why changing them is the usual prerequisite for
another region's firmware: `set mid` writes mfg 0x4000, `set cid` writes
board_info 0x14, and CID `11111111` (SuperCID) makes the phone accept any CID -
the MID check still applies. What each package expects
is listed in
[this M8 firmware sheet](https://docs.google.com/spreadsheets/d/10H7RftecZZKb5tT2zpShfYNFAfSe-imhhqtVfeMPVDA/edit?gid=0#gid=0).

### Red text at boot

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

### First screen

`splash` converts a PNG into what the `sp1` partition actually holds:
little-endian RGB565, 1080x1920 (4,147,200 bytes) unless `--size=WxH` says
otherwise; the rest of the partition is padding.  The frame size is checked
against the partition size before anything is written.

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

The `dd` needs root: on a Magisk ROM write it as
`adb shell 'su -c "dd …"'`. Everything else in this block runs on the host.

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

### 6. Parameter offsets

`kmod/addr.h` covers the kernel symbols; the parameter offsets are generated by
nothing either. They follow the partition layout, so they live in
`targets.conf`.

The section is chosen by comparing its `layout` line against the sizes the
device reports in `/sys/class/block/*/uevent` (`PARTNAME` plus `size`, in
512-byte sectors, world-readable and no root needed). Size is the right key:
rewriting MID or CID moves nothing, because both are contents of partitions,
while a different firmware gives the partitions that carry the records
different sizes. When nothing matches, the script stops before touching the
card and prints what it saw:

```
error: no section in targets.conf matches this device.
  observed: hboot:8192 sp1:10240 pg1fs:243646 board_info:32 ...
```

Paste that under a new `[name]` section, then fill in the offsets - those still
have to be derived by hand. Dump the small partitions and search for a value the
bootloader already reports:

```sh
for p in board_info mfg misc pg1fs pg2fs hboot sp1; do
	adb shell "su -c 'dd if=/dev/block/bootdevice/by-name/$p of=/sdcard/$p.img'"
	adb pull /sdcard/$p.img
done
```

The `su -c` assumes a Magisk ROM; drop it where `adb shell` is already root.

| field | key | place | on the M8 | how it was located |
|---|---|---|---|---|
| CID | `cid` | `board_info` p3 | 0x14, 8 chars ASCII | the `cidnum` string `fastboot getvar all` prints |
| MID | `mid` | `mfg` p5 | 0x4000, 18 bytes UTF-16LE | UTF-16LE encoding of the `modelid` string, 2 bytes per char |
| version | `version` | `misc` p24 | 0xA0, 16 bytes ASCII | the `version-main` string |
| tamper | `tamper` | `pg2fs` p6 | 0x511804, u32 LE | reads 4 while hboot says `Software status: Modified`, 0 when Official |
| secure | `secure` | `pg1fs` p2 | 0x8400, u32 LE | `03 00 00 00` on S-ON, `00 00 00 00` on S-OFF; confirmed by `readsecureflag` |
| BL lock | `blmagic` | `pg1fs` p2 | 0x8404, 4 chars | right after the flag: `HTCU` unlocked, `00000000` locked |
| red text | `hbootpart` | `hboot` p26 | run time | six known banner strings, searched per image |
| first screen | `splash` | `sp1` p12 | 0 | the frame starts at 0: W x H x 2 bytes |

`screen` is the only key without an offset: it sets the default WxH `splash`
converts to, and `hbootpart` gives the partition whose size bounds a noredtext
image.

Two rules when repeating this on another build:

- search for something the device already tells you (`cidnum`, `modelid`,
  `version-main`, the hboot status line) instead of guessing at offsets; the
  same value then confirms what you found.
- after every write, `sync` + `drop_caches` before reading back. A write that
  "succeeds" against a write-protected partition only updates the page cache -
  which is why `write_hex` verifies instead of trusting `dd`.

### 7. Build

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
loading fails with `no symbol version for <sym>` or
`disagrees about version of symbol <sym>`.

Sanity checks before pushing anything to the phone:

```sh
readelf -S kmod/pwrsq_on.ko | grep __versions    # 64 bytes, non-empty
strings kmod/pwrsq_on.ko | grep vermagic=
nm -u kmod/pwrsq_on.ko                           # prints nothing
```

`__versions` must contain exactly one entry (`module_layout`, 64 bytes in all).
If it is empty, the section never made it into the `.ko`: check that
`pwrsq_impl.h` still carries `section("__versions"), used`, and that you are
looking at the module you just built.

`build.sh` does not build the userspace helper; `tools/mmc_cmd` is not committed
either, it is a static ARM binary:

```sh
make -C tools CROSS=arm-none-linux-gnueabihf-
```

`soff` pushes it to `/dev` (tmpfs) and runs it as root. Without it `soff` stops
before touching the phone: the write-protection check is the only thing that
proves the power cycle worked.

### 8. Porting

The reference build is:

| item | value |
|---|---|
| device | HTC One M8, `m8_ul` |
| MID / CID as shipped | `0P6B62000` / `HTCCN703` |
| firmware tested | 6.31.1402.1, then 6.12.1540.4 (both Android 6.0.1) |
| kernel | `3.4.0-perf-ga6393e1` (Jan 2016) / `3.4.0-perf-g708019f` (Nov 2015) |
| hboot | `3.19.0.0000` |
| root | Magisk 20.1 (`su`), `modules_disabled=0` |

MID and CID are the values the phone shipped with; the reference unit was later
switched to `0P6B12000` / `11111111` and re-flashed with the Dev firmware, which
is why both builds appear above.

Two things have to match when moving to another device, and they fail
independently: the kernel side (struct layouts, symbol addresses) and the model
side (rail name, device name, offsets, partition names). The regulator name and
MMC platform device are compile-time parameters in `kmod/pwrsq_impl.h`.

Porting falls into four cases, A to D, ordered by how much has to be redone.
None of them was tested here.

**A. hboot before 3.19:** e.g. One M7 (msm8960), One S (msm8260A),
Sensation / XE (msm8260), Desire HD (msm8255), plus the B-tier devices that
have had few system updates. They may not set write protection at all: run
`mmc_cmd wp` while S-ON, and an all-zero bitmap means hboot never armed it. A
plain write is enough then, with neither the module nor the power cycle: derive
the partition, the offset and the record shape as in
[section 6](#6-parameter-offsets), put them in a `targets.conf` section, and
`stool.sh set secure 0` is that write - it probes the bitmap first and refuses
only if protection is really armed. One caveat there:
the four bytes after `03 00 00 00` read `HTCU` only while the bootloader is
unlocked, so a dump from a locked phone shows `00000000` and the pair is not a
reliable anchor. Confirm the candidate with `readsecureflag`.

**B. Same generation:** e.g. other M8 variants (dual-SIM, Sprint, Verizon),
One E8, Butterfly 2, One mini 2 - all off the same HTC 3.4 tree. The mechanism,
the structures and the record layout hold; only the board-level items need
re-checking:

* `TARGET_VREG` and `TARGET_MMC_DEV` stay `8941_l20` and `msm_sdcc.1`. Both are
  board strings, not driver names: `board-8974.c` registers the `sdhci-msm`
  device under the name `msm_sdcc.1`, and the rail name comes from
  `msm-pm8x41-rpm-regulator.dtsi`.
* The security record keeps its shape - `{u32 flag; char magic[4]}` at pg1fs
  0x8400, `03 00 00 00` in the first four on an S-ON device. The four after it
  are the bootloader lock magic, `HTCU` only while the bootloader is unlocked.
  Check those eight bytes before writing anything.
* `scripts/gen_addr.sh` plus a fresh `module_layout` crc is the whole job.

**C. Driver layer must be redone:** e.g. One M9 (msm8994), One M8s (msm8939),
Desire 816 / 610 (msm8928 / msm8926) - all on a different driver layer. The idea
still applies, but four things change at once, and each one can produce a
module that loads and then does the wrong thing:

1. `struct regulator` is private to `drivers/regulator/core.c`; the file carries
   a copy, and it must be re-copied from the target tree.
2. drvdata: this kernel stores `sdhci_host`; variants that bind the older
   `msm_sdcc` driver store their own host struct, and reading `->mmc` off it is
   garbage.
3. The rail name follows the PMIC, not the SoC.
4. Every offset in `targets.conf` has to be re-derived.

`pwrsq_diag.ko` exists to answer 2 and 3 from the device instead of from a
guess: it resolves the regulator, prints every consumer and the mmc_host it
found, and writes nothing.

**D. HTC 10 and later:** e.g. Desire 10 pro and the later models that still use
eMMC; nothing carries over unchanged. From the HTC 10 partition table on XDA
(thread 3374048): the bootloader is `aboot`; the parameter partitions move -
`board_info` at p1, `mfg` p2, `pg1fs` p3, `pg2fs` p4 (23.6 MB, about the same
as the M8); `sp1` at p21, 10 MB, on a 1440x2560 panel; by-name under
`/dev/block/platform/soc/7464900.sdhci/by-name`. `by-name` is the directory of
symlinks ueventd creates from the partition table, one per partition name - the
scripts resolve through it instead of hard-coding `mmcblk0pN`.

Porting to them, in order of severity:

1. `struct regulator` re-copied per branch - newer kernels differ from 3.4 and
   from each other.
2. drvdata: newer kernels store `sdhci_pltfm_host` and expect
   `pltfm_host->host`.
3. Every offset in `targets.conf` re-derived; only the pg1fs record is
   likely to keep its shape.

And from the U11 on, HTC ships UFS 2.1 instead of eMMC. There is no `mmcblk0`
and no CMD28/29/31 write-protect group, so the mechanism this tool is built on
does not exist on those phones regardless of how much of the rest is ported.

---

## How it works

### 1. The wall

The S-OFF state is one byte in the `pg1fs` partition:

| offset | meaning | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag (u32 LE) | `03 00 00 00` | `00 00 00 00` |
| `0x8404` | bootloader lock magic | `HTCU` unlocked / `00000000` locked | unchanged |

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
CMD31 -> aaaaaaaa2aaaaaaa
         8 bytes, 2 bits per group; 10b = power-on
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

The eMMC disappears, `mmcblk0*` vanish — and there is no way back except a
reboot. That is the wall.

### 3. The module

`kmod/pwrsq_impl.h` does four things:

1. **Resolve the regulator** — `regulator_get(NULL, "8941_l20")`.
   `struct regulator` is private to `drivers/regulator/core.c`, so the module
   carries a copy of the struct to reach `->rdev`.
2. **Call the driver ops directly** — `rdev->desc->ops->disable(rdev)` and later
   `->enable(rdev)`. This bypasses `_regulator_enable()` and therefore the
   `is_enabled()` short-circuit.
3. **Find the MMC host** — walk `rdev->consumer_list`, pick the entry whose
   device name is `msm_sdcc.1`, read its drvdata (which `sdhci_pltfm_init()`
   sets to the `sdhci_host`), and take `sdhci_host->mmc`.
4. **Ask for a rescan** — `mmc_detect_change(host, 0)` schedules `mmc_rescan()`,
   which re-runs the identification sequence.

Three build variants come from the same source: `diag` (stage 3, read only),
`off` (stage 1) and `on` (stage 2, which sleeps 1.5 s first so the rail
discharges before power is restored).

The log these produce is in [diagnostic](#diagnostic); the two lines that matter
here are `ops->disable ret=0` and `ops->enable ret=0` - they mean the driver ops
really ran instead of being short-circuited by the core.  The `mmc_reinit_card`
pair at the end is HTC's own re-initialisation path in `sdhci_msm`: the eMMC
comes back, with its partitions, without rebooting.

### 4. The write

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
```

`33792` is `0x8400`. Only the lowest byte changes (`03` -> `00`); the upper
three are already zero. The 4-byte magic at `0x8404` is the bootloader lock
state, not part of the flag - `HTCU` unlocked, `00000000` locked - and writing
the flag leaves it as it was. The read-back and the `drop_caches` that makes it
trustworthy are in [write flag](#write-flag); what matters here is that exactly
one byte moves.

There is a second 4-byte field at `pg1fs + 0x424` that the old
Firewater/Sunshine payload also writes. On this device it is **not** required:
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

## Expected output and troubleshooting

Every command in the order it runs, with the output that says it worked and the
failure that belongs to it.

### `stool.sh status`

```
== state ==
target  : m8  [htc_m8, hboot 3.19.*]
S state : S-ON  (secure_flag 3)
BL state: unlocked (pg1fs 0x8404 = HTCU (unlocked))

== parameters ==
CID       11111111     board_info @ 0x14
MID       0P6B12000    mfg @ 0x4000
version   6.12.1540.4  misc @ 0xa0
tamper    0            pg2fs @ 0x511804
secure    3            pg1fs @ 0x8400
BL lock   unlocked     pg1fs @ 0x8404

modules   0 (0 = allowed)
selinux   Enforcing
```

`target` is the `targets.conf` section that matched, and it is the first thing
to look at: `unknown - no targets.conf section matches` means the table has no
entry for this layout, and the `observed:` line under it is what to paste into a
new section ([section 6](#6-parameter-offsets)). `S state` has to read `S-ON`.
`unknown (no root ...)` means `su` does not work yet, and nothing below will
either. `modules` must be `0`; anything else and `insmod` is denied.
`selinux Enforcing` is not fatal - `soff` warns and carries on, and whether the
module loads depends on the domain `su` lands in. If it is denied,
`setenforce 0` for this boot and rerun.

### `gen_addr.sh`

```
wrote .../kmod/addr.h
/* Generated by scripts/gen_addr.sh - do not edit.
 * Kernel: Linux version 3.4.0-perf-g708019f ...
 */
#define A_REGULATOR_GET      0xc04033e0UL
#define A_DEV_GET_DRVDATA    0xc0482948UL
#define A_MMC_DETECT_CHANGE  0xc06aa7d4UL
#define A_PRINTK             0xc097da6cUL
#define A_MSLEEP             0xc01ba260UL

#define A_MODULE_LAYOUT_CRC  0x7d779921UL
```

All five addresses must be non-zero, and the `Kernel:` line must be the build
the phone is running now. A symbol that comes back unavailable means
`kptr_restrict` was not 0; the script prints both ways to set it.

### Build

```
pwrsq_diag: (no undefined symbols)
pwrsq_off: (no undefined symbols)
pwrsq_on: (no undefined symbols)
```

The three modules import nothing: every kernel function is reached through
`addr.h`. `build.sh` stops if `addr.h` is missing or still holds the
`0x00000000UL` placeholders. `make -C tools` leaves `tools/mmc_cmd` behind, and
`soff` refuses to start without it - that binary is the only way to tell
whether the power cycle worked.

### `soff`

`== state before ==` repeats the status lines above. The stages follow in the
order they print, each with the failure that stops it.

#### Backup

`== backup ==` - one size per partition on stderr, then the snapshot path:

```
  pg1fs        124746752 bytes
  board_info       16384 bytes
  mfg             262144 bytes
  pg2fs         24837120 bytes
  misc           1048576 bytes
saved: /path/to/repo/backup/20261102-231500.txt
```

Five whole partitions, about 144 MB and a minute over USB; the file layout is
in [the snapshot table](#stoolsh). A partition that cannot be read gives
`warning: could not dump <part>` and the run continues; a short image gives
`<part>: expected N bytes, got M`.

#### Diagnostic

```
== diagnostic (no side effects) ==
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` means the rail was found; `consumer 'msm_sdcc.1'` plus a
non-null `mmc_host` means the rescan path will work.
`Failed to create debugfs directory` is harmless (duplicate consumer dir).
`regulator 8941_l20 not found - wrong device/kernel?` means the module does not
match this kernel, and the run stops there.

#### Quiesce

`== quiesce ==` - `framework stopped, caches flushed`, after `stop`, a `sleep`
and two `sync` calls. The eMMC is about to lose power, so nothing may be
writing to it.

`/data` is mounted `errors=panic`: any write that reaches a dead eMMC panics.
The phone reboots by itself, the protection is re-armed and the flag is
untouched, so a panic here costs time and nothing else - fix the cause and
retry. To take `/data` out of the picture entirely, remount it read-only first:

```sh
adb shell 'su -c "mount -o remount,ro /data"'
```

ROMs that keep a loop-mounted `/su` answer `Device or resource busy`; then rely
on the `stop` + `sync` above.

#### Power cycle

`== power cycle ==` - `SEQ_DONE`. `dmesg | grep mmc_reinit_card` shows the
re-scan itself.

If `/dev/block/mmcblk0p2` does not come back the run stops with
`eMMC did not come back - hold power ~10s, then retry`. Nothing is permanently
damaged - the flag is only written in a later stage - so:

1. Wait 10 s: `mmc_detect_change()` runs on a workqueue.
2. `adb shell 'dmesg | tail -40'`. Look for `mmc_reinit_card`, `AUTO CMD err`,
   `Controller never released inhibit bit(s)`.
3. `adb shell 'insmod /dev/pwrsq_on.ko'` again; stage 2 is idempotent.
4. If adb is gone too, hold power ~10 s. The phone boots normally with the flag
   unchanged, and you can start over.

#### Write protection

```
== write protection ==
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

If any group is listed the run stops with
`eMMC write protection is still active - power cycle did not take effect`, and
nothing may be written in that state. If a write does go through but the byte
reads back unchanged, the write never reached the eMMC:

```sh
adb shell '/dev/mmc_cmd wp'                    # any non-zero group => still protected
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00` (bit 22, `WP_ERASE_SKIP`) - protection still active,
  the power cycle did not actually happen. `pwrsq: ops->disable ret=0` must
  appear in `dmesg`, and `cat /sys/kernel/debug/regulator/8941_l20/enable` must
  read 0 while the eMMC is gone.
* no `card status` error at all - you read back from the page cache. Always
  `sync` + `echo 3 > /proc/sys/vm/drop_caches` before verifying.

#### Write flag

`== write secure flag ==` - `pg1fs 0x8400 = 0`. It writes `00` and reads the 4
bytes back; the read-back follows `dd` + `sync` + `drop_caches`, so the value
came off the eMMC and not out of the page cache. A mismatch stops the run with
`read-back mismatch` - since the previous stage passed, that means the write did
not stick: see the two bullets above.

#### Verify

`== verify from bootloader ==` - `secure_flag: 0   security: off`, the phone
reboots into Android, and the last line is `done - S-OFF`. Both values are
asserted: `secure_flag is ..., expected 0` or `security is ..., expected off`
stops the run before `done`. Why this is the real proof:
[section 5](#5-why-it-stays-off).

### `son`

The same run in the other direction: `pg1fs 0x8400 = 3`, `secure_flag: 3`, and
`done - S-ON (write protection comes back on the next boot)`. This bootloader
check only warns - `expected 3, got ...` - because the flag has already been
written and read back by then.

### Restoring a backup

With S-OFF the firmware partitions are writable, so a restore is a plain `dd`.
Run it as root - on a Magisk ROM that means `su -c`, as everywhere else:

```sh
adb push backup/<ts>.pg1fs.img /dev/pg1fs.img
adb shell 'dd if=/dev/pg1fs.img of=/dev/block/bootdevice/by-name/pg1fs bs=1048576'
adb shell 'sync; rm -f /dev/pg1fs.img'
adb reboot bootloader && fastboot oem readsecureflag
```

Same for `board_info` (p3), `mfg` (p5), `pg2fs` (p6) and `misc` (p24).
Restoring `pg1fs.img` puts `0x8400` back to `03` — i.e. S-ON.

### Do not

* **`fastboot flash` a firmware partition.** On an S-ON device hboot verifies
  signatures on every one of them and refuses — that is the behaviour this tool
  works around, and also what protects you from a bad image.
* **Write anything in `pg1fs` other than `0x8400`.** The header at `0x400`
  describes three records (`security`, `simlock`, `simunlock`); the 4 bytes at
  `0x424`/`0x824`/`0xc24` are device-specific and were left untouched here on
  purpose.
* **Run the power cycle while `/data` is being written.** The panic is
  recoverable; a half-written ext4 journal is not always.

### If the phone will not boot at all

Enter the bootloader (volume down + power). If hboot comes up,
`fastboot getvar all`: still S-ON means nothing was modified and a normal ROM
flash recovers you; S-OFF with a dead Android can be fixed with any matching
RUU. If hboot does not come up, the problem is not in `pg1fs` - the S-OFF
procedure never touches `hboot`, `sbl1` or `tz`. `noredtext` is the one command
that writes `hboot`, and it keeps a dump.

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

Four things bite on Windows:

1. **Line endings.** A script saved with CRLF dies with
   `$'\r': command not found`. The repo pins `*.sh text eol=lf` in
   `.gitattributes`, so a fresh clone is fine; if you copy files around, run
   `sed -i 's/\r$//'`.
2. **Device paths.** MSYS rewrites absolute paths before `adb` sees them:
   `adb push x /data/local/tmp/x` arrives as
   `C:/Program Files/Git/data/local/tmp/x`. Prefix device paths with `//`
   (`//data/local/tmp/x`) to keep them literal; the scripts in this repo do.
3. **Host paths.** Git Bash understands `/d/...`; kbuild does not accept
   `D:/...` as `M=` because the colon looks like a make target separator. Pass
   MSYS paths to `scripts/build.sh`.
4. **PATH.** `adb`, `make` and `python3` must be visible from that shell. Git
   Bash does not bundle `make`; install MSYS2 or add it to `PATH`.

Toolchain actually used here: Git Bash, GNU Make 4.4.1 from MSYS2, Python 3.13,
adb 1.0.41, `arm-none-linux-gnueabihf-gcc` 13.3.1 (MinGW host build). The steps
in this README were executed as the equivalent raw commands;
`scripts/gen_addr.sh` was additionally run end-to-end.

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
bitmap: aa aa aa aa 2a aa aa aa      -> 10b = power-on
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

## Warnings

Intended for security research and maintenance on devices you own. Cutting power
to an eMMC while Android is running is not a supported operation.

* Remount `/data` read-only or stop the framework before the power cycle.
  `/data` is `errors=panic`; a write to a dead eMMC panics the kernel.
* If the eMMC does not re-enumerate, the phone will not boot until it is power
  cycled by hand. Nothing is lost, but you need physical access.
* `stool.sh backup` exists because "should not happen" is not a recovery plan.
  Keep the images on a PC, not on the phone.
* Writing `0x8400` is the last step and the only one that flips S-ON/S-OFF:
  `00` = S-OFF, `03` = S-ON, and it can be written back. What cannot be undone
  in place is a modified `hboot` (`noredtext`) — put the dumped image back
  before returning to S-ON.

No warranty of any kind; the authors are not responsible for data loss or
voided warranties. If you brick it, you own both halves.

---

## Credits

Substantial parts of the code and prose here were written with AI assistance.
Every address, offset, and verified claim was checked against a real device: the
experiments, the failure analysis and the decisions about what to keep are human
work.

* HTC for publishing the kernel source, and for the `mmc_reinit_card` path that
  makes the eMMC come back without a reboot.
* The XDA/ARHD community for the RUU/CID/MID knowledge this relies on.
* The Firewater/Sunshine era research for documenting what the S-OFF flag is.

---

## License

Copyright (C) 2026 the S-OFF-My-One-M8 contributors. Two licenses, split by what
a file is derived from:

| path | license | why |
|---|---|---|
| `kmod/`, `kernel-patches/` | GPL-2.0-only ([`kmod/LICENSE`](kmod/LICENSE), [`kernel-patches/LICENSE`](kernel-patches/LICENSE)) | kernel module and kernel patches; the 3.4 tree is v2-only |
| everything else: `tools/`, `scripts/`, `README*.md` | GPL-3.0-or-later ([`LICENSE`](LICENSE)) | userland programs and prose; nothing links them against kernel code, so the licence is a choice |

`kmod/` is a Linux kernel module. It includes GPL-2.0-only kernel headers,
carries a verbatim copy of `struct regulator` from `drivers/regulator/core.c`
and is loaded into a GPL-2.0-only kernel, so it is GPL-2.0-only as well —
GPL-3.0 cannot be used there, the two versions cannot be combined. It declares
`MODULE_LICENSE("GPL v2")`, which is the kernel's tag for v2-only; bare `"GPL"`
would mean v2-or-later. The userland side reaches the kernel only through
syscalls, so GPL-3.0-or-later is a choice, not a constraint.

Every source file starts with an `SPDX-License-Identifier` line, so the terms
are unambiguous per file; the table above is only an index. The
`_regulator_enable` excerpt in *How it works* is quoted from the kernel and
stays GPL-2.0.
