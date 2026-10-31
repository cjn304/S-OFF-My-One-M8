# Field evidence

Trimmed captures from the reference device. Serial and IMEI removed; everything
else is verbatim.

## Before

```
(bootloader) version-bootloader: 3.19.0.0000
(bootloader) version-main: 6.31.1402.1
(bootloader) version-misc: PVT SHIP S-ON
(bootloader) product: m8_ul
(bootloader) modelid: 0P6B62000
(bootloader) cidnum: HTCCN703
(bootloader) security: on
```

```
$ fastboot oem readsecureflag
(bootloader) secure_flag: 3
```

```
$ mmc_cmd wp
RSP=00000900 00000000 00000000 00000000
bitmap: aa aa aa aa 2a aa aa aa
  group 0  power-on
  ...
  group 11 power-on
```

`pg1fs` head:

```
00000000  50 47 46 53 00 7c 6f 07 20 00 00 00 00 00 f0 01   PGFS....
00000400  73 65 63 75 72 69 74 79 00 ...                      security
00000800  73 69 6d 6c 6f 63 6b 00 ...                      simlock
00000c00  73 69 6d 75 6e 6c 6f 63 6b 00 ...                  simunlock
00008400  03 00 00 00 48 54 43 55 00 00 00 00                ....HTCU
```

`dd` to `0x8400` returns 0 but changes nothing; `dmesg` shows
`card status 0x400d00` (`WP_ERASE_SKIP`, bit 22).

## During the power cycle

```
pwrsq: init stage=1
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: ops->disable ret=0
pwrsq: done
pwrsq: init stage=2
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
pwrsq: done
mmc0: sdhci_cmd_irq: AUTO CMD err sts 0x00000002
mmc0: mmc_blk_issue_rw_rq status 4 retry 0
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

## After

```
$ mmc_cmd wp
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

```
00008400  00 00 00 00 48 54 43 55 00 00 00 00                ....HTCU
```

```
$ fastboot oem readsecureflag
(bootloader) secure_flag: 0

(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

Two cold boots later:

```
$ fastboot oem readsecureflag
(bootloader) secure_flag: 0

$ mmc_cmd wp
bitmap: 00 00 00 00 00 00 00 00
```

The second `mmc_cmd` is the interesting one: hboot stopped arming the write
protection because the flag says S-OFF. Nothing re-applies it.

## Integrity of the rest of the partition

`md5` of `pg1fs[0x0000..0x1000]` before and after the procedure:

```
f22ff5ac41ac26e1a3ecd2997ba6ca3a   before (backup)
f22ff5ac41ac26e1a3ecd2997ba6ca3a   after
```

Identical — including the device-specific 4-byte field at `0x424`. Only
`0x8400` changed, which is why this tool writes exactly one byte.
