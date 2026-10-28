#!/usr/bin/env python3
"""Кто вызывает функцию: все BL/B на адрес (или символ) в __TEXT,__text arm64 Mach-O, с именами вызывающих.

xrefs.py БИНАРНИК 0xАДРЕС|СИМВОЛ
"""

import array
import bisect
import struct
import subprocess
import sys


def main():
    path, what = sys.argv[1], sys.argv[2]
    syms = []
    for line in subprocess.run(["nm", "-n", "--defined-only", path], capture_output=True, text=True).stdout.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[1] in "tT":
            syms.append((int(parts[0], 16), parts[2]))
    addrs = [a for a, _ in syms]
    target = int(what, 16) if what.startswith("0x") else next(a for a, n in syms if n == what)
    data = open(path, "rb").read()
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    text = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for s in range(nsects):
                so = off + 72 + s * 80
                if data[so:so + 16].rstrip(b"\0") == b"__text":
                    addr, sz = struct.unpack_from("<QQ", data, so + 32)
                    fo = struct.unpack_from("<I", data, so + 48)[0]
                    text = (addr, sz, fo)
        off += size
    addr, size, fo = text
    words = array.array("I")
    words.frombytes(data[fo:fo + size])
    hits = []
    for i, w in enumerate(words):
        top = w >> 26
        if top not in (0x25, 0x05):  # BL, B
            continue
        imm = w & 0x3FFFFFF
        if imm & 0x2000000:
            imm -= 0x4000000
        if addr + i * 4 + imm * 4 == target:
            hits.append(addr + i * 4)
    for h in hits:
        k = bisect.bisect_right(addrs, h) - 1
        name = subprocess.run(["c++filt", "-_"], input=syms[k][1], capture_output=True, text=True).stdout.strip()
        print(f"{h:x}  {name[:150]}+0x{h - syms[k][0]:x}")


if __name__ == "__main__":
    main()
