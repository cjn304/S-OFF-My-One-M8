#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Read the "module_layout" crc out of a stock kernel module.

A module built for a CONFIG_MODVERSIONS=y kernel must carry a __versions entry
for module_layout whose crc equals the one the kernel was built with.  Without
the Module.symvers of the exact kernel build, modpost cannot fill that in, so
we copy the value from a module that shipped with the device.

Usage:
    python3 get_module_layout_crc.py <module.ko>

Prints the crc as a C literal, e.g.  0x7d779921UL
"""
import struct
import sys

MODULE_NAME_LEN = 64  # sizeof(struct modversion_info) on 32-bit kernels


def read_elf32_sections(data):
    if data[:4] != b"\x7fELF":
        raise SystemExit("not an ELF file")
    if data[4] != 1:
        raise SystemExit("not a 32-bit ELF file")
    e_shoff = struct.unpack_from("<I", data, 0x20)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x2E)[0]
    e_shnum = struct.unpack_from("<H", data, 0x30)[0]
    e_shstrndx = struct.unpack_from("<H", data, 0x32)[0]

    def section(i):
        off = e_shoff + i * e_shentsize
        name, stype, flags, addr, offset, size = struct.unpack_from(
            "<IIIIII", data, off)
        return {"name_off": name, "type": stype, "offset": offset, "size": size}

    shstr = section(e_shstrndx)
    strtab = data[shstr["offset"]:shstr["offset"] + shstr["size"]]

    def name_of(sec):
        end = strtab.find(b"\0", sec["name_off"])
        return strtab[sec["name_off"]:end].decode()

    return [(name_of(section(i)), section(i)) for i in range(e_shnum)]


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    data = open(sys.argv[1], "rb").read()
    for name, sec in read_elf32_sections(data):
        if name != "__versions":
            continue
        blob = data[sec["offset"]:sec["offset"] + sec["size"]]
        for off in range(0, len(blob), MODULE_NAME_LEN):
            entry = blob[off:off + MODULE_NAME_LEN]
            if len(entry) < MODULE_NAME_LEN:
                break
            crc = struct.unpack_from("<I", entry, 0)[0]
            sym = entry[4:].split(b"\0", 1)[0].decode(errors="replace")
            if sym == "module_layout":
                print("0x%08xUL" % crc)
                return
        raise SystemExit("no module_layout entry in __versions")
    raise SystemExit("no __versions section (kernel built without MODVERSIONS?)")


if __name__ == "__main__":
    main()
