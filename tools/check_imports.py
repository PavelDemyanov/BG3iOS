#!/usr/bin/env python3
"""Проверка подготовленного Mac-приложения: у каждого импорта каждого Mach-O должен быть хозяин.

Хозяин импорта — библиотека, на которую указывает его ordinal после конвертации (двухуровневое пространство
имён: символ ищется только в ней и в том, что она реэкспортирует):
- библиотека самой игры или наш заменитель — её экспорт плюс реэкспорт (системные — по .tbd SDK);
- системная библиотека iOS — по .tbd SDK, с её reexported-libraries.
Ещё проверяет, что каждая системная библиотека (абсолютный путь в LC_LOAD_DYLIB) в iOS есть.

check_imports.py APP_DIR
"""

import functools
import os
import re
import subprocess
import sys
from collections import defaultdict

SYMBOL_BLOCKS = re.compile(r"(symbols|weak-symbols|objc-classes|objc-eh-types|objc-ivars):\s*\[([^\]]*)\]", re.S)
PREFIX = {"objc-classes": ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_"), "objc-eh-types": ("_OBJC_EHTYPE_$_",),
          "objc-ivars": ("_OBJC_IVAR_$_",)}


def sdk_libraries():
    """install-name → (символы, реэкспортируемые install-name) по всем документам .tbd SDK iOS."""
    sdk = subprocess.run(["xcrun", "-sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True,
                         check=True).stdout.strip()
    libs = {}
    for base in ("System/Library/Frameworks", "usr/lib"):
        for root, _, files in os.walk(os.path.join(sdk, base), followlinks=True):
            for f in files:
                if not f.endswith(".tbd"):
                    continue
                text = open(os.path.join(root, f), errors="replace").read()
                for doc in re.split(r"^--- !tapi-tbd", text, flags=re.M):
                    m = re.search(r"^install-name:\s+'?([^'\n]+?)'?\s*$", doc, re.M)
                    if not m:
                        continue
                    syms = set()
                    for kind, body in SYMBOL_BLOCKS.findall(doc):
                        for s in re.findall(r"'([^']+)'|([^\s,']+)", body):
                            name = s[0] or s[1]
                            syms.update(p + name for p in PREFIX.get(kind, ("",)))
                    rex = set()
                    block = re.search(r"^reexported-libraries:\n((?:[ \t].*\n?)*)", doc, re.M)
                    if block:
                        rex = set(re.findall(r"'?(/[^',\s\]]+)'?", block.group(1)))
                    libs[m.group(1)] = (syms, rex)
    return libs


SDK = sdk_libraries()


@functools.lru_cache(None)
def system_symbols(install_name):
    syms, rex = SDK.get(install_name, (set(), set()))
    out = set(syms)
    for r in rex:
        out |= system_symbols(r)
    return frozenset(out)


def exports(path):
    out = subprocess.run(["xcrun", "dyld_info", "-exports", path], capture_output=True, text=True).stdout
    return {m.group(1) for m in re.finditer(r"^\s+0x[0-9A-F]+\s+(\S+)", out, re.M)}


def reexports(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    return re.findall(r"cmd LC_REEXPORT_DYLIB\n\s+cmdsize \d+\n\s+name (\S+)", out)


def dependencies(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out]


def leaf_names(path):
    """Как dyld_info называет библиотеку в «(from …)»: имя файла без .dylib и без суффикса версии."""
    base = path.rsplit("/", 1)[-1]
    return {base, base.rsplit(".dylib", 1)[0], base.split(".", 1)[0]}


def main():
    app = sys.argv[1]
    contents = os.path.join(app, "Contents")
    machos = []
    for root, _, files in os.walk(contents):
        if "/Data" in root:
            continue
        for f in files:
            p = os.path.join(root, f)
            if not os.path.islink(p):
                with open(p, "rb") as fh:
                    if fh.read(4) == b"\xcf\xfa\xed\xfe":
                        machos.append(p)
    # Библиотеки приложения (и наши заменители): экспорт плюс всё, что они реэкспортируют из системы.
    own = {}
    for p in machos:
        syms = exports(p) | set().union(*(system_symbols(r) for r in reexports(p) if r.startswith("/")))
        for key in leaf_names(p):
            own[key] = syms
    problems = 0
    for p in sorted(machos):
        rel = os.path.relpath(p, app)
        system = {}
        for lib in dependencies(p):
            if lib.startswith("/"):
                if lib not in SDK:
                    problems += 1
                    print(f"{rel}: библиотеки нет в iOS: {lib}")
                for key in leaf_names(lib):
                    system[key] = lib
        run = subprocess.run(["xcrun", "dyld_info", "-imports", p], capture_output=True, text=True)
        errors = [l.strip() for l in (run.stdout + run.stderr).splitlines()
                  if l.strip() and not l.strip().startswith(("-imports", "_")) and "(from" not in l
                  and "[arm64]" not in l]
        if errors:
            problems += 1
            print(f"{rel}: dyld_info: {' | '.join(errors)}")
        missing = defaultdict(list)
        for m in re.finditer(r"^\s+(\S+)\s+\(from (\S+)\)", run.stdout, re.M):
            sym, lib = m.groups()
            if lib in own:
                if sym in own[lib]:
                    continue
            elif lib in system:
                if sym in system_symbols(system[lib]):
                    continue
            missing[lib].append(sym)
        if missing:
            problems += sum(len(v) for v in missing.values())
            print(f"{rel}:")
            for lib, syms in missing.items():
                print(f"  {lib}: {' '.join(sorted(syms)[:12])}{' …' if len(syms) > 12 else ''} ({len(syms)})")
    print(f"Mach-O: {len(machos)}, проблем: {problems}")


if __name__ == "__main__":
    main()
