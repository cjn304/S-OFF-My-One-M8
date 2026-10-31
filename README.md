# HTC-S-OFF-M8

True **S-OFF** for the HTC One (M8) on **hboot 3.19.0.0000** — the bootloader
version the community has treated as un-S-OFF-able since 2015.

The trick is not a new exploit in the usual sense. hboot protects the firmware
partitions with the eMMC's **power-on write protection**, which by design only
goes away on a real power cycle of the card. Every userspace route to cycle that
rail is blocked (the regulator core refuses to re-enable it, and the SDHCI
driver never cuts it). This project does the power cycle from kernel context
with a small module that calls the PMIC regulator ops directly, then writes the
one byte hboot reads.

```
before                          after
------                          -----
secure_flag: 3                  secure_flag: 0
PVT SHIP S-ON                   PVT SHIP S-OFF
security: on                    security: off
CMD31: aaaaaaaa2aaaaaaa         CMD31: 0000000000000000   <- hboot stops arming WP
```

## Verified on

| item | value |
|---|---|
| device | HTC One (M8), `m8_ul` |
| MID / CID | `0P6B62000` / `HTCCN703` |
| firmware | 6.31.1402.1, Android 6.0.1 (MMB29M) |
| kernel | `3.4.0-perf-ga6393e1` (stock HTC, Jan 2016) |
| hboot | `3.19.0.0000` |
| root | adbd as root, SELinux permissive, `modules_disabled=0` |

Other M8 variants with a stock 3.4 kernel should work the same way; the module
is parameterised by regulator name and MMC platform device name, but the symbol
addresses and the `module_layout` crc are properties of the exact kernel build
(see [docs/build.md](docs/build.md)).

## What you need

* The phone must be rooted (`adb shell id` -> `uid=0`) with SELinux permissive.
  A stock, unmodified phone cannot run this: you need kernel module loading.
* The **exact kernel source** for your build, prepared for out-of-tree modules.
  HTC publishes it at htcdev.com; for the 6.0.1 M8 build the tarball is
  `m8ul-3.4.0-perf-ga6393e1.zip`.
* A cross toolchain and a host that can run kbuild (Linux, or MSYS2 as
  documented in [docs/build.md](docs/build.md)).
* Patience and a backup. See the warning below.

## Quick start

```sh
# 0. backups first - pg1fs, board_info, mfg, radio, misc
scripts/backup.sh

# 1. read the symbol addresses and the module_layout crc from the phone
scripts/gen_addr.sh

# 2. build the three modules against your prepared kernel tree
scripts/build.sh /path/to/kernel-tree

# 3. make sure the plumbing is right (no side effects)
adb push kmod/pwrsq_diag.ko /dev/ && adb shell insmod /dev/pwrsq_diag.ko
adb shell dmesg | grep pwrsq      # must show rdev, "8941_l20" and a mmc_host

# 4. stop the framework, flush, then cut and restore VCC
adb shell 'stop; sleep 8; sync'
scripts/powercycle.sh

# 5. confirm the write protection is gone, then set the flag
adb push tools/mmc_cmd /dev/ && adb shell '/dev/mmc_cmd wp'   # expect all zeroes
scripts/write_flag.sh 0

# 6. verify from the bootloader
adb reboot bootloader && fastboot oem readsecureflag           # expect: 0
```

Full walkthrough with the exact expected output: [docs/usage.md](docs/usage.md).
How and why it works: [docs/how-it-works.md](docs/how-it-works.md).
Captured before/after output from the reference device: [docs/evidence.md](docs/evidence.md).
中文说明: [docs/zh-CN.md](docs/zh-CN.md).

## ⚠️ Warning

Cutting power to the eMMC while Android is running is **not** a supported
operation.

* Remount `/data` read-only or stop the framework before the power cycle.
  `/data` is mounted with `errors=panic`; a write to a dead card panics the
  kernel.
* If the card does not re-enumerate, the phone will not boot until it is power
  cycled by hand (hold power). Nothing is lost, but you need physical access.
* `scripts/backup.sh` exists because "should not happen" is not a recovery
  plan. Keep the images on a PC, not on the phone.
* Writing `pg1fs` is the point of the tool and also the only irreversible step.
  Offset `0x8400`: `00` = S-OFF, `03` = S-ON. Do not touch anything else in
  that partition.

No warranty. If you brick it, you own both halves.

## Repository layout

```
kmod/              the power-cycle module (three build variants + addr.h)
tools/             mmc_cmd: CMD31 write-protection query
scripts/           backup, address generation, build, power cycle, flag write
kernel-patches/    fixes needed to build a 3.4 tree with a modern toolchain
docs/              how it works, build notes, usage, recovery, 中文说明
```

## How it works, in one paragraph

hboot arms power-on write protection on the firmware groups of the eMMC at
every boot, which is why `dd` to `pg1fs` fails even as root. That protection is
latched in the card and cleared by a power cycle. The rail is PM8941 LDO20, but
the kernel's regulator core short-circuits `regulator_enable()` because
`->is_enabled()` reports "already on", and `sdhci_msm` marks the rail
`qcom,vdd-always-on` so nothing ever cuts it. `pwrsq` resolves the
`regulator_dev` by name, calls `desc->ops->disable()` and later
`desc->ops->enable()` directly (bypassing the core's bookkeeping), and asks the
MMC core to re-scan with `mmc_detect_change()`. With the card back and the
protection cleared, the secure flag at `pg1fs + 0x8400` can finally be written.

## Credits

* HTC for publishing the kernel source, and for the `mmc_reinit_card` path that
  makes the card come back without a reboot.
* The XDA/ARHD community for the RUU/CID/MID knowledge this relies on.
* `firewater`/Sunshine era research for documenting what the S-OFF flag
  actually is.

Licensed GPL-2.0. Kernel module code must match the kernel it links against.
