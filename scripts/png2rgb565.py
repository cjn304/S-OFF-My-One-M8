#!/usr/bin/env python3
"""Convert a PNG into the raw frame buffer format used by the M8 splash partition.

The sp1 partition holds 1080x1920 little-endian RGB565 starting at offset 0
(4,147,200 bytes; the rest of the partition is padding).  This script is pure
standard library on purpose - the tool has to run on a bare Windows box where
ffmpeg / PIL / ImageMagick are not installed.

    python png2rgb565.py in.png out.raw [--width 1080] [--height 1920]
                                      [--fit=contain|cover|stretch] [--bg=RRGGBB]

--fit controls what happens when the source is not the target aspect ratio:

    contain  (default) scale to fit, centre, fill the rest with --bg
    cover              scale to fill, centre-crop the overflow
    stretch            scale each axis independently (distorts; old behaviour)

Only non-interlaced 8-bit PNGs are supported (grey, grey+alpha, RGB, RGBA and
palette).  Anything else is rejected with a clear message instead of producing
a silently wrong image.
"""
import struct
import sys
import zlib

CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path):
    """Return (width, height, rows) where rows is a list of bytearray RGB triples."""
    data = open(path, 'rb').read()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('error: %s is not a PNG file (JPEG is not supported, re-save as PNG)' % path)

    pos = 8
    idat = []
    palette = b''
    width = height = depth = ctype = interlace = None

    while pos < len(data):
        if pos + 8 > len(data):
            break
        length, ctag = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctag == b'IHDR':
            width, height, depth, ctype, _comp, _filt, interlace = struct.unpack('>IIBBBBB', body)
        elif ctag == b'PLTE':
            palette = body
        elif ctag == b'IDAT':
            idat.append(body)
        elif ctag == b'IEND':
            break

    if width is None:
        raise SystemExit('error: no IHDR in %s' % path)
    if interlace:
        raise SystemExit('error: interlaced PNG is not supported, re-save as non-interlaced')
    if depth != 8:
        raise SystemExit('error: only 8-bit PNG is supported (got %d-bit)' % depth)
    if ctype not in CHANNELS:
        raise SystemExit('error: unsupported PNG colour type %d' % ctype)

    raw = zlib.decompress(b''.join(idat))
    bpp = CHANNELS[ctype] * depth // 8
    stride = width * bpp
    out = []
    prev = bytearray(stride)
    p = 0

    for _y in range(height):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                c = prev[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + _paeth(a, prev[i], c)) & 0xFF
        elif ft != 0:
            raise SystemExit('error: bad PNG filter type %d' % ft)
        out.append(line)
        prev = line

    rows = []
    if ctype == 0:
        for line in out:
            row = bytearray(width * 3)
            for x in range(width):
                v = line[x]
                row[x * 3] = row[x * 3 + 1] = row[x * 3 + 2] = v
            rows.append(row)
    elif ctype == 4:
        for line in out:
            row = bytearray(width * 3)
            for x in range(width):
                v = line[x * 2]
                row[x * 3] = row[x * 3 + 1] = row[x * 3 + 2] = v
            rows.append(row)
    elif ctype == 2:
        rows = [bytearray(line) for line in out]
    elif ctype == 6:
        for line in out:
            row = bytearray(width * 3)
            for x in range(width):
                row[x * 3:x * 3 + 3] = line[x * 4:x * 4 + 3]
            rows.append(row)
    else:  # palette
        lut = [palette[i:i + 3] for i in range(0, len(palette), 3)]
        if not lut:
            raise SystemExit('error: palette PNG without PLTE')
        for line in out:
            row = bytearray(width * 3)
            for x in range(width):
                idx = line[x]
                row[x * 3:x * 3 + 3] = lut[idx] if idx < len(lut) else b'\x00\x00\x00'
            rows.append(row)

    return width, height, rows


