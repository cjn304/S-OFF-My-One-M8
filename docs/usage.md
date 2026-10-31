# Runbook

Everything below is what was actually executed on the reference device
(`m8_ul`, 6.31.1402.1, hboot 3.19.0.0000). Expected output is quoted so you can
tell a working step from a silent failure.

## 0. Pre-flight

```sh
adb shell id
# uid=0(root) gid=0(root) ... context=u:r:init:s0

adb shell getenforce
# Permissive

adb shell cat /proc/sys/kernel/modules_disabled
# 0

adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
adb shell 'mkdir -p /sys/kernel/debug; mount -t debugfs none /sys/kernel/debug'
adb shell 'ls /sys/kernel/debug/regulator/8941_l20/'
# consumers  enable  force_disable  mode  msm_sdcc.1-vdd  open_count  use_count  voltage
```

If `insmod` is missing or `modules_disabled` is 1, stop here: you need a rooted
ROM with module loading enabled.

## 1. Back up

```sh
scripts/backup.sh
# backing up to ./backup-20261101-012000
#   pg1fs       124746752 bytes
#   board_info  16384 bytes
#   mfg         262144 bytes
#   radio       ...
#   misc        1048576 bytes
```

Copy that directory to the PC and keep it. In particular `pg1fs.img` is your
undo for step 6.

## 2. Diagnose

```sh
adb push kmod/pwrsq_diag.ko /dev/
adb shell 'dmesg -c >/dev/null; insmod /dev/pwrsq_diag.ko; dmesg | grep pwrsq'
```

Expected:

```
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

* `name=8941_l20` — the rail was found. If this says something else, your
  `TARGET_VREG` is wrong.
* `consumer 'msm_sdcc.1'` and a non-null `mmc_host` — the rescan path will work.
* `Failed to create debugfs directory` is harmless (a duplicate consumer dir).

Remove it again with `adb shell rmmod pwrsq_diag`.

## 3. Quiesce the eMMC

The card is about to lose power. Nothing may be writing to it.

```sh
adb shell stop          # framework down; adbd stays up (class core)
adb shell 'sleep 8; sync; sync'
```

Optionally remount `/data` read-only:

```sh
adb shell 'for d in /mnt/runtime/*/emulated /data/media; do umount -l $d; done'
adb shell 'mount -o remount,ro /data'
```

On ROMs that keep a loop-mounted `/su` this fails with `Device or resource busy`
— then just make sure the framework is stopped and `sync` has run. `/data` is
mounted `errors=panic`, so a write during the outage panics the kernel.

## 4. Power cycle

```sh
scripts/powercycle.sh
```

What it does, in order: push `pwrsq_off.ko` and `pwrsq_on.ko` to `/dev`
(tmpfs!), `insmod` the off module, `insmod` the on module. The second one sleeps
1.5 s before restoring power, so the rail discharges and the card sees a real
power-on reset.

Expected:

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

If `/proc/partitions` shows no `mmcblk0`, the card did not come back: wait a few
seconds, then `adb shell 'ls /dev/block/mmcblk0*'`. Still nothing means a manual
power cycle is needed (hold power 10 s) — see [recovery.md](recovery.md).

## 5. Prove the write protection is gone

```sh
adb push tools/mmc_cmd /dev/ && adb shell chmod 755 /dev/mmc_cmd
adb shell '/dev/mmc_cmd wp'
```

Before the power cycle this prints groups 0..11 as `power-on`. Now it must be:

```
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

Do not continue if any group is still listed.

## 6. Write the flag

```sh
scripts/write_flag.sh 0
```

Expected:

```
before:
 03 00 00 00 48 54 43 55
after:
 00 00 00 00 48 54 43 55
```

The script does `dd` + `sync` + `drop_caches` before reading back, so the value
you see came off the card and not out of the page cache. That distinction
matters: a `dd` that "succeeds" against a write-protected card still updates the
cache.

## 7. Verify

```sh
adb reboot bootloader
fastboot oem readsecureflag
# (bootloader) secure_flag: 0

fastboot getvar all | grep -Ei 'secure|misc'
# (bootloader) version-misc: PVT SHIP S-OFF
# (bootloader) security: off
```

Then boot Android again and confirm that hboot no longer arms the protection:

```sh
adb shell '/dev/mmc_cmd wp'
# bitmap: 00 00 00 00 00 00 00 00
```

That last check is the real proof of S-OFF on this platform: the flag persists
because the protection is not re-applied, not because something patches it every
boot.

## Undo

```sh
scripts/write_flag.sh 3 && adb reboot bootloader && fastboot oem readsecureflag
```

`3` restores S-ON. The write protection comes back on the next boot, as does the
inability to write `pg1fs`. S-ON with an unlocked bootloader is a supported
state; S-ON with a modified `hboot` is not — flash a stock `hboot` first if you
ever replaced it.

## Notes

* Root is not lost by this procedure. The eMMC power cycle only affects the
  card; Android comes back with the same `/data`.
* If the phone boots but `/data` needs a journal replay, that is expected after
  an unclean power cut. It resolves itself on first mount.
* `Tamper_Flag` is unrelated to S-OFF and is not touched here.
