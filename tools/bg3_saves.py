#!/usr/bin/env python3
"""Сохранения BG3: уровень, время и герой из SaveInfo.json внутри .lsv (архив LSPK v18, оглавление в LZ4).

bg3_saves.py [ПАПКА Story]   (по умолчанию — Mac-сохранения пользователя)
"""

import json
import os
import struct
import sys
import zlib

DEFAULT = os.path.expanduser("~/Documents/Larian Studios/Baldur's Gate 3/PlayerProfiles/Public/Savegames/Story")


def lz4_block(src, size):
    """Распаковка блока LZ4 (без кадра), size — размер результата."""
    out = bytearray()
    i = 0
    while i < len(src):
        token = src[i]
        i += 1
        literal = token >> 4
        if literal == 15:
            while True:
                b = src[i]
                i += 1
                literal += b
                if b != 255:
                    break
        out += src[i:i + literal]
        i += literal
        if i >= len(src) or len(out) >= size:
            break
        offset = src[i] | src[i + 1] << 8
        i += 2
        match = token & 15
        if match == 15:
            while True:
                b = src[i]
                i += 1
                match += b
                if b != 255:
                    break
        match += 4
        start = len(out) - offset
        for k in range(match):
            out.append(out[start + k])
    return bytes(out[:size])


def lspk_files(path):
    data = open(path, "rb").read()
    if data[:4] != b"LSPK":
        return {}
    version, list_offset, list_size = struct.unpack_from("<IQI", data, 4)
    count, compressed = struct.unpack_from("<II", data, list_offset)
    table = lz4_block(data[list_offset + 8:list_offset + 8 + compressed], count * 272)
    files = {}
    for n in range(count):
        e = table[n * 272:(n + 1) * 272]
        name = e[:256].split(b"\0", 1)[0].decode(errors="replace")
        lo, hi, part, flags, disk, size = struct.unpack_from("<IHBBII", e, 256)
        files[name] = (lo | hi << 32, flags & 0xF, disk, size)

    def read(name):
        offset, method, disk, size = files[name]
        raw = data[offset:offset + disk]
        if method == 0:
            return raw
        if method == 1:
            return zlib.decompress(raw)
        if method == 2:
            return lz4_block(raw, size)
        if method == 3:  # zstd — через утилиту zstd (Homebrew), модуля в Python нет
            import subprocess
            return subprocess.run(["zstd", "-dc"], input=raw, capture_output=True, check=True).stdout
        raise ValueError(f"сжатие {method} не поддержано")

    return {name: (lambda name=name: read(name)) for name in files}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    rows = []
    for folder in sorted(os.listdir(root)):
        lsv = [f for f in os.listdir(os.path.join(root, folder)) if f.endswith(".lsv")]
        if not lsv:
            continue
        path = os.path.join(root, folder, lsv[0])
        try:
            files = lspk_files(path)
            info = json.loads(files["SaveInfo.json"]()) if "SaveInfo.json" in files else {}
        except Exception as error:
            info = {"ошибка": str(error)}
        rows.append((os.path.getmtime(path), folder, info))
    for _, folder, info in sorted(rows):
        level = info.get("Current Level", info.get("ошибка", "?"))
        when = info.get("Save Time", {})
        hero = info.get("Active Party", {}).get("Characters", [{}])[0].get("Origin", "") if isinstance(info.get("Active Party"), dict) else ""
        game = info.get("Game Time", info.get("Total Play Time", ""))
        print(f"{level:24} {str(game):10} {folder}  {hero}")


if __name__ == "__main__":
    main()
