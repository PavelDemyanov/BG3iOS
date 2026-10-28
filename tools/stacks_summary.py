#!/usr/bin/env python3
"""Сводка сэмплера стеков MPSystem (MP_SAMPLE=…) из журнала: последние окна каждого потока складываются,
адреса подписываются atos по бинарнику игры.

stacks_summary.py ЖУРНАЛ БИНАРНИК [ОКОН=3] [СТРОК=12]
"""

import collections
import re
import subprocess
import sys


def short(name, limit=110):
    name = re.sub(r" \(in [^)]*\)", "", name)
    name = re.sub(r"\(.*\)", "()", name)  # аргументы шаблонов и функций — не нужны для сводки
    return name if len(name) <= limit else name[:limit] + "…"


def main():
    log, binary = sys.argv[1], sys.argv[2]
    windows = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    rows = int(sys.argv[4]) if len(sys.argv) > 4 else 12
    sections = collections.defaultdict(list)  # поток → [(выборок, ждёт%, [(доля, ждёт, адреса)])]
    current = None
    for line in open(log, errors="replace"):
        m = re.search(r"стеки «(.+)»: (\d+) выборок, ждёт в системном вызове (\d+)%", line)
        if m:
            current = (int(m.group(2)), int(m.group(3)), [])
            sections[m.group(1)].append(current)
            continue
        m = re.search(r"MPSystem:\s+([\d.]+)% (ждёт|счёт) (\S+) (\S+) (\S+) (\S+)", line)
        if m and current:
            current[2].append((float(m.group(1)), m.group(2), [a for a in m.group(3, 4, 5, 6) if a != "0"]))
            continue
        current = None
    addrs = sorted({a for runs in sections.values() for _, _, items in runs for _, _, keys in items for a in keys})
    names = {}
    if addrs:
        out = subprocess.run(["atos", "-o", binary, "-arch", "arm64", *addrs], capture_output=True, text=True).stdout
        names = dict(zip(addrs, out.splitlines()))
    for thread, runs in sections.items():
        runs = runs[-windows:]
        total = sum(n for n, _, _ in runs)
        wait = sum(n * w for n, w, _ in runs) / max(total, 1)
        print(f"== {thread}: {total} выборок за {len(runs)} окон, ждёт в системном вызове {wait:.0f}%")
        agg = collections.Counter()
        for n, _, items in runs:
            for share, kind, keys in items:
                agg[(kind, tuple(keys))] += share * n / 100
        for (kind, keys), count in agg.most_common(rows):
            print(f"  {count * 100 / total:5.1f}% {kind}")
            for a in keys:
                print(f"         {a}  {short(names.get(a, '?'))}")


if __name__ == "__main__":
    main()
