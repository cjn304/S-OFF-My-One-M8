# Recovery

The failure modes here are boring and recoverable, provided you have the
backups from `scripts/backup.sh`. Work through this in order.

## The card did not come back

Symptom: `SEQ_DONE` was printed, but `/proc/partitions` has no `mmcblk0` and
`/dev/block/mmcblk0*` is empty.

1. Wait 10 s. `mmc_detect_change()` queues the rescan on a workqueue; on a busy
   system it can take a moment.
2. `adb shell 'dmesg | tail -40'`. Look for `mmc_reinit_card`, `AUTO CMD err`,
   or `Controller never released inhibit bit(s)`.
3. `adb shell 'insmod /dev/pwrsq_on.ko'` again — stage 2 is idempotent and can
   be re-run.
4. If adb is gone too, the kernel is wedged: hold power ~10 s. The phone boots
   normally; the secure flag is unchanged and you can retry from step 3 of the
   runbook.

Nothing is permanently damaged by a failed power cycle — the flag is only
written in step 6.

## The kernel panicked

`/data` is mounted `errors=panic`, so any write that reaches a dead card panics.
The phone reboots by itself and comes back with the write protection re-armed
and the flag untouched. Fix the cause (stop the framework, `sync`, remount
`/data` read-only) and retry.

## `dd` reports success but the byte does not change

The write never reached the card. Check, in this order:

```sh
adb shell '/dev/mmc_cmd wp'          # any non-zero group => protection still on
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00` (bit 22, `WP_ERASE_SKIP`) — protection is still active.
  The power cycle did not actually happen: `pwrsq: ops->disable ret=0` must
  appear in `dmesg`, and `cat /sys/kernel/debug/regulator/8941_l20/enable` must
  read 0 while the card is gone.
* no card-status error at all — you read back from the page cache. Always
  `sync` + `echo 3 > /proc/sys/vm/drop_caches` before verifying.

## Restoring a backup

With S-OFF (the normal case after this procedure) the firmware partitions are
writable, so a restore is a plain `dd`:

```sh
adb push backup-.../pg1fs.img /dev/pg1fs.img
adb shell 'dd if=/dev/pg1fs.img of=/dev/block/bootdevice/by-name/pg1fs bs=1048576'
adb shell 'sync; rm -f /dev/pg1fs.img'
adb reboot bootloader && fastboot oem readsecureflag
```

The same works for `board_info` (p3), `mfg` (p5), `radio` (p20) and `misc` (p24).
Restoring `pg1fs.img` puts `0x8400` back to `03` — i.e. S-ON.

If you are S-ON and need to restore, the write protection will block you. Boot
TWRP and write from there only if the partition is not protected; otherwise you
need to redo the power cycle first.

## Do not

* **Do not `fastboot flash` a firmware partition.** hboot verifies signatures on
  every one of them and will refuse — that is the behaviour this tool exists to
  work around, and it is also what protects you from a bad image.
* **Do not write anything in `pg1fs` other than `0x8400`.** The header at
  `0x400` describes three records (`security`, `simlock`, `simunlock`); the 4
  bytes at `0x424`/`0x824`/`0xc24` are device-specific and were left untouched
  here on purpose.
* **Do not run the power cycle on a device that is writing to `/data`.** The
  panic is recoverable; a half-written ext4 journal is not always.

## If the phone will not boot at all

Enter the bootloader (volume down + power). If hboot comes up:

* `fastboot getvar all` — check `secure_flag`/`security`. If it still says
  S-ON, nothing was modified and a normal flash of your ROM recovers you.
* If it says S-OFF and Android does not boot, you can flash any RUU/firmware
  image for the matching MID without signature trouble, or restore the
  partition images above from a TWRP shell.

If hboot does not come up, the problem is not in `pg1fs` — this procedure never
touches `hboot`, `sbl1` or `tz`.