def _scale(rows, sw, sh, dw, dh):
    """Bilinear scale of a list of RGB bytearrays to exactly dw x dh."""
    if sw == dw and sh == dh:
        return [bytearray(r) for r in rows]

    xtaps = []
    for x in range(dw):
        sx = (x + 0.5) * sw / dw - 0.5
        x0 = int(sx)
        fx = sx - x0
        if x0 < 0:
            x0, fx = 0, 0.0
        x1 = min(x0 + 1, sw - 1)
        xtaps.append((x0 * 3, x1 * 3, fx))

    out = []
    for y in range(dh):
        sy = (y + 0.5) * sh / dh - 0.5
        y0 = int(sy)
        fy = sy - y0
        if y0 < 0:
            y0, fy = 0, 0.0
        y1 = min(y0 + 1, sh - 1)
        r0 = rows[y0]
        r1 = rows[y1]
        row = bytearray(dw * 3)
        if fy == 0.0 and r0 is r1:
            for x, (a, b, fx) in enumerate(xtaps):
                if fx == 0.0:
                    row[x * 3:x * 3 + 3] = r0[a:a + 3]
                else:
                    for c in range(3):
                        row[x * 3 + c] = int(r0[a + c] + (r0[b + c] - r0[a + c]) * fx + 0.5)
        else:
            for x, (a, b, fx) in enumerate(xtaps):
                for c in range(3):
                    top = r0[a + c] + (r0[b + c] - r0[a + c]) * fx
                    bot = r1[a + c] + (r1[b + c] - r1[a + c]) * fx
                    row[x * 3 + c] = int(top + (bot - top) * fy + 0.5)
        out.append(row)
    return out


def resize(rows, sw, sh, dw, dh, fit='contain', bg=(0, 0, 0)):
    """Fit a source image into dw x dh according to `fit`."""
    if fit == 'stretch':
        return _scale(rows, sw, sh, dw, dh)

    if fit == 'cover':
        scale = max(dw / sw, dh / sh)
        nw = max(dw, int(sw * scale + 0.5))
        nh = max(dh, int(sh * scale + 0.5))
        big = _scale(rows, sw, sh, nw, nh)
        ox = (nw - dw) // 2
        oy = (nh - dh) // 2
        return [bytearray(r[ox * 3:(ox + dw) * 3]) for r in big[oy:oy + dh]]

    # contain: keep the whole image, pad with bg
    scale = min(dw / sw, dh / sh)
    nw = max(1, min(dw, int(sw * scale + 0.5)))
    nh = max(1, min(dh, int(sh * scale + 0.5)))
    small = _scale(rows, sw, sh, nw, nh)
    ox = (dw - nw) // 2
    oy = (dh - nh) // 2
    fill = bytes(bg) * dw
    out = []
    for y in range(dh):
        if oy <= y < oy + nh:
            row = bytearray(fill)
            row[ox * 3:(ox + nw) * 3] = small[y - oy]
            out.append(row)
        else:
            out.append(bytearray(fill))
    return out


def to_rgb565(rows, width, height):
    buf = bytearray(width * height * 2)
    o = 0
    for row in rows:
        for x in range(width):
            r = row[x * 3]
            g = row[x * 3 + 1]
            b = row[x * 3 + 2]
            v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
            buf[o] = v & 0xFF
            buf[o + 1] = v >> 8
            o += 2
    return buf


def parse_bg(text):
    text = text.lstrip('#')
    if len(text) != 6:
        raise SystemExit('error: --bg wants RRGGBB, got %r' % text)
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


def main(argv):
    args = []
    opts = {}
    for a in argv[1:]:
        if a.startswith('--'):
            if '=' in a:
                k, v = a[2:].split('=', 1)
                opts[k] = v
            else:
                opts[a[2:]] = '1'
        else:
            args.append(a)
    if len(args) < 2:
        raise SystemExit(__doc__)

    width = int(opts.get('width', 1080))
    height = int(opts.get('height', 1920))
    fit = opts.get('fit', 'contain')
    if fit not in ('contain', 'cover', 'stretch'):
        raise SystemExit('error: --fit must be contain, cover or stretch')
    bg = parse_bg(opts.get('bg', '000000'))

    sw, sh, rows = read_png(args[0])

    src_ratio = sw / sh
    dst_ratio = width / height
    note = ''
    if abs(src_ratio / dst_ratio - 1) > 0.02:
        pct = (src_ratio / dst_ratio - 1) * 100
        if fit == 'stretch':
            note = ' (source is %+.0f%% off 9:16, stretch will distort)' % pct
        else:
            note = ' (source is %+.0f%% off 9:16, %s applied)' % (pct, fit)

    rows = resize(rows, sw, sh, width, height, fit, bg)
    buf = to_rgb565(rows, width, height)
    open(args[1], 'wb').write(buf)
    sys.stderr.write('%dx%d -> %dx%d (%s)%s, %d bytes\n'
                     % (sw, sh, width, height, fit, note, len(buf)))


if __name__ == '__main__':
    main(sys.argv)
