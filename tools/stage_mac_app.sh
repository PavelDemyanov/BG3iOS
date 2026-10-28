#!/bin/sh
# stage_mac_app.sh SRC.app DST_DIR [ИДЕНТИЧНОСТЬ]
# Готовит Mac-приложение к запуску на iOS:
# - копия в DST_DIR (SKIP_DATA=1 — без Contents/Data: данные кладёт stage_data.sh, уже лежащие не трогаются);
# - каждый Mach-O (главный файл и библиотеки в Contents/Frameworks) — через macport_convert.py, rpath —
#   путь от файла к Contents/Frameworks;
# - libsteam_api.dylib игры заменяется нашей (build/shims/libsteam_api.dylib), заменители — в Contents/Frameworks;
# - у .metallib сброшен бит macOS в заголовке;
# - каждый Mach-O подписан отдельно (вне бандла) той же идентичностью, что и приложение-хост.
set -e
SRC=$1; DST_DIR=$2; ID=${3:-"Apple Development: redpax@mail.ru (JBE9G67DN9)"}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=$(basename "$SRC")
DST="$DST_DIR/$NAME"
mkdir -p "$DST_DIR"
if [ "$SKIP_DATA" = 1 ]; then
    # Contents/Data не трогается: её кладёт stage_data.sh (исключённое rsync --delete не удаляет).
    rsync -a --delete --exclude "Contents/Data" --exclude "Contents/_CodeSignature" --exclude "*.log" "$SRC/" "$DST/"
else
    rm -rf "$DST"
    rsync -a --exclude "Contents/_CodeSignature" "$SRC/" "$DST/"
fi
FW="$DST/Contents/Frameworks"
mkdir -p "$FW"

# rpath от каталога файла до Contents/Frameworks.
rpath_for() {
    rel=$(python3 -I -c 'import os,sys; print(os.path.relpath(sys.argv[2], os.path.dirname(sys.argv[1])))' "$1" "$FW")
    [ "$rel" = "." ] && echo "@loader_path" || echo "@loader_path/$rel"
}

find "$DST/Contents/MacOS" "$FW" -type f | while read -r f; do
    file "$f" | grep -q "Mach-O" || continue
    case "$f" in
        */libsteam_api.dylib) cp "$ROOT/build/shims/libsteam_api.dylib" "$f"; echo "steam: заменён ${f#$DST/}"; continue ;;
    esac
    python3 -I "$ROOT/tools/macport_convert.py" --rpath "$(rpath_for "$f")" "$f" "$f.conv" > "$f.report" || { cat "$f.report"; exit 1; }
    mv "$f.conv" "$f"
    python3 -I "$ROOT/tools/patch_binary.py" "$f"  # правки байтов для известных игр (tools/patch_binary.py)
    echo "конвертирован: ${f#$DST/} ($(grep '^заменители' "$f.report"))"
    rm "$f.report"
done
cp "$ROOT"/build/shims/MP*.dylib "$FW/"

# metallib: u16 по смещению 4 — 0x8001 у macOS, 0x0001 у iOS.
find "$DST" -name "*.metallib" -print0 | xargs -0 -I{} python3 -I -c '
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
    head = f.read(6)
    if head[:4] == b"MTLB" and head[5] == 0x80:
        f.seek(5); f.write(b"\0"); print("metallib:", p.rsplit("/", 1)[-1], "→ iOS")
' {}

# Сначала Frameworks, потом главный файл. Каждый — копией вне бандла: внутри Contents codesign подписал бы
# файл как бандл (с печатью ресурсов), а такую подпись iOS не принимает.
{ find "$FW" -type f; find "$DST/Contents/MacOS" -type f; } | while read -r f; do
    file "$f" | grep -q "Mach-O" || continue
    tmp=$(mktemp -d); cp "$f" "$tmp/x"
    codesign -f -s "$ID" --timestamp=none "$tmp/x" 2>&1 | grep -v "replacing existing signature" || true
    cp "$tmp/x" "$f"; rm -rf "$tmp"
    if codesign -dvv "$f" 2>&1 | grep -q "TeamIdentifier=not set"; then echo "НЕ подписан: ${f#$DST/}"; exit 1; fi
done
echo "подписано Mach-O: $(find "$FW" "$DST/Contents/MacOS" -type f -exec file {} \; | grep -c Mach-O)"
