/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * pwrsq - eMMC VCC power-cycle helper for HTC One M8 (msm8974, Linux 3.4)
 *
 * Forces the PM8941 LDO20 rail (eMMC VCC) off and back on, then asks the MMC
 * core to re-scan the card.  Necessary because the debugfs "enable" file
 * short-circuits when _regulator_is_enabled() reports "already on", so the
 * driver's ->enable() op is never reached after a force_disable.
 *
 * The module deliberately imports *no* kernel symbols: every function it calls
 * is taken from addr.h, generated from /proc/kallsyms on the target device.
 * That keeps it loadable on a kernel built with CONFIG_MODVERSIONS=y even
 * without the Module.symvers of that exact build.
 *
 * STAGE is selected at build time:
 *   1 = power OFF the rail
 *   2 = power ON the rail and trigger a card re-scan
 *   3 = diagnostic only (no side effects)
 *
 * Licensed GPL-2.0-only.  No warranty.  See README.md for the full procedure.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/list.h>
#include <linux/device.h>
#include <linux/regulator/driver.h>
#include <linux/mmc/host.h>
#include <linux/mmc/sdhci.h>

#include "addr.h"

#ifndef STAGE
#define STAGE 3
#endif

/* PMIC rail that supplies eMMC VCC on the M8 (PM8941 LDO20). */
#ifndef TARGET_VREG
#define TARGET_VREG "8941_l20"
#endif

/* Platform device of the eMMC host controller (sdhci-msm). */
#ifndef TARGET_MMC_DEV
#define TARGET_MMC_DEV "msm_sdcc.1"
#endif

/*
 * The kernel refuses to load a module built with CONFIG_MODVERSIONS unless the
 * module carries a __versions entry for "module_layout" whose crc matches the
 * one compiled into the kernel.  modpost cannot fill it in without the
 * Module.symvers of the exact build, so we supply it ourselves.  The value is
 * read from the __versions section of a stock module on the same device
 * (scripts/get_module_layout_crc.py).  It is a property of the kernel build,
 * not of this module.
 */
struct modversion_info_local {
	unsigned long crc;
	char name[64 - sizeof(unsigned long)];
};

static const struct modversion_info_local pwrsq_module_layout
__attribute__((section("__versions"), used)) = {
	.crc = A_MODULE_LAYOUT_CRC,
	.name = "module_layout",
};

#define LOG(...) \
	((int (*)(const char *, ...))A_PRINTK)(__VA_ARGS__)

/*
 * struct regulator is private to drivers/regulator/core.c; replicate it so we
 * can go from the consumer handle back to the regulator_dev.  Layout is fixed
 * for this kernel (same headers/config as the running build).
 */
struct regulator {
	struct device *dev;
	struct list_head list;
	int uA_load;
	int min_uV;
	int max_uV;
	int enabled;
	char *supply_name;
	struct device_attribute dev_attr;
	struct regulator_dev *rdev;
	struct dentry *debugfs;
};

static int s_eq(const char *a, const char *b)
{
	int i;

	if (!a || !b)
		return 0;
	for (i = 0; i < 64; i++) {
		if (a[i] != b[i])
			return 0;
		if (!a[i])
			return 1;
	}
	return 1;
}

/*
 * Find the mmc_host of the eMMC controller by walking the regulator's consumer
 * list.  mmc_regulator_get_supply() registers the host's parent device as a
 * consumer of this rail; sdhci_pltfm_init() stores the sdhci_host in that
 * device's drvdata, and sdhci_host->mmc is what mmc_detect_change() wants.
 */
static struct mmc_host *find_mmc_host(struct regulator_dev *rdev)
{
	struct regulator *c;

	list_for_each_entry(c, &rdev->consumer_list, list) {
		struct device *d = c->dev;
		struct sdhci_host *sh;
		void *drv;

		if (!d || !d->kobj.name)
			continue;
		LOG("pwrsq: consumer '%s'\n", d->kobj.name);
		if (!s_eq(d->kobj.name, TARGET_MMC_DEV))
			continue;
		drv = ((void *(*)(const struct device *))A_DEV_GET_DRVDATA)(d);
		if (!drv) {
			LOG("pwrsq: no drvdata on %s\n", d->kobj.name);
			continue;
		}
		sh = (struct sdhci_host *)drv;
		if (!sh->mmc) {
			LOG("pwrsq: drvdata has no mmc\n");
			continue;
		}
		return sh->mmc;
	}
	return NULL;
}

static int __init pwrsq_init(void)
{
	struct regulator *r;
	struct regulator_dev *rdev;
	struct mmc_host *host;
	int ret;

	LOG("pwrsq: init stage=%d\n", STAGE);

#if STAGE == 2
	/*
	 * Wait for the rail to discharge before powering it back up, otherwise
	 * the eMMC never sees a real power-on reset and the power-on write
	 * protection stays latched.
	 */
	((void (*)(unsigned int))A_MSLEEP)(1500);
#endif

	r = ((struct regulator *(*)(struct device *, const char *))
	     A_REGULATOR_GET)(NULL, TARGET_VREG);
	if (!r || ((unsigned long)r > 0xffff0000UL)) {
		LOG("pwrsq: regulator_get failed (%p)\n", r);
		return -ENODEV;
	}

	rdev = r->rdev;
	if (!rdev || ((unsigned long)rdev > 0xffff0000UL)) {
		LOG("pwrsq: bad rdev (%p)\n", rdev);
		return -ENODEV;
	}
	if (!rdev->desc || !rdev->desc->ops) {
		LOG("pwrsq: no desc/ops\n");
		return -ENODEV;
	}

	LOG("pwrsq: rdev=%p name=%s use_count=%d\n",
	    rdev, rdev->desc->name, rdev->use_count);

	host = find_mmc_host(rdev);
	LOG("pwrsq: mmc_host=%p\n", host);

#if STAGE == 1
	if (rdev->desc->ops->disable) {
		ret = rdev->desc->ops->disable(rdev);
		LOG("pwrsq: ops->disable ret=%d\n", ret);
	} else {
		LOG("pwrsq: no disable op\n");
	}
#endif

#if STAGE == 2
	if (rdev->desc->ops->enable) {
		ret = rdev->desc->ops->enable(rdev);
		LOG("pwrsq: ops->enable ret=%d\n", ret);
		((void (*)(unsigned int))A_MSLEEP)(300);
	} else {
		LOG("pwrsq: no enable op\n");
	}
	if (host) {
		((void (*)(struct mmc_host *, unsigned long))
		 A_MMC_DETECT_CHANGE)(host, 0);
		LOG("pwrsq: detect_change queued\n");
	} else {
		LOG("pwrsq: no mmc_host, cannot rescan\n");
	}
#endif

	LOG("pwrsq: done\n");
	return 0;
}

static void __exit pwrsq_exit(void)
{
	LOG("pwrsq: unloaded\n");
}

module_init(pwrsq_init);
module_exit(pwrsq_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("eMMC VCC power-cycle helper (HTC One M8)");
MODULE_AUTHOR("HTC-S-OFF-M8");
