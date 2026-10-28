#!/usr/bin/env python3
"""Профиль Time Profiler по времени: загрузка процессора по 5-секундным окнам — всего, на P-ядрах и по главным
потокам (доля окна: 1.0 — ядро целиком). Экспорт — как для profile_summary.py.

profile_timeline.py X.xml [ШАГ_С]
"""

import sys
import xml.etree.ElementTree as ET
from collections import defaultdict

COLUMNS = ["Σ", "P", "ServerWorker thread", "GameThread", "Main Thread", "WT/Low/WT_0", "WT/Low/WT_1", "WT/Low/WT_2",
           "WT/High/WT_0", "прочие"]


def main():
    step = int(sys.argv[2]) if len(sys.argv) > 2 else 5
    root = ET.parse(sys.argv[1]).getroot()
    by_id = {}

    def reg(el):
        if el.get("id"):
            by_id[el.get("id")] = el
        for c in el:
            reg(c)

    reg(root)

    def res(el):
        return by_id[el.get("ref")] if el is not None and el.get("ref") else el

    buckets = defaultdict(lambda: defaultdict(float))
    for row in root.iter("row"):
        th, t, w, core = (res(row.find(k)) for k in ("thread", "sample-time", "weight", "core"))
        if th is None or t is None:
            continue
        name = th.get("fmt", "?").split(" (0x")[0].split(" (MacportLab")[0]
        if name not in COLUMNS:
            name = "прочие"
        ms = int(w.text) / 1e6 if w is not None and w.text else 1.0
        sec = int(int(t.text) / 1e9) // step * step
        b = buckets[sec]
        b[name] += ms
        b["Σ"] += ms
        if core is not None and "E Core" not in core.get("fmt", ""):
            b["P"] += ms
    print("сек " + " ".join(f"{c.replace(' thread', '').replace('WT/', '')[:9]:>9}" for c in COLUMNS))
    for sec in sorted(buckets):
        print(f"{sec:3} " + " ".join(f"{buckets[sec][c] / (step * 1000):9.2f}" for c in COLUMNS))


if __name__ == "__main__":
    main()
