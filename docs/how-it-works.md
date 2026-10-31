# How it works

## 1. The wall: hboot + eMMC power-on write protection

On the M8, the S-OFF state is one byte in the `pg1fs` partition:

| offset | meaning | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag (u32 LE) | `03 00 00 00` | `00 00 00 00` |
| `0x8404` | tag | `"HTCU"` | `"HTCU"` |

`fastboot oem readsecureflag` reads exactly this value, and `getvar all` derives
`version-misc: PVT SHIP S-ON/S-OFF` and `security: on/off` from it.

Writing it as root fails. The reason is not SELinux and not the filesystem: at
every boot hboot sets the eMMC's **power-on write protection** on the firmware
groups. `CMD31` (SEND_WRITE_PROT_TYPE) reports 2 bits per write-protect group:

```
00 = not protected   01 = temporary   10 = power-on   11 = permanent
```

A stock, booted M8 answers:

```
CMD31 -> 0000000000000000 aaaaaaaa2aaaaaaa
                            ^^^^^^^^^^^^^^^^  groups 0..11 = 10b = power-on
```

Power-on protection is, by definition, only cleared by a power cycle. `CMD29`
(CLEAR_WRITE_PROT) has no effect on it, and a normal `dd` to `pg1fs` comes back
with `card status 0x400d00` — bit 22, `WP_ERASE_SKIP`.

So the whole problem reduces to: **cut VCC to the eMMC and bring it back,
without rebooting the SoC.**

## 2. Why userspace cannot do that

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
3. **No rescan hook** — `sdhci` has no userspace "rescan" attribute. Unbinding
   the driver does not cut power either (the card is still fed), and
   `device_release_driver()` can block forever if a filesystem on that gendisk
   is still writable.

What *does* work from userspace is the first half only:

```sh
echo 1 > /sys/kernel/debug/regulator/8941_l20/force_disable   # VCC really drops
```

The card disappears, `mmcblk0*` vanish — and there is no way back except a
reboot. That is the wall.

## 3. The module

`kmod/pwrsq_impl.h` is deliberately tiny and does four things:

1. **Resolve the regulator** — `regulator_get(NULL, "8941_l20")`. `struct
   regulator` is private to `drivers/regulator/core.c`, so the module carries a
   copy of the struct to reach `->rdev`.
2. **Call the driver ops directly** — `rdev->desc->ops->disable(rdev)` and
   later `->enable(rdev)`. This bypasses `_regulator_enable()` and therefore
   the `is_enabled()` short-circuit entirely.
3. **Find the MMC host** — walk `rdev->consumer_list`, pick the entry whose
   device name is `msm_sdcc.1`, read its drvdata (which `sdhci_pltfm_init()`
   sets to the `sdhci_host`), and take `sdhci_host->mmc`.
4. **Ask for a rescan** — `mmc_detect_change(host, 0)` schedules
   `mmc_rescan()`, which re-runs the card identification sequence.

Three build variants are produced from the same source: `diag` (stage 3, read
only), `off` (stage 1) and `on` (stage 2, which sleeps 1.5 s first so the rail
actually discharges before power is restored).

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

`CMD31` after the cycle:

```
CMD31 -> 0000000000000000 0000000000000000
```

## 4. The write

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
sync; echo 3 > /proc/sys/vm/drop_caches     # prove it came off the card, not cache
```

`33792` = `0x8400`. Only the low byte has to change (`03` -> `00`); the tag at
`0x8404` is already `HTCU` on shipping devices.

There is a second 4-byte field at `pg1fs + 0x424` that the old `firewater`/Sunshine
payload also writes. On this device it is **not** required: the partition head
(0..0x1000, including `0x424`) stayed byte-identical to the pre-change backup
after a successful S-OFF, and the phone booted normally. Leave it alone.

## 5. Why the flag is the only thing that changes

After the reboot hboot reads `secure_flag = 0` and takes its S-OFF path — which
includes **not arming the power-on write protection**. That is why a second
`CMD31` on the S-OFF device returns all zeroes, and why `pg1fs` stays writable
from then on. The write protection was never "defeated"; it simply stopped being
set.

## 6. Why the module loads at all

The kernel is built with `CONFIG_MODVERSIONS=y` and we do not have its
`Module.symvers`. Two consequences, both handled:

* every imported symbol would need a matching crc — so the module imports
  **none**: all function addresses come from `/proc/kallsyms` at build time
  (`kmod/addr.h`);
* `module_layout` is checked unconditionally, so the module carries its own
  `__versions` entry with the crc copied from a stock `.ko` on the device.

Details, including the toolchain workarounds: [build.md](build.md).
