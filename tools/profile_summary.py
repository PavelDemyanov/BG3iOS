#!/usr/bin/env python3
"""Сводка профиля Time Profiler (xctrace export таблицы time-profile в XML).

По потокам: сколько миллисекунд выполнения, на каких ядрах (P/E); по каждому крупному потоку — функции, в которых
он был (самое верхнее имя в стеке, «сам»), и функции игры, внутри которых проведено больше всего (включительно).

xcrun xctrace export --input X.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > X.xml
profile_summary.py X.xml [ПОТОКОВ] [СТРОК]
"""

import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict


def main():
    path = sys.argv[1]
    threads_shown = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    lines = int(sys.argv[3]) if len(sys.argv) > 3 else 12
    root = ET.parse(path).getroot()
    by_id = {}

    def resolve(el):
        if el is None:
            return None
        ref = el.get("ref")
        if ref:
            return by_id[ref]
        if el.get("id"):
            by_id[el.get("id")] = el
        for child in el:
            resolve(child)
        return el

    per_thread = Counter()
    cores = defaultdict(Counter)
    leaf = defaultdict(Counter)
    inclusive = defaultdict(Counter)
    states = defaultdict(Counter)
    for row in root.iter("row"):
        thread = resolve(row.find("thread"))
        core = resolve(row.find("core"))
        state = resolve(row.find("thread-state"))
        weight = resolve(row.find("weight"))
        stack = resolve(row.find("tagged-backtrace"))
        if thread is None:
            continue
        name = thread.get("fmt", "?").split(" (MacportLab")[0]
        ms = int(weight.text) / 1e6 if weight is not None and weight.text else 1.0
        per_thread[name] += ms
        cores[name]["E" if core is not None and "E Core" in core.get("fmt", "") else "P"] += ms
        states[name][state.get("fmt") if state is not None else "?"] += ms
        frames = []
        if stack is not None:
            for f in stack.iter("frame"):
                f = by_id.get(f.get("ref")) if f.get("ref") else f
                if f is not None and f.get("id"):
                    by_id[f.get("id")] = f
                if f is not None:
                    binary = f.find("binary")
                    if binary is not None and binary.get("ref"):
                        binary = by_id.get(binary.get("ref"))
                    elif binary is not None and binary.get("id"):
                        by_id[binary.get("id")] = binary
                    frames.append((f.get("name", "?"), binary.get("name", "?") if binary is not None else "?"))
        if frames:
            leaf[name][f"{frames[0][0][:90]}  [{frames[0][1]}]"] += ms
            seen = set()
            for fn, binary in frames:
                if binary.startswith("Baldur") and fn not in seen:
                    seen.add(fn)
                    inclusive[name][fn[:110]] += ms
    total = sum(per_thread.values())
    print(f"всего {total / 1000:.1f} с процессора, потоков {len(per_thread)}")
    for name, ms in per_thread.most_common(30):
        c = cores[name]
        print(f"  {ms / 1000:6.1f} с  P {c['P'] / 1000:5.1f} / E {c['E'] / 1000:5.1f}  {name}")
    for name, _ in per_thread.most_common(threads_shown):
        print(f"\n== {name}: сам")
        for fn, ms in leaf[name].most_common(lines):
            print(f"  {ms / 1000:6.2f} с  {fn}")
        print(f"-- включительно (код игры)")
        for fn, ms in inclusive[name].most_common(lines):
            print(f"  {ms / 1000:6.2f} с  {fn}")


if __name__ == "__main__":
    main()
