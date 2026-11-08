# S-OFF-My-One-M8

**English** | [中文](README.zh-CN.md)

Since Sunshine became unavailable, there has been no working HTC S-OFF tool.

Hboot protects the firmware partitions with the eMMC's power-on write
protection, which by design only clears on a real power cycle. Every
userspace route to cycle that rail is blocked, so the cycle is done from
kernel context with a small module that calls the PMIC regulator ops directly,
followed by writing the flag byte.

[Tested](#field-evidence) on the HTC One M8, hboot 3.19.0.0000
(other devices: see [Porting](#6-porting)).

---

## Requirements

* [Unlock bootloader](http://www.htcdev.com/bootloader/). Then root
  or flash a firmware that ships root. The kernel has to be able to load
  modules: e.g. LineageOS 17.1 for M8 is disabled. Temporary root like
  Sunshine without unlocking BL works too, once S-OFF the BL is yours.
* The kernel source your firmware was close to. HTC publishes the official
  ones on [htcdev.com](https://www.htcdev.com/devcenter/downloads).
* A cross toolchain and a host that can run kbuild: Linux, or MSYS2/Git Bash
  (see [Windows](#windows)).
* Data backup and [Building](#building).

---

## Quick start

The commands below assume `adb shell` is root: a userdebug or eng ROM, where
`adb root` works, or a rooted stock ROM, where every `adb shell ...` becomes
`adb shell 'su -c "..."'`. The quoting matters - the redirection has to sit
inside the su command, or the non-root shell performs it first and fails with
`Permission denied`. Every `stool.sh` command and `prepare.sh` finds root on its own
(Magisk `su`, adb root, or a userdebug build).
[Expected output and troubleshooting](#expected-output-and-troubleshooting).

```sh
# 0. check root, Security state, modules, SELinux
scripts/stool.sh status

# 1. phone config and addresses into the tree: m8.config, kmod/addr.h, and the
#    tree configured to match
scripts/prepare.sh /path/to/kernel-tree

# 2. build the three modules and the mmc_cmd helper
scripts/build.sh /path/to/kernel-tree
make -C tools CROSS=arm-none-linux-gnueabihf-

# 3. mount debugfs, back up, then diagnose, power cycle, write, verify
adb shell 'mount -t debugfs none /sys/kernel/debug'
scripts/stool.sh backup
scripts/stool.sh soff

# 4. write a saved partition image back
scripts/stool.sh restore pg2fs HT495WM00193-20261104-045201.pg2fs.img
```

---

## stool.sh

`scripts/stool.sh` is the entry point for every command below. Commands that
write (`set`, `lock`, `unlock`, `nowarn`, `splash`) check for Security state
before they dump or write anything, and stop with nothing written if S-ON.
`status` and `backup` only read, `restore` takes the partition from its
argument, and `soff`, `son` and `set secure_flag 0` are how the Security state
itself is changed, so none of those need S-OFF up front.

```sh
scripts/stool.sh status                  # Security state + other parameters (Android or fastboot)
scripts/stool.sh soff                    # full S-OFF: diag, power cycle, write, verify
scripts/stool.sh son                     # back to S-ON
scripts/stool.sh backup [partition]      # all four + parameters, or just one
scripts/stool.sh restore <partition> <file.img>   # e.g. restore pg2fs *.img
scripts/stool.sh set cid <cid>           # 8 chars, 11111111 = SuperCID
scripts/stool.sh set mid <mid>           # 9 chars, e.g. 0P6B12000
scripts/stool.sh set tamper_flag <0|4>   # 0 = Official, 4 = Modified
scripts/stool.sh set secure_flag <0|3>   # 0 = S-OFF, 3 = S-ON
scripts/stool.sh lock                    # BL magic -> HTCU
scripts/stool.sh unlock                  # BL magic -> 00000000
scripts/stool.sh nowarn                  # blank the six dev-warning lines in hboot
scripts/stool.sh splash photo.png        # first boot screen, size from targets.conf
```

Where each parameter lives, and which partitions get dumped, comes from
`targets.conf`: one section per partition layout, matched against the sizes the
device reports in `/sys/class/block/*/uevent`. A phone whose layout has no
section is refused before anything is written - see
[section 5](#5-parameter-offsets) to add one.

Nothing is backed up automatically:
`backup` writes `backup/<serial>-<timestamp>.{txt,img}` - five whole partitions
plus a txt that reproduces `status` and ends with one restore command per image
- and `restore` writes those images
back, `0x8400` among them. The flag inside the image wins, so restoring a set
taken while S-ON puts the phone back to S-ON. The only dumps taken without
asking are the ones `nowarn` and `splash` make of the single partition they
are about to overwrite; that dump is their undo path, nothing else.

`set tamper_flag` takes any decimal 0..255, standard values are `0` and `4`.
That u32 (four bytes, only the lowest non-zero) is the only input to hboot's `Software status:` line: `00` prints
`*** Software status: Official ***`, otherwise prints
`*** Software status: Modified ***`. The bootloader can read the same byte
back: `fastboot oem get_tamper_flag` answers `Tamper_Flag: 0x0`. It is not in
`getvar all`, only in the `oem ?` list.

`set secure_flag` is the write from the last stage of `soff`, on its own: `00` or
`03` at `0x8400`, then a read-back - no power cycle and no reboot. `00` while
S-ON is refused unless `mmc_cmd wp` reports no write protection, which is the
old-hboot case in [Porting](#6-porting); there it is the plain write that sets
the flag. On an S-OFF phone it is also what puts `00` back after restoring a
`pg1fs.img` that was taken while S-ON.

`lock` / `unlock` write the four bytes at `pg1fs` (p2)
0x8404 directly: `HTCU` = unlocked, `00000000` = locked. That is the same magic
hboot compares at boot, so once the device is S-OFF no htcdev-issued unlock
code is needed. `fastboot oem lock` is not used either — it only produces
`RELOCKED`, and hboot 3.19 has no `oem unlock` command at all
(`[ERR] Command error`).

What a M8's backup holds:

| file | content | size |
|---|---|---|
| `<serial>-<timestamp>.txt` | what `status` prints, plus a restore command per image | ~1 KB |
| `<serial>-<timestamp>.pg1fs.img` | p2 — the secure flag, BL magic lives here | 119 MB |
| `<serial>-<timestamp>.board_info.img` | p3 — CID, IMEI, board data lives here | 16 KB |
| `<serial>-<timestamp>.mfg.img` | p5 — MID lives here | 256 KB |
| `<serial>-<timestamp>.pg2fs.img` | p6 — the tamper flag lives here | 24 MB |

Names start with the serial (`ro.serialno`) and end with the timestamp, so two
M8s can share one `backup/` directory without getting mixed up. `restore`
refuses an image whose name carries another phone's serial.

The txt holds exactly what `status` prints: the `== state ==` block, which
carries `modules` and `selinux` too, then the `== parameters ==` block. Both come from the same
function (`status_show`), so the file and the screen cannot drift apart. It ends
with `== restore ==`, one line per image that actually landed, ready to copy:

```text
== restore ==
  stool.sh restore <partition> <file>   (bare filename = look in backup/)
  stool.sh restore pg1fs       HT495WM00193-20261105-215502.pg1fs.img
  stool.sh restore mfg         HT495WM00193-20261105-215502.mfg.img
```

Only partitions whose dump succeeded are listed, so no line points at a missing
file. A bare filename is looked up in `backup/`. `set cid` writes its 8 bytes at
`board_info` 0x14 with `dd`, like the rest; hboot reads it at boot, so
`getvar cidnum` changes only after a reboot. The whole p3 image is still kept -
the CID sits next to the IMEI and board data this tool never touches. Radio
(p20) is never written, so it is not dumped. The whole set is ~144 MB and takes
about a minute over USB.

### CID, MID and flashing

MID names the model variant - `0P6B62000` is the China Unicom M8, `0P6B12000`
the Dev Edition - and CID names the carrier or region (`HTCCN703` for China
Unicom). Both live in a package's `android-info.txt`, and hboot compares them
while parsing the zip in RUU mode. `set mid` writes mfg 0x4000, `set cid`
writes board_info 0x14. CID `11111111` (SuperCID) is accepted by most hboot
builds, but not all of them, and the firmware version can stop an RUU before
either check matters; see
[Flashing a 6.12 RUU from 4.18](#flashing-a-612-ruu-from-418). What each package
expects is listed in this
[sheet](https://docs.google.com/spreadsheets/d/10H7RftecZZKb5tT2zpShfYNFAfSe-imhhqtVfeMPVDA/edit?gid=0#gid=0).

#### Flashing a 6.12 RUU from 4.18

A Hong Kong 4.18.708.12 phone (hboot `3aa067db`) running the 6.12.1540.4 RUU
stops the moment Start is pressed, with Error 155. The RUU log
(`C:\RUU_log\RUU_*.log`) shows what happened:

```text
(bootloader) zip info parsing...
FAILED (status read failed (Too many links))
```

This is not a MID or CID mismatch. The log shows the tool read `boot-mode`,
`battery-status` and `version-main`, rebooted into RUU mode, sent the zip, and
died where hboot parses it.

The `rom.zip` inside the RUU exe is an HTC large-zip container; htc_fastboot
prints `found large-zip header` before sending. The 4.18 hboot only understands
plain zips, resets the USB endpoint when it meets the chunked structure, and the
host sees `Too many links`.

The way through is to flash a base firmware first (
`DevEdition_6.12.1540.4_+StockRecovery+boot.img_0p6bimg.zip`, about 53 MB,
holding hboot). Switch the hboot to `76df2b54`.

`fastboot flash hboot hboot_signedbyaa.img` is refused with
`FAILED (remote: not allowed)`, in FASTBOOT and RUU mode alike. The hboot
partition only accepts the zip path, never a raw image.

The firmware zip writes sbl1 and tz, so an interrupted flash bricks the phone.
Check the battery and leave the cable alone. `backup hboot` only helps while
hboot still reaches the bootloader; it cannot recover a phone that shows
nothing at all.

### Warning red text

The six dev-warning lines is drawn by hboot when a boot image fails its
signature check. Both `boot` and `recovery` are checked, and either one failing
paints the six lines.

On the 6.12.1540.4 hboot the six lines share one draw function at file offset
`0x18B64`, reached by exactly one `bl` instruction, `0x147EA`.  That instruction
sits inside the per-partition check, and the check entry `0xF51490C` has six
callers: two set mode `9` or `0x0F` and read `boot`, four set mode `3` and read
`recovery`.  Either failure executes the same `bl 0x18B64`; two of the recovery
entries are fastboot command handlers that answer `OKAY` first.

The instruction right before it is the image signature check at `0x147D4`: a zero
return boots straight on, a non-zero return enters the function, paints the six
lines, flushes the screen and then carries on booting.  The 4.18 `3aa067db` build
has the same shape - function `0x18258`, call site `0x142AE`, check at `0x14298`.

`nowarn` finds the six lines by content, not by a hard-coded offset.  It
dumps the whole 4 MB `hboot` partition, searches for the six strings, blanks
the first byte of each, writes them back and reads them back.  The offsets move
between builds - `0x8C340` on 6.12.1540.4, `0x8C3F8` on the 6.31.1402.1 dump,
`0x899CE` on the older m8_ul image - which is exactly why the search is dynamic.

Two things to know before running it:

- hboot carries the HTC signature; one changed byte kills it.  While S-OFF the
  SBL skips the check and the phone still boots.  The moment `son` writes the
  secure flag back to 3, the SBL verifies hboot again, fails, and stops: hboot
  never runs, so neither fastboot nor RUU comes up - only EDL is left.  Keep the
  `<serial>-<timestamp>.hboot.img` that `nowarn` prints and write it back with
  `restore hboot <stamp>.hboot.img` before running `son`. `son` checks the six
  strings first and refuses if they were blanked.
- These six strings are **not** unreferenced.  The draw function loads their
  addresses with a 16-bit `ldr rX, [pc, #imm]` plus `add rX, pc`: a small
  offset, then the current PC added.  That is why searching for a 32-bit
  absolute address finds nothing, though the draw function does exist - at
  `0x18B64` on 6.12.1540.4 and at `0x18258` on the 4.18 `3aa067db` build.
  Blanking the strings is still the smallest edit, because only one place draws
  them and the edit changes the text, not the control flow.

### First screen

`splash` converts a PNG into what the `sp1` partition actually holds:
little-endian RGB565 at the size `targets.conf` gives for the model - 1080x1920
on the M8, 4,147,200 bytes - and the rest of the partition is padding.  For a
model with a different panel, add its section to `targets.conf` with `screen` set
to the native resolution; `splash photo.png` then picks it up.  `--size=WxH` is
only a temporary override for when you do not want to touch the config.  The
frame size is checked against the partition size before anything is written: the
M8's `sp1` is 5,242,880 bytes, 1080x1920 fits at 4,147,200, and 1440x2560 at
7,372,800 is refused, so that size only suits models with a larger partition.

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
(Kernel Source Code). The package is named `m8ul-<uname -r>.zip` - for instance
`m8ul-3.4.0-perf-ga6393e1.zip`; take the one matching what your phone reports.
It contains `kernel570.tar.gz` (`kernel/`) and `platform.tar.gz` (the rest of the
tree). Only `kernel/` matters.

On Windows, NTFS is case-insensitive and the tree contains files that differ
only in case (`net/netfilter/xt_DSCP.c` vs `xt_dscp.c`). Either enable
per-directory case sensitivity (`fsutil file setCaseSensitiveInfo <dir> enable`,
needs admin) or extract with those paths excluded — they are netfilter drivers
and irrelevant here.

### 2. Phone to tree

```sh
scripts/prepare.sh /d/kernel-src/kernel
```

One command, six steps, each one printed:

| step | what it does | what stopping here means |
|---|---|---|
| 1 | `stool.sh backup boot` takes the boot partition | adb or root is not working, or the phone is in recovery |
| 2 | digs the compiled-in `.config` out of the image | the kernel was built without `CONFIG_IKCONFIG`, so the image holds none |
| 3 | writes the five addresses and the `module_layout` crc into `kmod/addr.h` | `kptr_restrict` is not 0, so kallsyms reads as zeros |
| 4 | computes the vermagic flags from the config and compares them with a stock module | the config is not from this phone's kernel |
| 5 | overwrites `kernel/.config`, runs `oldconfig`, counts new symbols | the tree is too far from this build (over 20 needs `--force`) |
| 6 | `modules_prepare`, then checks `utsrelease.h` | the toolchain - see the next section |

Things that are easy to get wrong:

- The config is not in `arch/arm/configs/m8_defconfig`: HTC ships many variants
  from one tree. The device's own config sits inside the kernel image
  (`CONFIG_IKCONFIG=y`, `CONFIG_IKCONFIG_PROC` off, so the phone has no
  `/proc/config.gz`). Step 2 unpacks the gzip stream behind the `IKCFG_ST`
  marker.
- Do not use the RUU's `boot_signed.img`: it carries a 256-byte signature header
  in front, so the boot header is read from the wrong offset. A partition dump is
  what you want, and `backup boot` is exactly that.
- In a zImage the compressed body is preceded by a self-decompressing stub, so
  gzip is not at offset 0. `extract_config.py` walks the magic instead, and names
  lz4/lzo/lzma when it finds one of those.
- `CONFIG_LOCALVERSION` is derived from `uname -r`: everything from the first
  dash onwards goes in, and `LOCALVERSION_AUTO` is turned off - a patched tree would otherwise pick
  up a `-dirty` suffix. It is not a load condition (next subsection), only a way
  to make the string inside the `.ko` match the phone when you read it.
- `addr.h` has nothing to do with the tree: it describes the kernel the phone is
  running right now, so it is re-read from the device whichever tree you use.
  That is why it happens here instead of by hand before the build.
- Run it while the phone boots normally. If boot was flashed after the last
  boot, the config you get and the symbols you read belong to different kernels.

`--force` only relaxes the step 5 threshold. The `ADB`, `CROSS` and `MAKE`
environment variables pick adb, the toolchain prefix and the make program. On
MSYS2 apply the two patches from section 3 first: `oldconfig` builds `fixdep`
before it does anything else.

#### When the tree is not the build the phone runs

That is the normal case: HTC ships one source package per firmware, and the
`gXXXXXXX` in the phone's kernel string is that package's git commit. Whether a
tree can be used does **not** depend on the version string; three things have to
line up:

| must match | decided by | what happens otherwise |
|---|---|---|
| the vermagic flags (`SMP preempt mod_unload modversions ARMv7`) | the tree's `.config` | `insmod` refuses the module |
| field offsets in `struct device` / `sdhci_host` / `mmc_host` | the tree's headers + `.config` | it loads, then reads the wrong bytes |
| the five addresses and the `module_layout` crc | the phone's `addr.h` | nothing - they do not come from the tree |

The first row is now a comparison that happens before you build: step 4 derives
the flag string from `.config` and checks it against a stock module from the
phone, character for character. If it does not match, the script stops instead of
letting you wait twenty minutes to find out `insmod` refuses. The reason is that
`same_magic()` compares only that half: when the module carries `__versions`,
everything before the first space - `UTS_RELEASE` - is skipped.

The second row only gets an indirect signal: the `(NEW)` count from step 5. Zero
means the two symbol tables agree, so the structs probably do too; a wall of them
means the tree is far off, and over 20 the script wants `--force` before it
continues.

The third row is re-read every run, so it always describes the current kernel -
`addr.h` is in `.gitignore` and should never travel between devices.
`A_MODULE_LAYOUT_CRC` comes out of `__versions` of a stock module
(`scripts/get_module_layout_crc.py`): the crc genksyms computed for
`module_layout` when that kernel was built, which cannot be guessed.

The real acceptance test for the second row needs a built module; it is at the
end of [3. Build](#3-build). Only `name=8941_l20` counts as a pass.

If it fails, change the tree - do not push it. A tree that is too far off gets
defaults for the new symbols from `oldconfig`, and the structs it compiles can be
missing fields. That failure is invisible at `insmod` and surfaces at
`regulator_get` or when writing through `ops`. The diagnostic run is the last
cheap check before the power cycle.

Step 6 also prints whether `UTS_RELEASE` lines up with `uname -r`. A mismatch
does not stop the load (that half is skipped, as above), but it means
`CONFIG_LOCALVERSION` never made it into the config.

### 3. Build

`build.sh` reads `kmod/addr.h`, which step 3 of the previous section wrote; without
it the script stops. It does not read a partition, and it does not talk to the
phone.

```sh
scripts/build.sh /path/to/kernel-tree
# On Windows/MSYS2 pass a MSYS path (/d/kernel-src/kernel), not D:/...
# kbuild passes M= to make, and a drive-letter colon breaks the target.
```

After linking it runs three checks of its own, and exits non-zero if any fails:

```
pwrsq_diag: (no undefined symbols), __versions 64 bytes, 1 entry
pwrsq_off: (no undefined symbols), __versions 64 bytes, 1 entry
pwrsq_on: (no undefined symbols), __versions 64 bytes, 1 entry
vermagic: 3.4.0-perf-g708019f SMP preempt mod_unload modversions ARMv7
```

- **undefined symbols**: the modules import nothing, so every symbol listed there
  makes the kernel demand a version crc, and the load fails with
  `no symbol version for <sym>` or `disagrees about version of symbol <sym>`.
- **`__versions`**: exactly one `module_layout` entry, 64 bytes in all (that is
  `struct modversion_info` on a 32-bit kernel). An empty section still links and
  only fails on the phone - when it does, check that `pwrsq_impl.h` still carries
  `section("__versions"), used`.
- **vermagic**: the string is compared with the kernel recorded in `addr.h`; a
  mismatch means the `.ko` came from another build, or the tree is still not the
  one the phone runs.

All three use the `${CROSS}`-prefixed binutils (`nm`, `readelf`, `strings`). Git
Bash and MSYS2 have no bare `readelf`, `nm` or `strings` - only a Linux
distribution does - so inspecting a module by hand needs the prefix too, or you
get `command not found` instead of a pass.

`build.sh` does not build the userspace helper; `tools/mmc_cmd` is not committed
either, it is a static ARM binary:

```sh
make -C tools CROSS=arm-none-linux-gnueabihf-
```

`soff` puts it in `/dev` (tmpfs) and runs it as root - `adb push` cannot write
there, so it lands in `/data/local/tmp` first and root copies it across while
the eMMC is still up. Without it `soff` stops
before touching the phone: the write-protection check is the only thing that
proves the power cycle worked.

#### Acceptance: the diagnostic module

This is the only cheap proof that the struct offsets are right:

```sh
adb push kmod/pwrsq_diag.ko //data/local/tmp/
adb shell 'su -c "dmesg -c >/dev/null; insmod /data/local/tmp/pwrsq_diag.ko; sleep 1; dmesg | grep pwrsq"'
adb shell 'su -c "rmmod pwrsq_diag"'
```

Only `name=8941_l20` counts as a pass. That one call exercises all five addresses
plus `r->rdev`, `rdev->desc->ops`, `consumer_list`, `d->kobj.name`, `drvdata` and
`sh->mmc`. If SELinux denies the load, `setenforce 0` for this boot and retry -
this is also the last cheap check before the power cycle.

### 4. Toolchain workarounds

A 2016 kernel built with a modern toolchain on MSYS2 hits five things. All of
them are in `kernel-patches/`. When step 5 or 6 of `prepare.sh` or the build in
the previous section fails, look here first.

| symptom | fix |
|---|---|
| `scripts/gcc-wrapper.py` is Python 2 (`print "..."`) | override `CC=` so the wrapper is skipped |
| `fatal error: linux/compiler-gcc13.h: No such file` | copy `compiler-gcc4.h` to `compiler-gcc13.h` |
| `fixdep: error opening config file:` and random parse errors | MinGW gcc writes `.d` files with CRLF; patch fixdep to skip `\r` |
| `fixdep` segfaults on MSYS2 | replace its `mmap()` with `malloc()+read()` |
| `multiple definition of 'yylloc'` building dtc | `HOSTCFLAGS=-fcommon`; `prepare.sh` already passes it |

```sh
cd kernel
patch -p1 < ../kernel-patches/0001-fixdep-crlf-and-no-mmap.patch
cp ../kernel-patches/compiler-gcc13.h include/linux/
```

HTC ships a tarball, not a git tree, so this is `patch -p1` rather than
`git apply`.

The wrapper is only used because the top Makefile sets
`CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`; passing `CC=<cross>gcc` on
the command line overrides it. On Linux with an old toolchain none of this is
needed — the fixdep patch is still harmless.

### 5. Parameter offsets

`kmod/addr.h` covers the kernel symbols; the parameter offsets are generated by
nothing either. They follow the partition layout, so they live in
`targets.conf`.

The section is chosen by comparing its `layout` line against the sizes the
device reports in `/sys/class/block/*/uevent` (`PARTNAME` plus `size`, in
512-byte sectors, world-readable and no root needed). Size is the right key:
rewriting MID or CID moves nothing, because both are contents of partitions,
while a different firmware gives the partitions that carry the records
different sizes. When nothing matches, the script stops before touching the
eMMC and prints what it saw:

```
error: no section in targets.conf matches this device.
  observed: hboot:8192 sp1:10240 pg1fs:243646 board_info:32 ...
```

Paste the part after `observed:` - starting at `hboot:8192` - as `layout =`
in a new `[name]` section, then fill in the offsets; those still have to be
derived by hand. Dump the small partitions and search for a value the
bootloader already reports:

```sh
for p in board_info mfg pg1fs pg2fs hboot sp1; do
	scripts/stool.sh backup "$p"
done
```

`backup` needs only the partition name - the name and the size both come from
the device, so it wants no `targets.conf` section, which is the point here:
that section does not exist yet. Images land in
`backup/<serial>-<timestamp>.<part>.img`, each checked against the length the
phone reports. If the script cannot run on that phone, fall back to
`adb shell 'su -c "dd if=/dev/block/bootdevice/by-name/<part> of=/sdcard/<part>.img"'`
plus `adb pull`; the `su -c` assumes a Magisk ROM and can be dropped where
`adb shell` is already root.

| field | key | location on the M8 | offset and width on the M8 | how it was located |
|---|---|---|---|---|
| CID | `cid` | `board_info` p3 | 0x14, 8 bytes ASCII | the `cidnum` string `fastboot getvar all` prints |
| MID | `mid` | `mfg` p5 | 0x4000, 18 bytes UTF-16LE | the `modelid` string `fastboot getvar all` prints, 2 bytes per char |
| tamper flag | `tamper_flag` | `pg2fs` p6 | 0x511804, 4 bytes u32 LE | non-zero (normally 4) while hboot says `Software status: Modified`, 0 when Official |
| secure flag | `secure_flag` | `pg1fs` p2 | 0x8400, 4 bytes u32 LE | `03 00 00 00` on S-ON, `00 00 00 00` on S-OFF; confirmed by `readsecureflag` |
| BL magic | `bl_magic` | `pg1fs` p2 | 0x8404, 4 bytes ASCII | right after the secure flag: `HTCU` unlocked, `00000000` locked |
| warning | `bl_partition` | `hboot` p26 | run time, no fixed offset | six known banner strings, searched per image |
| first screen | `splash` | `sp1` p12 | 0, W x H x 2 bytes | the frame starts at 0 |

There is no version row: this tool neither reads nor writes the firmware
version (`version-main`), and it does not print the Android build either.

`screen` is the only key without an offset: it sets the default WxH `splash`
converts to, and `bl_partition` names the partition `nowarn` rewrites - `hboot`
here, `aboot` on other models - and its size is what bounds the image.

Two rules when repeating this on another build:

- search for something the device already tells you (`cidnum`, `modelid`,
  the hboot status line) instead of guessing at offsets; the
  same value then confirms what you found.
- after every write, `sync` + `drop_caches` before reading back. A write that
  "succeeds" against a write-protected partition only updates the page cache -
  which is why `write_hex` verifies instead of trusting `dd`.

### 6. Porting

The reference build is:

| item | value |
|---|---|
| device | HTC One M8, `m8_ul` |
| MID / CID as shipped | `0P6B62000` / `HTCCN703` |
| firmware tested | 6.31.1402.1, then 6.12.1540.4 (both Android 6.0.1) |
| kernel | `3.4.0-perf-ga6393e1` (Jan 2016) / `3.4.0-perf-g708019f` (Nov 2015) |
| hboot | `3.19.0.0000` |
| root | Magisk 20.1 (`su`), `modules_disabled=0` |
| 32 GB test unit | 4.18.708.12 (S-ON), hboot `3aa067db`, Magisk 20.1, 61071360-sector eMMC |

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
[section 5](#5-parameter-offsets), put them in a `targets.conf` section, and
`stool.sh set secure_flag 0` is that write - it probes the bitmap first and refuses
only if protection is really armed. One caveat there: the four bytes after
`03 00 00 00` read `HTCU` only while the bootloader is unlocked, so a dump from
a locked phone shows `00000000` and the pair is not a reliable anchor. Confirm
the candidate with `readsecureflag`.

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

The S-OFF state is a 4-byte little-endian u32 at `pg1fs 0x8400`:

| offset | meaning | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag (u32 LE) | `03 00 00 00` | `00 00 00 00` |

`fastboot oem readsecureflag` reads exactly this value, and `getvar all` derives
`version-misc: PVT SHIP S-ON/S-OFF` and `security: on/off` from it.

The 4 bytes at `0x8404` are a separate field - the bootloader lock state, `HTCU`
unlocked or `00000000` locked. It does not follow the Security state: an S-ON
phone can be unlocked, and `lock`/`unlock` change nothing else.

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

Protection is not per partition but per **write protect group**, and the eMMC
decides how big a group is. `mmc_cmd extcsd` reads the fields that settle it:

```
  [221] HC_WP_GRP_SIZE     = 16
  [224] HC_ERASE_GRP_SIZE  = 1
  erase group  0.5 MiB
  wp group     8.0 MiB
  32 groups    256 MiB of 14910 MiB (1.7%)
```

8 MiB per group and CMD31 reports 32 of them, so this bitmap can describe at most
the first 256 MiB. Measured on an S-ON M8, that bitmap is **not** what the eMMC
obeys: it says 31 of the 32 groups are protected, yet a byte written at 120 MiB
lands and one written at 315 MiB comes back `card status 0x400d00` and never
reaches the eMMC. `WP_GRP_ENABLE = 0` says the same thing from the other side:
the group mechanism is off, hboot protects ranges, and `mmc_cmd wp` is only good
as an all-or-nothing check.

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
pair at the end is HTC's own re-initialisation path in `sdhci_msm`: on the
reference build the eMMC comes back that way, with its partitions, without
rebooting.  The 32 GB phone with an 8 s cut does not take that path: the host
reports `runtime_error -110` first and the nodes appear a minute or two later,
see [Power cycle](#power-cycle).

### 4. Writing the flag

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
```

`33792` is `0x8400`. The field is four bytes, but it only ever holds `0` or
`3`, so the top three are always zero and going from S-ON to S-OFF changes just
the lowest one, `03` -> `00`; that `dd` writes only that single byte. The tool
writes all four (`set secure_flag 0` reports `4+0 records`), which also clears
any stale high byte. The 4-byte magic at `0x8404` is the bootloader lock state,
not part of the flag - `HTCU` unlocked, `00000000` locked - and writing the flag
leaves it as it was. The read-back and the `drop_caches` that makes it
trustworthy are in [write flag](#write-flag).

There is a second 4-byte field at `pg1fs + 0x424` that the old
Firewater/Sunshine payload also writes. On this device it is **not** required:
the partition head (0..0x1000, including `0x424`) stayed byte-identical to the
pre-change backup after a successful S-OFF, and the phone booted normally. Leave
it alone.

For any other offset, without going through `set`:

```sh
# read 4 bytes at 0x8400 (33792)
adb shell 'dd if=/dev/block/bootdevice/by-name/pg1fs bs=1 skip=33792 count=4 2>/dev/null' | od -An -tx1

# write 4 bytes
printf '\0\0\0\0' > /tmp/x.bin
adb push /tmp/x.bin //data/local/tmp/x.bin
adb shell 'dd if=/data/local/tmp/x.bin of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=4; sync'
```

Use 4 KB alignment for larger reads: `bs=4096 skip=8 count=1` is 4 KB at offset
32768. Toybox `dd` disables `conv=notrunc` and answers `conv option disabled`;
leave it out for block devices, it cannot truncate a partition. After a write,
`sync`, then `echo 3 > /proc/sys/vm/drop_caches`, then read back, or you may get
the page cache. `hex_at` and `write_hex` in the script do exactly this.

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

Each step of the quick start in the order it runs: the output that says it
worked, and the failure that belongs to it.

### `stool.sh status`

```
== state ==
target: m8_ul
serial: HT495WM00193
hboot: 3.19.0.0000
Security: ON
BL state: unlocked
Software status: Official
modules: enabled
selinux: Enforcing
== parameters ==
CID         11111111    board_info @ 0x14
MID         0P6B12000   mfg @ 0x4000
BL magic    HTCU        pg1fs @ 0x8404
secure flag 3           pg1fs @ 0x8400
tamper flag 0           pg2fs @ 0x511804
```

This is a phone that already runs 1540 with a changed CID/MID but is still
S-ON, which is exactly the state `soff` wants.

`target` is the `targets.conf` section that matched - the section name is what
`fastboot getvar product` prints, `m8_ul` on this phone - and it is the first
thing to look at: `unknown - no targets.conf section matches` means the table has no
entry for this layout, and the `observed:` line under it is what to paste into a
new section ([section 5](#5-parameter-offsets)). The `hboot:` line below it is
the bootloader build the phone actually reports. `soff` wants
`Security: ON`; on an already S-OFF phone it prints `already S-OFF` and
returns. `Security: unknown (no root ...)` means `su` does not work yet, and
nothing below will either. `Software status` is the same line the bootloader
prints, taken from the `tamper_flag` u32: `0` is `Official`, anything else is
`Modified`. `modules: enabled` is `modules_disabled=0` spelled as the capability
it grants; `disabled` and `insmod` is refused. `selinux: Enforcing` is not fatal
- `soff` warns and carries on, and whether the module loads depends on the domain
`su` lands in. If it is denied, `setenforce 0` for this boot and rerun.

### `gen_addr.sh`

The block below comes from another machine (`g708019f`); addresses and the crc
change with the build, so do not copy them:

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
`addr.h`. `build.sh` stops if `addr.h` is missing - nothing else writes it
except `gen_addr.sh`, which `prepare.sh` runs. `make -C tools` leaves `tools/mmc_cmd` behind, and
`soff` refuses to start without it - that binary is the only way to tell
whether the power cycle worked.

### `backup`

```
  pg1fs        124746752 bytes
  board_info       16384 bytes
  mfg             262144 bytes
  pg2fs         24837120 bytes
/path/to/repo/backup/HT495WM00193-20261104-031826.txt
```

One line per partition on stderr, the txt path on stdout. The txt is written
after all four dumps and holds the `status` output plus a `== restore ==` block
listing only the partitions that landed. The whole set is
about 143 MB and takes roughly a minute over USB. A partition that cannot be
read gives `warning: could not dump <part>` and the run continues; a short image
gives `<part>: expected N bytes, got M`.

Name a partition and you get that one image instead, with no txt:

```sh
scripts/stool.sh backup hboot
  hboot         4194304 bytes
/path/to/repo/backup/HT495WM00193-20261104-072924.hboot.img
```

Any firmware partition can be dumped this way, not just the four. `system`,
`cache` and `userdata` are refused up front: those are Android's filesystems,
not firmware this tool touches. It needs no S-OFF - reading a partition never
does - and no `targets.conf` section either: the name and the size both come
from the device, so it works on a phone this tool has no offsets for.
`nowarn` and `splash` call it before they overwrite the partition they are
about to change.

### `soff`

`== state before ==` repeats the first four lines of `status` (`target`,
`Security`, `BL state`, `Software status`). The stages follow in the
order they print, each with the failure that stops it.

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

`/data` is mounted `errors=panic`: a write that reaches a dead eMMC raises I/O
errors and aborts the ext4 journal, and a panic is the worst case. If it does
panic, the phone reboots by itself, the protection is re-armed and the flag is
untouched, so it costs time and nothing else. On the 32 GB phone, 25 s with the
rail down did not panic: `JBD2: Detected IO errors` and an aborted journal, and
the next boot recovered. To take `/data` out of the picture entirely, remount it
read-only first:

```sh
adb shell 'su -c "mount -o remount,ro /data"'
```

ROMs that keep a loop-mounted `/su` answer `Device or resource busy`; then rely
on the `stop` + `sync` above.

#### Power cycle

`== power cycle ==` - `OFF_DONE`, the rail stays down for 8 s
(`PWRSQ_OFF_SEC` changes it), then `ON_DONE`. On the reference build
`dmesg | grep mmc_reinit_card` shows the re-scan; the 32 GB phone has no such
line, only `runtime_error -110`, see below.

Measured on the 32 GB phone: 1.5 s was not enough, the bitmap still listed 31
groups after the rail came back; 8 s cleared it. The longer the rail stays down,
the slower the host recovers - `pg1fs` can take one to two minutes to appear,
with `mmc0: err: runtime_error: -110` and `JBD2: Detected IO errors` on `/data`
in between. The script polls for about 2.5 minutes.

If the node never comes back the run stops with
`eMMC did not come back within ~2 min`. Nothing is permanently damaged - the
flag is only written in a later stage - so:

1. Wait one to two minutes: `mmc_detect_change()` runs on a workqueue, and after
   `runtime_error` the host waits for a PM timeout before retrying.
2. `adb shell 'dmesg | tail -40'`. Look for `runtime_error: -110` and
   `JBD2: Detected IO errors`.
3. Once the node is back, `adb reboot`: framework is still stopped, and a reboot
   is cleaner than `start` by hand.
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
adb shell 'su -c "/dev/mmc_cmd wp"'            # any non-zero group => still protected
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00` (bit 22, `WP_ERASE_SKIP`) - protection still active,
  the power cycle did not actually happen. `pwrsq: ops->disable ret=0` must
  appear in `dmesg`. With debugfs mounted as in the quick start,
  `/sys/kernel/debug/regulator/8941_l20/enable` exists and must read 0 while the
  eMMC is gone; without debugfs that path does not exist, and
  `ops->disable ret=0` plus the I/O errors are what you have. The module's
  `Failed to create debugfs directory` only means regulator core created that
  directory first.
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
stops the run before `done`.

### `son`

The same run in the other direction: `pg1fs 0x8400 = 3`, `secure_flag: 3`, and
`done - S-ON (write protection comes back on the next boot)`. This bootloader
check only warns - `expected 3, got ...` - because the flag has already been
written and read back by then.

### `restore`

```
== mfg ==
  mfg  262144 bytes  HT495WM00193-20261104-045201.mfg.img
  writing 262144 bytes to mfg
  64+0 records out
  262144 bytes transferred in 0.009 secs
  md5 e8301cf5c9c5873972846d54c7cd7040  ok
```

One partition, one file, and the partition is always named:

```sh
scripts/stool.sh restore mfg HT495WM00193-20261104-045201.mfg.img
```

Any firmware partition on the phone works, not only the six this tool writes.
`system`, `cache` and `userdata` are refused up front: those are Android's
filesystems, not firmware this tool touches. Before writing, it prints the
When the filename starts with a serial, that serial has to match the phone,
otherwise the run stops without writing a byte (old backups without the prefix
only get a note). What is left is
length: an image is one whole partition, so it has to be exactly that
partition's length, and the numbers come from the device
(`/sys/class/block/*/uevent`, the same probe that picks the `targets.conf`
section). A length that does not fit, a name the phone does not have, or a
partition that is not on its eMMC all stop the run before anything is written.
After the write, md5 of the image is compared with md5 read back from the
partition.

Like a backup, `restore` needs no `targets.conf` section: the name and the
length both come from the device, so it runs on a phone this tool has no offsets
for.

What decides whether it worked is the read-back, not the write. On an S-ON phone
the bootloader write-protects some partitions at the eMMC level; a write to one
of those is refused, `dd` still reports success, and the md5 comparison is what
catches it. `dmesg` shows `card status 0x400d00` for the refusal. S-OFF stops
arming that protection, but the command itself no longer insists on it.

Nothing else is touched: restoring `pg1fs` does not touch `hboot`, and vice
versa. `hboot` and `sp1` are restored the same way, which is why `nowarn` and
`splash` no longer carry their own `--restore` flags.

### Do not

* **`fastboot flash` a firmware partition.** While S-ON, hboot checks the
  signature of every one of them and refuses anything unsigned, which is also
  what stops you from writing a corrupt or wrong-model image. After S-OFF that
  check no longer runs, so `fastboot flash pg1fs ...` writes whatever you give
  it, whole.
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
procedure never touches `hboot`, `sbl1` or `tz`. `nowarn` is the only command
that changes what is inside `hboot`, and it keeps a dump first; `restore hboot`
also writes, but only puts your own image back.

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
adb 1.0.41, `arm-none-linux-gnueabihf-gcc` 13.3.1 (MinGW host build). `scripts/prepare.sh` ran end to
end on this phone (all six steps); it wrote both `kmod/addr.h` and
`kernel/.config`.

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

Identical, including the device-specific 4-byte field at `0x424`. Only the four
bytes at `0x8400` differ, and of those only the lowest one (`03` -> `00`).

**Re-checked 2026-11-08 on another `m8_ul` (kernel `3.4.0-perf-g708019f`).** The
diagnostic module, built against a tree that `prepare.sh` had configured, loaded
with:

```
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=84
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` is the pass condition: all five addresses resolved, and
`r->rdev`, `rdev->desc->ops`, `consumer_list`, `d->kobj.name`, `drvdata` and
`sh->mmc` all landed on the right fields. `use_count=84` is just how many
consumers `msm_sdcc.1` had at the time and differs per boot. The module was
removed with `rmmod` afterwards, and its file deleted from `/data/local/tmp`.

---

## Warnings

Intended for security research and maintenance on devices you own. Cutting power
to an eMMC while Android is running is not a supported operation.

* Remount `/data` read-only or stop the framework before the power cycle.
  `/data` is `errors=panic`; a write to a dead eMMC raises I/O errors, and a
  panic is the worst case.
* If the eMMC does not re-enumerate, the phone will not boot until it is power
  cycled by hand. Nothing is lost, but you need physical access.
* `stool.sh backup` exists because "should not happen" is not a recovery plan.
  Keep the images on a PC, not on the phone.
* Writing `0x8400` is the last step and the only one that flips S-ON/S-OFF:
  `00` = S-OFF, `03` = S-ON, and it can be written back. What cannot be undone
  in place is a modified `hboot` (`nowarn`) — put the dumped image back
  before returning to S-ON.

No warranty of any kind; the authors are not responsible for data loss or
voided warranties. If you brick it, you own both halves.

---

## Credits

Substantial parts of the code and prose here were written with AI assistance.
Every address, offset, and verified claim was checked against a real device;
what could not be tested is marked as such. The experiments, the failure
analysis and the decisions about what to keep are human work.

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
