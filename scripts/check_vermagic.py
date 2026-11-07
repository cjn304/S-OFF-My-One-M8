#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Compare the vermagic a .config will produce against a stock module's.

With CONFIG_MODVERSIONS=y the kernel's same_magic() skips everything up to the
first space - the UTS_RELEASE half - and compares only the flag half, plus the
module_layout crc.  So the flags are what has to match, and they are a pure
function of .config: this computes them from the config instead of waiting for
a 20-minute build to find out.

Usage:
    python3 check_vermagic.py <config> <stock.ko>

Exit status: 0 match, 1 mismatch, 2 could not read an input.
"""
import re
import sys

# arch/arm/Makefile: __LINUX_ARM_ARCH__ follows the CPU_32vN symbols, and
# ARCH_MSM_KRAIT pins it to 7 on its own.
def arm_arch(conf):
    if conf.get("CONFIG_ARCH_MSM_KRAIT") == "y":
        return 7
    vers = [int(m.group(1)) for k, v in conf.items()
            for m in [re.match(r"CONFIG_CPU_32v(\d+)$", k)] if m and v == "y"]
    return max(vers) if vers else None


def config_flags(path):
    conf = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"(CONFIG_[A-Za-z0-9_]+)=(.*)$", line.rstrip("\n"))
            if m:
                conf[m.group(1)] = m.group(2)

    on = lambda k: conf.get(k) == "y"
    flags = []
    if on("CONFIG_SMP"):
        flags.append("SMP")
    if on("CONFIG_PREEMPT_RT"):
        flags.append("preempt_rt")
    elif on("CONFIG_PREEMPT"):
        flags.append("preempt")
    if on("CONFIG_MODULE_UNLOAD"):
        flags.append("mod_unload")
    if on("CONFIG_MODVERSIONS"):
        flags.append("modversions")
    # include/linux/vermagic.h ends with MODULE_ARCH_VERMAGIC
    arch = arm_arch(conf)
    if arch is None:
        raise SystemExit("%s: no CONFIG_CPU_32vN - not an ARM config?" % path)
    flags.append("ARMv%d" % arch)
    if on("CONFIG_THUMB2_KERNEL"):
        flags.append("thumb2")
    if on("CONFIG_ARM_PATCH_PHYS_VIRT"):
        flags.append("p2v8")
    return conf, flags


def module_vermagic(path):
    data = open(path, "rb").read()
    m = re.search(rb"vermagic=([^\x00\n]+)", data)
    if not m:
        raise SystemExit("%s: no vermagic= in .modinfo" % path)
    return m.group(1).decode("utf-8", "replace").strip()


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    conf, expected = config_flags(sys.argv[1])
    actual = module_vermagic(sys.argv[2])
    actual_flags = actual.split(" ", 1)[1].split() if " " in actual else []

    print("  config : %s" % " ".join(expected))
    print("  module : %s" % " ".join(actual_flags))
    if expected == actual_flags:
        return 0

    print("vermagic flags differ - the config did not come from this phone's "
          "kernel, or oldconfig dropped something", file=sys.stderr)
    missing = [f for f in actual_flags if f not in expected]
    extra = [f for f in expected if f not in actual_flags]
    if missing:
        print("  the module has, the config will not: %s" % " ".join(missing),
              file=sys.stderr)
    if extra:
        print("  the config will add: %s" % " ".join(extra), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
