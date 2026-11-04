/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * mmc_cmd - tiny MMC_IOC_CMD wrapper used to inspect eMMC write protection.
 *
 *   mmc_cmd wp [device]                 # CMD31: write-protect type bitmap
 *   mmc_cmd extcsd [device]             # CMD8: the write-protect fields and
 *                                       # how far the 32-group bitmap reaches
 *   mmc_cmd raw <op> <arg> <flags> <blksz> <blocks> <write> [device]
 *
 * "wp" is the interesting one: hboot arms power-on write protection on the
 * firmware partitions at every boot, and CMD31 is how you prove it is gone
 * after the power cycle.  Types are 2 bits per write-protect group:
 *
 *   00 = not protected   01 = temporary   10 = power-on   11 = permanent
 *
 * A fully protected 16 GB eMMC typically reports 0xaaaaaaaa2aaaaaaa.
 * After the power cycle it must read all zeroes.
 *
 * Build with tools/Makefile (static ARM binary), push to the phone and run as
 * root.  Licensed GPL-2.0.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/fs.h>

/* current layout (msm 3.4+, 72 bytes) */
struct mmc_ioc_cmd {
	int write_flag;
	int is_acmd;
	uint32_t opcode;
	uint32_t arg;
	uint32_t response[4];
	unsigned int flags;
	unsigned int blksz;
	unsigned int blocks;
	unsigned int postsleep_min_us;
	unsigned int postsleep_max_us;
	unsigned int data_timeout_ns;
	unsigned int cmd_timeout_ms;
	uint32_t __pad;
	uint64_t data_ptr;
};
#define MMC_IOC_CMD_NEW _IOWR(179, 0, struct mmc_ioc_cmd)

/* old layout (56 bytes) - fallback for older kernels */
struct mmc_ioc_cmd_old {
	int write_flag;
	int is_acmd;
	uint32_t opcode;
	uint32_t arg;
	uint32_t response[4];
	unsigned int flags;
	unsigned int blksz;
	unsigned int blocks;
	unsigned int data_timeout_ns;
	uint32_t __pad;
	uint64_t data_ptr;
};
#define MMC_IOC_CMD_OLD _IOWR(179, 0, struct mmc_ioc_cmd_old)

#define MMC_RSP_R1  0x15
#define MMC_CMD_ADTC 0x20
#define FLAGS_R1_ADTC (MMC_RSP_R1 | MMC_CMD_ADTC)

static unsigned char databuf[512];

static int do_cmd(const char *dev, uint32_t op, uint32_t arg, unsigned flags,
		  unsigned blksz, unsigned blocks, int write, uint32_t *rsp)
{
	struct mmc_ioc_cmd c;
	int fd, ret;

	if ((unsigned long)blksz * blocks > sizeof(databuf)) {
		fprintf(stderr, "data too big\n");
		return -1;
	}
	memset(databuf, 0, sizeof(databuf));

	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return -1;
	}

	memset(&c, 0, sizeof(c));
	c.opcode = op;
	c.arg = arg;
	c.flags = flags;
	c.blksz = blksz;
	c.blocks = blocks;
	c.write_flag = write;
	c.data_ptr = (uint64_t)(uintptr_t)databuf;

	ret = ioctl(fd, MMC_IOC_CMD_NEW, &c);
	if (ret < 0) {
		struct mmc_ioc_cmd_old o;

		memset(&o, 0, sizeof(o));
		o.write_flag = c.write_flag;
		o.opcode = c.opcode;
		o.arg = c.arg;
		o.flags = c.flags;
		o.blksz = c.blksz;
		o.blocks = c.blocks;
		o.data_ptr = c.data_ptr;
		ret = ioctl(fd, MMC_IOC_CMD_OLD, &o);
		if (ret < 0) {
			fprintf(stderr, "ioctl failed: %s\n", strerror(errno));
			close(fd);
			return -1;
		}
		memcpy(c.response, o.response, sizeof(o.response));
	}
	if (rsp)
		memcpy(rsp, c.response, sizeof(c.response));
	close(fd);
	return ret;
}

static void print_wp(const unsigned char *b, int n)
{
	static const char *type[4] = {"none", "temporary", "power-on", "permanent"};
	int i, prot = 0;

	printf("bitmap:");
	for (i = 0; i < n; i++)
		printf(" %02x", b[i]);
	printf("\n");

	for (i = 0; i < n * 4; i++) {
		int t = (b[i / 4] >> ((i % 4) * 2)) & 3;

		if (!t)
			continue;
		printf("  group %-2d %s\n", i, type[t]);
		prot++;
	}
	if (!prot)
		printf("  -> no write protection at all\n");
}

