# HTC-S-OFF-M8

[English](README.md) | [中文](README.zh-CN.md)

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

Expected kernel log:

```
pwrsq: init stage=1
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: ops->disable ret=0
...
pwrsq: init stage=2
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: sdhci_cmd_irq: AUTO CMD err sts 0x00000002
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

That last pair is HTC's own re-initialisation path in `sdhci_msm`: the card is
back, with its partitions, without rebooting the phone.

### 4. The write

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
sync; echo 3 > /proc/sys/vm/drop_caches     # prove it came off the card, not cache
```

`33792` = `0x8400`. Only the low byte changes (`03` -> `00`); the tag at
`0x8404` is already `HTCU` on shipping devices.

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

## Requirements

* **Root** with module loading: `adb shell id` -> `uid=0`,
  `cat /proc/sys/kernel/modules_disabled` -> `0`, SELinux permissive.
* The **exact kernel source** of your build, prepared for out-of-tree modules.
  HTC publishes it on htcdev.com; for the 6.0.1 M8 build the tarball is
  `m8ul-3.4.0-perf-ga6393e1.zip`.
* A cross toolchain and a host that can run kbuild: Linux, or MSYS2/Git Bash on
  Windows (see [Windows](#windows)).
* Backups. See the warning at the bottom.

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

**Write protection check.** Before the cycle `mmc_cmd wp` lists groups 0..11 as
`power-on`. Now it must be:

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

That last check is the real proof: the flag persists because the protection is
not re-applied, not because something patches it every boot.

---

## Building

### 1. Get the source

HTC publishes it on htcdev.com (Kernel Source Code). For the 6.0.1 M8 build the
download is `m8ul-3.4.0-perf-ga6393e1.zip`, containing `kernel570.tar.gz`
(`kernel/`) and `platform.tar.gz` (the rest of the tree). Only `kernel/`
matters.

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

* `TARGET_VREG` and `TARGET_MMC_DEV` in `kmod/pwrsq_impl.h` name the rail and the
  MMC platform device. On other msm8974 HTC devices they are usually still
  `8941_l20` and `msm_sdcc.1`; verify with
  `/sys/kernel/debug/regulator/*/consumers`.
* Re-run `scripts/gen_addr.sh`; addresses and crc change with every kernel
  build.
* If the kernel has `CONFIG_MODULE_SIG_FORCE=y`, none of this works — the module
  must be signed with a key the kernel trusts.

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
scripts/           backup, address generation, build, power cycle, flag write
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
