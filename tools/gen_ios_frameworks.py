#!/usr/bin/env python3
"""Таблица путей фреймворков iOS (имя → install-name из .tbd SDK) для kit/Sources/MacportPrep/IOSFrameworks.swift:
переделка Mac-бинарников на телефоне не может спросить SDK. Перезапускать при смене SDK."""

import glob
import os
import re
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sdk = subprocess.run(["xcrun", "-sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True, check=True).stdout.strip()
ver = subprocess.run(["xcrun", "-sdk", "iphoneos", "--show-sdk-version"], capture_output=True, text=True).stdout.strip()
paths = {}
for tbd in glob.glob(f"{sdk}/System/Library/Frameworks/*.framework/*.tbd"):
    m = re.search(r"^install-name:\s+'?([^'\n]+?)'?\s*$", open(tbd, errors="ignore").read(), re.M)
    if m:
        paths[os.path.basename(tbd)[:-4]] = m.group(1)
lines = "\n".join(f'        "{k}": "{v}",' for k, v in sorted(paths.items()))
with open(os.path.join(ROOT, "kit/Sources/MacportPrep/IOSFrameworks.swift"), "w") as f:
    f.write(f"""// Пути фреймворков iOS по имени — из .tbd iOS SDK {ver} (tools/gen_ios_frameworks.py): на телефоне SDK нет.
// Не у всех плоская раскладка: IOKit в iOS — Versions/A.

enum IOSFrameworks {{
    static let installNames: [String: String] = [
{lines}
    ]
}}
""")
print(len(paths), "фреймворков")
