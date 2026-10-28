#!/usr/bin/env python3
"""Стек упавшего потока из отчёта iOS (.ips) с именами функций.

Кадры из библиотек подготовленного приложения (APP_DIR) и заменителей (build/shims) переводятся в имена через
atos по их файлам на Mac; системные — по имени символа из самого отчёта.

crash_summary.py ОТЧЁТ.ips [APP_DIR] [--all]   (--all — все потоки, иначе только упавший и lastExceptionBacktrace)
"""

import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def local_files(app):
    files = {}
    for base in filter(None, [app and os.path.join(app, "Contents"), os.path.join(ROOT, "build/shims")]):
        for root, _, names in os.walk(base):
            if "/Data" in root:
                continue
            for n in names:
                files.setdefault(n, os.path.join(root, n))
    return files


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show_all = "--all" in sys.argv
    text = open(args[0]).read()
    header, body = text.split("\n", 1)
    report = json.loads(body)
    app = args[1] if len(args) > 1 else None
    files = local_files(app)
    images = report.get("usedImages", [])
    exc = report.get("exception", {})
    print("исключение:", exc.get("type"), exc.get("signal"), exc.get("subtype", ""))
    if report.get("asi"):
        print("asi:", json.dumps(report["asi"], ensure_ascii=False)[:600])
    pending = {}  # (файл, база) -> [адреса]

    def frame_line(frame):
        img = images[frame["imageIndex"]] if frame.get("imageIndex") is not None else {}
        name = img.get("name") or os.path.basename(img.get("path", "?"))
        addr = img.get("base", 0) + frame.get("imageOffset", 0)
        sym = frame.get("symbol")
        if sym:
            return f"{name}: {sym}+{frame.get('symbolLocation', 0)}"
        local = files.get(name)
        if local:
            pending.setdefault((local, img["base"]), []).append(addr)
            return (local, img["base"], addr, name)
        return f"{name}: +{hex(frame.get('imageOffset', 0))}"

    blocks = []
    if report.get("lastExceptionBacktrace"):
        blocks.append(("lastExceptionBacktrace", [frame_line(f) for f in report["lastExceptionBacktrace"]]))
    for i, thread in enumerate(report.get("threads", [])):
        if show_all or thread.get("triggered"):
            title = f"поток {i}" + (" (упавший)" if thread.get("triggered") else "") + (
                f" {thread['name']}" if thread.get("name") else "") + (
                f" очередь {thread['queue']}" if thread.get("queue") else "")
            blocks.append((title, [frame_line(f) for f in thread.get("frames", [])]))
    # atos по каждой библиотеке разом.
    resolved = {}
    for (local, base), addrs in pending.items():
        out = subprocess.run(["atos", "-o", local, "-arch", "arm64", "-l", hex(base)] + [hex(a) for a in addrs],
                             capture_output=True, text=True).stdout.splitlines()
        for a, line in zip(addrs, out):
            resolved[(local, a)] = line
    for title, lines in blocks:
        print(f"\n== {title}")
        for i, l in enumerate(lines[:60]):
            if isinstance(l, tuple):
                local, base, addr, name = l
                l = f"{name}: {resolved.get((local, addr), hex(addr - base))}"
            print(f"{i:3} {l}")


if __name__ == "__main__":
    main()
