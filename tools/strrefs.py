#!/usr/bin/env python3
"""Где в коде используется C-строка: пары adrp + add (или adrp + ldr) с адресом строки в __TEXT,__text.

strrefs.py БИНАРНИК СТРОКА [--sub]   (--sub — строка может быть частью более длинной: ищется подстрока)
Печатает адреса инструкций add/ldr и ближайший символ перед ними (nm) — дальше в disasm.py.
"""

import bisect
import re
import struct
import subprocess
import sys

import numpy as np


def sections(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for i in range(nsects):
                s = off + 72 + i * 80
                sect = data[s:s + 16].rstrip(b"\0").decode()
                seg = data[s + 16:s + 32].rstrip(b"\0").decode()
                addr, size_, foff = struct.unpack_from("<QQI", data, s + 32)
                yield seg, sect, addr, size_, foff
        off += size


def main():
    path, needle = sys.argv[1], sys.argv[2].encode()
    sub = "--sub" in sys.argv
    data = open(path, "rb").read()
    secs = list(sections(data))
    targets = []
    for seg, sect, addr, size, foff in secs:
        if sect not in ("__cstring", "__const", "__objc_methname"):
            continue
        blob = data[foff:foff + size]
        for m in re.finditer(re.escape(needle), blob):
            start = m.start()
            if not sub:
                if (start and blob[start - 1] != 0) or blob[m.end():m.end() + 1] != b"\0":
                    continue
            else:  # начало C-строки, в которой найдена подстрока
                start = blob.rfind(b"\0", 0, start) + 1
            targets.append(addr + start)
    targets = sorted(set(targets))
    if not targets:
        sys.exit("строка не найдена")
    text = next(s for s in secs if s[0] == "__TEXT" and s[1] == "__text")
    _, _, taddr, tsize, tfoff = text
    w = np.frombuffer(data, dtype="<u4", count=tsize // 4, offset=tfoff)
    pcs = taddr + np.arange(len(w), dtype=np.uint64) * 4
    adrp = (w & 0x9F000000) == 0x90000000
    imm = (((w >> 5) & 0x7FFFF).astype(np.int64) << 2 | ((w >> 29) & 3).astype(np.int64))
    imm = np.where(imm & (1 << 20), imm - (1 << 21), imm)
    page = (pcs.astype(np.int64) & ~0xFFF) + (imm << 12)
    pages = {t & ~0xFFF for t in targets}
    idx = np.nonzero(adrp & np.isin(page, list(pages)))[0]
    syms = []
    out = subprocess.run(["nm", "-n", "--defined-only", path], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3 and parts[1] in "tT":
            syms.append((int(parts[0], 16), parts[2]))
    addrs = [a for a, _ in syms]
    for i in idx:
        rd = int(w[i]) & 31
        for j in range(i + 1, min(i + 12, len(w))):
            ins = int(w[j])
            rn = (ins >> 5) & 31
            if (ins & 0xFFC00000) == 0x91000000 and rn == rd:  # add Xd, Xn, #imm
                target = int(page[i]) + ((ins >> 10) & 0xFFF)
            elif (ins & 0xFFC00000) == 0xF9400000 and rn == rd:  # ldr Xt, [Xn, #imm]
                target = int(page[i]) + ((ins >> 10) & 0xFFF) * 8
            else:
                continue
            if target in targets:
                pc = taddr + j * 4
                k = bisect.bisect_right(addrs, pc) - 1
                name = f"{syms[k][1]}+{pc - syms[k][0]:#x}" if k >= 0 else "?"
                print(f"{pc:#x}  {name}")
            break


if __name__ == "__main__":
    main()
