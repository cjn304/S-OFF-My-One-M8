#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Pull the .config out of an Android boot image.

CONFIG_IKCONFIG=y stores the config inside the kernel image as a gzip stream
between the markers IKCFG_ST and IKCFG_ED.  CONFIG_IKCONFIG_PROC=n means the
phone has no /proc/config.gz, so the boot partition is the only copy.

Usage:
    python3 extract_config.py <boot.img> > m8.config

Reads a raw partition dump, not a signed RUU image: the latter carries a
256-byte signature header, and the boot header fields would be read from the
wrong offset.  Handles both an uncompressed kernel and the usual zImage, where
a self-decompressing stub precedes the gzip body.
"""
import struct
import sys
import zlib

IKCFG_ST = b"IKCFG_ST"
IKCFG_ED = b"IKCFG_ED"

# Compressed kernel bodies, in the order they are worth trying.  The other two
# formats are only recognised so the error message can name them.
MAGICS = ((b"\x1f\x8b\x08", "gzip"), (b"\xfd7zXZ\x00", "xz"))
UNSUPPORTED = ((b"\x02\x21\x4c\x18", "lz4"), (b"\x89LZO", "lzo"),
               (b"\x5d\x00\x00", "lzma"))
MIN_KERNEL = 1 << 20          # anything smaller is not a kernel image


def read_boot(path):
    raw = open(path, "rb").read()
    if raw[:8] != b"ANDROID!":
        raise SystemExit("%s: no ANDROID! magic - not a raw boot partition dump"
                         % path)
    ksize, _kaddr, _rsize, _raddr, _ssize, _saddr, _tags, page = \
        struct.unpack_from("<8I", raw, 8)
    if page < 2048 or page > 65536 or page & (page - 1):
        raise SystemExit("%s: implausible page size %d" % (path, page))
    return raw[page:page + ksize]


def find_config(image):
    """Return the config text, or None if this image carries no IKCONFIG blob."""
    start = 0
    while True:
        i = image.find(IKCFG_ST, start)
        if i < 0:
            return None
        j = image.find(IKCFG_ED, i)
        if j < 0:
            return None
        blob = image[i + len(IKCFG_ST):j]
        try:
            text = zlib.decompressobj(31).decompress(blob)
        except zlib.error:
            start = i + 1          # that marker was data, not the real one
            continue
        if b"CONFIG_" in text:
            return text.decode("utf-8", "replace")
        start = i + 1


def decompressed(image):
    """Yield the decompressed kernel bodies found in a zImage-style payload.

    A zImage starts with a decompressor stub, so the compressed stream is not
    at offset 0; walk the magic instead.  Bogus hits fail to inflate and are
    skipped.
    """
    for magic, fmt in MAGICS:
        start, tries = 0, 0
        while tries < 8:
            i = image.find(magic, start)
            if i < 0:
                break
            tries += 1
            start = i + 1
            try:
                if fmt == "gzip":
                    plain = zlib.decompressobj(31).decompress(image[i:])
                else:
                    import lzma
                    plain = lzma.decompress(image[i:])
            except Exception:
                continue
            if len(plain) >= MIN_KERNEL:
                yield plain
                break              # one good hit per format is enough


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    image = read_boot(sys.argv[1])

    text = find_config(image)      # uncompressed kernel: the marker is right there
    packed = False
    if text is None:
        for plain in decompressed(image):
            packed = True
            text = find_config(plain)
            if text:
                break

    if text is None:
        if packed:
            raise SystemExit(
                "the kernel carries no IKCFG_ST - it was built without "
                "CONFIG_IKCONFIG, so this image does not hold its .config")
        for magic, name in UNSUPPORTED:
            if image.find(magic) >= 0:
                raise SystemExit(
                    "kernel is %s-compressed - unpack it with the matching "
                    "tool, then search the result for IKCFG_ST" % name)
        raise SystemExit(
            "no compressed kernel body and no IKCFG_ST - not a kernel image?")

    sys.stdout.write(text)


if __name__ == "__main__":
    main()
