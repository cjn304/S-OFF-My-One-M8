#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Locate the six "This build is for ..." lines in an hboot image on stdin.

Prints the six decimal offsets on one line, or exits non-zero if any line is
missing (which means this hboot build does not carry the dev warning at all).
"""
import sys

LINES = [b'This build is for',
         b'development purposes only',
         b'Do not distribute outside of HTC',
         b"without HTC's written permission.",
         b'Failure to comply may',
         b'lead to legal action.']


def main():
    data = sys.stdin.buffer.read()
    if not data:
        sys.stderr.write('error: no data on stdin\n')
        return 2
    out = []
    for line in LINES:
        i = data.find(line)
        if i < 0:
            sys.stderr.write('not found: %s\n' % line.decode('latin1'))
            return 1
        out.append(i)
    sys.stdout.write(' '.join(str(x) for x in out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
