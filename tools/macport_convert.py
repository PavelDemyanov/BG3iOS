#!/usr/bin/env python3
"""Готовит arm64-бинарник macOS к загрузке на iOS через dlopen.

- Универсальный файл сужается до arm64 (lipo).
- LC_BUILD_VERSION: платформа macOS → iOS, minos и sdk — под iOS.
- Главный файл (MH_EXECUTE) становится библиотекой (MH_DYLIB), как у LiveContainer:
  __PAGEZERO сжимается до одной страницы, LC_LOAD_DYLINKER заменяется на LC_ID_DYLIB. LC_MAIN остаётся —
  по нему загрузчик находит main.
- Пути зависимостей: /System/Library/Frameworks/X.framework/Versions/V/X → .../X.framework/X (на iOS
  фреймворки плоские); библиотеки, которых в iOS нет или у которых не хватает символов, — на наши заменители
  (@rpath/MPX.dylib, см. SHIMS); у системных путей compatibility_version обнуляется.
- LC_RPATH → @loader_path/../Frameworks: заменители и библиотеки игры лежат в Contents/Frameworks.

Подпись после правок недействительна: подписывать заново (codesign) при сборке приложения.
"""

import argparse
import functools
import glob
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE, MH_DYLIB = 0x2, 0x6
MH_PIE, MH_NO_REEXPORTED_DYLIBS = 0x200000, 0x100000
LC_SEGMENT_64 = 0x19
LC_ID_DYLIB, LC_LOAD_DYLINKER = 0xD, 0xE
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB = 0xC, 0x80000018, 0x8000001F
LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB = 0x20, 0x80000023
LC_RPATH = 0x8000001C
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_IPHONEOS = 0x24, 0x25
PLATFORM_IOS = 2
DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}

# Фреймворки macOS, которых в iOS нет или где не хватает символов: на наш заменитель.
# Заменитель для существующего в iOS фреймворка реэкспортирует настоящий и добавляет недостающее.
SHIMS = {
    # У каждого убранного фреймворка свой пустой заменитель: два LC_LOAD_DYLIB с одним путём dyld отвергает
    # («duplicate linked dylib»).
    "AppKit": "MPAppKit",
    "Cocoa": "MPCocoa",
    "Carbon": "MPCarbon",
    "OpenGL": "MPOpenGL",
    "ForceFeedback": "MPForceFeedback",
    "CoreGraphics": "MPCoreGraphics",
    "CoreVideo": "MPCoreVideo",
    "Security": "MPSecurity",
    "CoreServices": "MPCoreServices",
    # В iOS функции AudioUnit живут в AudioToolbox, отдельного фреймворка нет: заменитель реэкспортирует AudioToolbox.
    "AudioUnit": "MPAudioUnit",
    # Managed-ресурсы (только macOS) → Shared, пустые didModifyRange:/synchronizeResource: (см. MPMetal.m).
    "Metal": "MPMetal",
    # Звук: выход HAL → RemoteIO, HAL (AudioObject…) — своё устройство (см. MPAudioToolbox.c, MPCoreAudio.c).
    "AudioToolbox": "MPAudioToolbox",
    "CoreAudio": "MPCoreAudio",
}
LIB_SHIMS = {"/usr/lib/libSystem.B.dylib": "MPSystem"}


def version(major, minor=0, patch=0):
    return (major << 16) | (minor << 8) | patch


def thin_arm64(src, dst):
    out = subprocess.run(["lipo", "-info", src], capture_output=True, text=True).stdout
    if "Non-fat" in out:
        shutil.copyfile(src, dst)
    else:
        subprocess.run(["lipo", "-thin", "arm64", src, "-output", dst], check=True)


