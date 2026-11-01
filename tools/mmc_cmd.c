/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * mmc_cmd - tiny MMC_IOC_CMD wrapper used to inspect eMMC write protection.
 *
 *   mmc_cmd wp [device]                 # CMD31: write-protect type bitmap
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
		"  %s raw <op> <arg> <flags> <blksz> <blocks> <write> [device]\n",
		argv[0], argv[0]);
	return 2;
}
