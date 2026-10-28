#!/usr/bin/env python3
"""Правки байтов в сконвертированном Mac-бинарнике (до подписи): адрес в памяти, ожидаемые байты, новые байты.
Байты не совпали (другая версия игры) — правка пропускается с предупреждением.

patch_binary.py ФАЙЛ   (правки выбираются по UUID-независимому признаку: имени файла)
"""

import os
import struct
import sys

# BG3 4.1.1 (Mac): ожидание подгрузки {минимум 0,5 с, максимум 20 с} — один литерал в __const на шесть
# мест (экран загрузки ecl::LoadProtocol → GameStatePrepareRunning, затемнения, ролики, использование
# предметов). Подгрузка на телефоне дольше 20 с, и экран снимался раньше: Т-позы, пустые текстуры. Максимум — 60 с.
#
# BaseApp::InitFrameStages добавляет в список этапов кадра набор SHADOW_BUFFER_PACK (этап каскадов теней солнца)
# дважды — до SECOND_PACK и после; второй раз каскады перерисовываются в тот же массив глубины теми же вызовами
# (≈9 млн треугольников на кадр в Нижнем городе), картинка без него та же. Второе добавление (blr на
# InitFrameStages(view, span)) заменено на nop.
PATCHES = {
    "Baldur's Gate 3": [
        ("ожидание подгрузки: максимум 20 → 60 с", 0x10786db60,
         struct.pack("<ff", 0.5, 20.0), struct.pack("<ff", 0.5, 60.0)),
        ("каскады теней — один раз за кадр", 0x105d1a830,
         struct.pack("<I", 0xD63F0100), struct.pack("<I", 0xD503201F)),
    ],
}


def segments(data):
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x19:
            vm, vms, fo, fs = struct.unpack_from("<QQQQ", data, off + 24)
            yield vm, vms, fo
        off += size


def main():
    path = sys.argv[1]
    patches = PATCHES.get(os.path.basename(path), [])
    if not patches:
        return
    data = bytearray(open(path, "rb").read())
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        sys.exit(f"{path}: не тонкий arm64 Mach-O")
    segs = list(segments(data))
    for title, addr, old, new in patches:
        fo = next((fo + addr - vm for vm, vms, fo in segs if vm <= addr < vm + vms), None)
        if fo is None or bytes(data[fo:fo + len(old)]) != old:
            print(f"правка пропущена (другие байты): {title}")
            continue
        data[fo:fo + len(new)] = new
        print(f"правка: {title}")
    open(path, "wb").write(data)


if __name__ == "__main__":
    main()