@functools.lru_cache(None)
def ios_frameworks():
    """Пути фреймворков iOS по имени — из .tbd SDK. Не у всех плоская раскладка: IOKit в iOS — Versions/A."""
    sdk = subprocess.run(["xcrun", "-sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True,
                         check=True).stdout.strip()
    paths = {}
    for tbd in glob.glob(f"{sdk}/System/Library/Frameworks/*.framework/*.tbd"):
        m = re.search(r"^install-name:\s+'?([^'\n]+?)'?\s*$", open(tbd, errors="ignore").read(), re.M)
        if m:
            paths[os.path.basename(tbd)[:-4]] = m.group(1)
    return paths


def new_dylib_path(path, shims_used):
    if path in LIB_SHIMS:
        name = LIB_SHIMS[path]
        shims_used.add(name)
        return f"@rpath/{name}.dylib", True
    prefix = "/System/Library/Frameworks/"
    if path.startswith(prefix):
        name = path[len(prefix):].split(".framework", 1)[0]
        if name in SHIMS:
            shims_used.add(SHIMS[name])
            return f"@rpath/{SHIMS[name]}.dylib", True
        if name not in ios_frameworks():
            sys.exit(f"фреймворка {name} в iOS нет — нужен заменитель в SHIMS")
        return ios_frameworks()[name], True
    return path, False


def convert(src, dst, report, rpath="@loader_path/../Frameworks"):
    with tempfile.TemporaryDirectory() as tmp:
        thin = os.path.join(tmp, "thin")
        thin_arm64(src, thin)
        data = bytearray(open(thin, "rb").read())
    magic, cputype, _, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64:
        sys.exit(f"{src}: не Mach-O 64")
    shims_used = set()
    was_exec = filetype == MH_EXECUTE
    has_rpath = False
    first_section = len(data)  # первый байт содержимого: до него могут расти команды загрузки
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", data, off + 8)
            struct.pack_into("<III", data, off + 8, PLATFORM_IOS, version(17), version(26))
            report.append(f"LC_BUILD_VERSION: platform {platform} → iOS, minos 17.0, sdk 26.0")
        elif cmd == LC_VERSION_MIN_MACOSX:
            struct.pack_into("<III", data, off, LC_VERSION_MIN_IPHONEOS, cmdsize, version(17))
            struct.pack_into("<I", data, off + 12, version(26))
            report.append("LC_VERSION_MIN_MACOSX → LC_VERSION_MIN_IPHONEOS")
        elif cmd in DYLIB_CMDS:
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            raw = bytes(data[off + name_off: off + cmdsize])
            path = raw.split(b"\0", 1)[0].decode()
            new, system = new_dylib_path(path, shims_used)
            if new != path:
                encoded = new.encode() + b"\0"
                room = cmdsize - name_off
                if len(encoded) > room:
                    sys.exit(f"{src}: путь «{new}» не помещается вместо «{path}» ({room} байт)")
                data[off + name_off: off + cmdsize] = encoded + b"\0" * (room - len(encoded))
                report.append(f"dylib: {path} → {new}")
            if system:
                struct.pack_into("<I", data, off + 20, 0)  # compatibility_version: любая
        elif cmd == LC_RPATH:
            # Первый LC_RPATH — на Contents/Frameworks; остальные остаются (пути macOS безвредны), а совпавший с
            # новым получает уникальное имя: одинаковые LC_RPATH dyld отвергает.
            name_off = struct.unpack_from("<I", data, off + 8)[0]
            room = cmdsize - name_off
            old = bytes(data[off + name_off: off + cmdsize]).split(b"\0", 1)[0].decode()
            target = rpath if not has_rpath else (f"@loader_path/.mp{off}" if old == rpath else None)
            has_rpath = True
            new = target.encode() + b"\0" if target else None
            if new and len(new) <= room:
                data[off + name_off: off + cmdsize] = new + b"\0" * (room - len(new))
                report.append(f"rpath: {old} → {target}")
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, off + 64)[0]
            for s in range(nsects):
                sect_off = struct.unpack_from("<I", data, off + 72 + s * 80 + 48)[0]
                if sect_off:
                    first_section = min(first_section, sect_off)
        if cmd == LC_SEGMENT_64 and was_exec:
            segname = data[off + 8: off + 24].split(b"\0", 1)[0].decode()
            vmaddr, vmsize = struct.unpack_from("<QQ", data, off + 24)
            if segname == "__PAGEZERO" and vmaddr == 0:
                # Как в LiveContainer: библиотеке не нужно 4 ГБ пустоты под адресом 0.
                struct.pack_into("<QQ", data, off + 24, vmsize - 0x4000, 0x4000)
                report.append(f"__PAGEZERO: 0x{vmsize:x} → одна страница у 0x{vmsize - 0x4000:x}")
        if cmd == LC_LOAD_DYLINKER and was_exec:
            # LC_ID_DYLIB на место LC_LOAD_DYLINKER: dylib_command (24 байта) + короткое имя.
            name = b"mp\0"
            if 24 + len(name) > cmdsize:
                sys.exit(f"{src}: в LC_LOAD_DYLINKER ({cmdsize} байт) не помещается LC_ID_DYLIB")
            body = struct.pack("<IIIIII", LC_ID_DYLIB, cmdsize, 24, 2, version(1), version(1)) + name
            data[off: off + cmdsize] = body + b"\0" * (cmdsize - len(body))
            report.append("LC_LOAD_DYLINKER → LC_ID_DYLIB")
        off += cmdsize
    if not has_rpath:
        # Без своего LC_RPATH @rpath искался бы только по путям хоста: добавляем в запас после команд.
        path = rpath.encode() + b"\0"
        size = (12 + len(path) + 7) & ~7
        end = 32 + sizeofcmds
        if end + size > first_section:
            sys.exit(f"{src}: нет места под LC_RPATH ({first_section - end} байт)")
        data[end: end + size] = struct.pack("<III", LC_RPATH, size, 12) + path + b"\0" * (size - 12 - len(path))
        ncmds += 1
        sizeofcmds += size
        struct.pack_into("<II", data, 16, ncmds, sizeofcmds)
        report.append(f"rpath: добавлен {rpath}")
    if was_exec:
        flags = (flags & ~MH_PIE) | MH_NO_REEXPORTED_DYLIBS
        struct.pack_into("<II", data, 12, MH_DYLIB, ncmds)
        struct.pack_into("<I", data, 24, flags)
        report.append("MH_EXECUTE → MH_DYLIB")
    with open(dst, "wb") as f:
        f.write(data)
    os.chmod(dst, 0o755)
    return sorted(shims_used)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("--rpath", default="@loader_path/../Frameworks",
                   help="путь к Contents/Frameworks от файла (по умолчанию — для Contents/MacOS)")
    args = p.parse_args()
    report = []
    shims = convert(args.src, args.dst, report, args.rpath)
    for line in report:
        print(line)
    print("заменители:", " ".join(shims) or "—")


if __name__ == "__main__":
    main()