/* EXT_CSD byte offsets, from include/linux/mmc/mmc.h (JEDEC JESD84-B51) */
#define X_WP_GRP_ENABLE        31
#define X_BOOT_WP             173
#define X_ERASE_GROUP_DEF     175
#define X_REV                 192
#define X_HC_WP_GRP_SIZE      221
#define X_HC_ERASE_GRP_SIZE   224

static void print_extcsd(const char *dev)
{
	unsigned en = databuf[X_WP_GRP_ENABLE];
	unsigned boot_wp = databuf[X_BOOT_WP];
	unsigned def = databuf[X_ERASE_GROUP_DEF];
	unsigned hcwp = databuf[X_HC_WP_GRP_SIZE];
	unsigned hcer = databuf[X_HC_ERASE_GRP_SIZE];
	double erase_kb = 512, grp_kb, win_mb;
	unsigned long long card = 0;
	int fd;

	printf("ext_csd:\n");
	printf("  [%3d] REV                = %u\n", X_REV, databuf[X_REV]);
	printf("  [%3d] BOOT_WP            = 0x%02x\n", X_BOOT_WP, boot_wp);
	printf("  [%3d] ERASE_GROUP_DEF    = %u\n", X_ERASE_GROUP_DEF, def);
	printf("  [%3d] WP_GRP_ENABLE      = %u\n", X_WP_GRP_ENABLE, en);
	printf("  [%3d] HC_WP_GRP_SIZE     = %u\n", X_HC_WP_GRP_SIZE, hcwp);
	printf("  [%3d] HC_ERASE_GRP_SIZE  = %u\n", X_HC_ERASE_GRP_SIZE, hcer);

	if (def && hcer)
		erase_kb = hcer * 512.0;
	/* one write protect group = HC_WP_GRP_SIZE x erase group */
	grp_kb = (hcwp ? hcwp : 1) * erase_kb;
	win_mb = grp_kb * 32 / 1024;

	fd = open(dev, O_RDONLY);
	if (fd >= 0) {
		if (ioctl(fd, BLKGETSIZE64, &card) == 0)
			card /= 1024 * 1024;
		close(fd);
	}

	printf("  erase group  %.1f MiB\n", erase_kb / 1024);
	printf("  wp group     %.1f MiB\n", grp_kb / 1024);
	printf("  32 groups    %.0f MiB", win_mb);
	if (card)
		printf(" of %llu MiB (%.1f%%)", card, 100.0 * win_mb / card);
	printf("\n");
	if (!en)
		printf("  note: WP_GRP_ENABLE = 0, the card itself reports no groups\n");
}

int main(int argc, char **argv)
{
	const char *dev = "/dev/block/mmcblk0";
	uint32_t rsp[4] = {0};

	if (argc >= 2 && !strcmp(argv[1], "wp")) {
		if (argc >= 3)
			dev = argv[2];
		if (do_cmd(dev, 31, 0, FLAGS_R1_ADTC, 8, 1, 0, rsp) < 0)
			return 1;
		printf("RSP=%08x %08x %08x %08x\n", rsp[0], rsp[1], rsp[2], rsp[3]);
		print_wp(databuf, 8);
		return 0;
	}

	if (argc >= 2 && !strcmp(argv[1], "extcsd")) {
		int dump = 0, i;

		if (argc >= 3 && !strcmp(argv[2], "dump")) {
			dump = 1;
			if (argc >= 4)
				dev = argv[3];
		} else if (argc >= 3) {
			dev = argv[2];
		}
		if (do_cmd(dev, 8, 0, FLAGS_R1_ADTC, 512, 1, 0, rsp) < 0)
			return 1;
		print_extcsd(dev);
		if (dump)
			for (i = 0; i < 512; i += 16) {
				int j;

				printf("  %3d:", i);
				for (j = 0; j < 16; j++)
					printf(" %02x", databuf[i + j]);
				printf("\n");
			}
		return 0;
	}

	if (argc >= 8 && !strcmp(argv[1], "raw")) {
		dev = (argc >= 9) ? argv[8] : dev;
		if (do_cmd(dev, (uint32_t)strtoul(argv[2], 0, 0),
			   (uint32_t)strtoul(argv[3], 0, 0),
			   (unsigned)strtoul(argv[4], 0, 0),
			   (unsigned)strtoul(argv[5], 0, 0),
			   (unsigned)strtoul(argv[6], 0, 0),
			   atoi(argv[7]), rsp) < 0)
			return 1;
		printf("RSP=%08x %08x %08x %08x\n", rsp[0], rsp[1], rsp[2], rsp[3]);
		return 0;
	}

	fprintf(stderr,
		"usage:\n"
		"  %s wp [device]\n"
		"  %s extcsd [dump] [device]\n"
		"  %s raw <op> <arg> <flags> <blksz> <blocks> <write> [device]\n",
		argv[0], argv[0], argv[0]);
	return 2;
}
