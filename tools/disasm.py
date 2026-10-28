#!/usr/bin/env python3
"""Дизассемблер для разбора Mac-бинарников: llvm-objdump с подписями, которых он сам не ставит.

- вызов заглушки (__stubs) и загрузка из GOT — имя импорта (таблица косвенных символов, otool -Iv);
- adrp + add/ldr — C-строка, CFString или селектор по этому адресу;
- функция задаётся именем символа (или его началом) либо адресом; конец — следующий символ.

disasm.py БИНАРНИК СИМВОЛ|0xАДРЕС [0xКОНЕЦ] [--calls]   (--calls — только вызовы и строки)
"""

import bisect
import functools
import re
import struct
import subprocess
import sys


class MachO:
    def __init__(self, path):
        self.path = path
        self.data = open(path, "rb").read()
        ncmds = struct.unpack_from("<I", self.data, 16)[0]
        off = 32
        self.segs, self.sections = [], []
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", self.data, off)
            if cmd == 0x19:
                vm, vms, fo, _ = struct.unpack_from("<QQQQ", self.data, off + 24)
                self.segs.append((vm, vms, fo))
                nsects = struct.unpack_from("<I", self.data, off + 64)[0]
                for s in range(nsects):
                    so = off + 72 + s * 80
                    name = self.data[so:so + 16].rstrip(b"\0").decode()
                    seg = self.data[so + 16:so + 32].rstrip(b"\0").decode()
                    addr, sz = struct.unpack_from("<QQ", self.data, so + 32)
                    self.sections.append((seg, name, addr, sz))
            off += size

    def section(self, addr):
        for seg, name, a, sz in self.sections:
            if a <= addr < a + sz:
                return name
        return None

    def file_off(self, addr):
        for vm, vms, fo in self.segs:
            if vm <= addr < vm + vms:
                return fo + addr - vm
        return None

    def u64(self, addr):
        return struct.unpack_from("<Q", self.data, self.file_off(addr))[0]

    def ptr(self, addr):
        t = self.u64(addr) & 0xFFFFFFFFF
        return t + 0x100000000 if t < 0x100000000 else t

    def cstr(self, addr, limit=120):
        o = self.file_off(addr)
        if o is None:
            return None
        end = self.data.find(b"\0", o, o + 400)
        s = self.data[o:end if end >= 0 else o + limit].decode(errors="replace")
        return s[:limit] + ("…" if len(s) > limit else "")

    def describe(self, addr):
        sect = self.section(addr)
        try:
            if sect == "__cfstring":
                flags = self.u64(addr + 8)
                n = self.u64(addr + 24)
                raw = self.data[self.file_off(self.ptr(addr + 16)):][:n * (2 if flags == 0x7d0 else 1)]
                return '@"' + raw.decode("utf-16-le" if flags == 0x7d0 else "utf-8", errors="replace") + '"'
            if sect in ("__objc_selrefs",):
                return "sel " + self.cstr(self.ptr(addr))
            if sect in ("__cstring", "__objc_methname", "__const", "__objc_classname"):
                s = self.cstr(addr)
                if s and len(s) >= 2 and s.isprintable():
                    return '"' + s + '"'
        except Exception:
            return None
        return None


@functools.lru_cache(None)
def indirect(path):
    """Адрес заглушки (__stubs) или ячейки GOT → имя импорта, по таблице косвенных символов."""
    out = subprocess.run(["otool", "-Iv", path], capture_output=True, text=True).stdout
    return {int(m.group(1), 16): m.group(2) for m in re.finditer(r"^0x([0-9a-f]+)\s+\d+\s+(\S+)", out, re.M)}


@functools.lru_cache(None)
def symbols(path):
    out = subprocess.run(["nm", "-n", "--defined-only", path], capture_output=True, text=True).stdout
    syms = []
    for line in out.splitlines():
        parts = line.split(" ", 2)
        if len(parts) == 3:
            syms.append((int(parts[0], 16), parts[2]))
    return syms


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only_calls = "--calls" in sys.argv
    path = args[0]
    mo = MachO(path)
    syms = symbols(path)
    addrs = [a for a, _ in syms]
    if args[1].startswith("0x"):
        start = int(args[1], 16)
    else:
        matches = [(a, n) for a, n in syms if n == args[1]] or [(a, n) for a, n in syms if args[1] in n]
        if not matches:
            sys.exit(f"нет символа {args[1]}")
        if len(matches) > 1:
            print("несколько символов, беру первый:", *[n for _, n in matches[:5]], sep="\n  ")
        start = matches[0][0]
    if len(args) > 2:
        end = int(args[2], 16)
    else:
        i = bisect.bisect_right(addrs, start)
        end = addrs[i] if i < len(addrs) else start + 0x400
    names = indirect(path)
    out = subprocess.run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", f"--start-address={hex(start)}",
                          f"--stop-address={hex(end)}", path], capture_output=True, text=True).stdout
    regs = {}
    for line in out.splitlines():
        m = re.match(r"^\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
        if not m:
            if line.strip().endswith(">:"):
                print(line)
            continue
        addr, op, rest = int(m.group(1), 16), m.group(2), m.group(3)
        note = ""
        t = re.search(r"0x([0-9a-f]+)", rest)
        if op == "adrp" and t:
            regs[rest.split(",")[0]] = int(t.group(1), 16)
        elif op in ("add", "ldr") and "#" in rest:
            r = re.match(r"(x\d+),\s*\[?(x\d+),\s*#(0x[0-9a-f]+|\d+)", rest)
            if r and r.group(2) in regs:
                target = regs[r.group(2)] + int(r.group(3), 0)
                desc = mo.describe(target)
                if op == "ldr" and not desc and mo.section(target) == "__got":
                    desc = "got " + names.get(target, "?")
                if desc:
                    note = desc
                if r.group(1) != r.group(2):
                    regs.pop(r.group(1), None)
        if op in ("bl", "b") and t:
            target = int(t.group(1), 16)
            if mo.section(target) == "__stubs":
                rest = f"{hex(target)} <{names.get(target, '?')}>"
        if only_calls and op not in ("bl", "blr", "b") and not note:
            continue
        print(f"{addr:x}: {op:7} {rest}" + (f"   ; {note}" if note else ""))


if __name__ == "__main__":
    main()
