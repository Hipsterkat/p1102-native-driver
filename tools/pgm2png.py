#!/usr/bin/env python3
"""Downscale a binary PGM (as written by zjsdecode -d) to a grayscale PNG for viewing.

  pgm2png.py IN.pgm OUT.png [FACTOR]

zjsdecode writes the printer's 2-bit levels as a normal PGM (0 = black .. maxval = white);
each output pixel is the average of a FACTOR x FACTOR block, so halftones show up as gray.
"""
import struct
import sys
import zlib


def read_pgm(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos)
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    assert fields[0] == b"P5", "not a binary PGM"
    w, h, maxval = int(fields[1]), int(fields[2]), int(fields[3])
    return w, h, maxval, data[pos + 1:pos + 1 + w * h]


def main(src, dst, factor=8):
    w, h, maxval, px = read_pgm(src)
    ow, oh = w // factor, h // factor
    rows = []
    for oy in range(oh):
        acc = [0] * ow
        for dy in range(factor):
            line = px[(oy * factor + dy) * w:(oy * factor + dy + 1) * w]
            for ox in range(ow):
                acc[ox] += sum(line[ox * factor:(ox + 1) * factor])
        full = factor * factor * maxval
        rows.append(b"\x00" + bytes((a * 255) // full for a in acc))

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", ow, oh, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")
    open(dst, "wb").write(png)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 8)
