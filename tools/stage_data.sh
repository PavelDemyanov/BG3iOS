#!/bin/sh
# stage_data.sh SRC.app DST_DIR [skeleton|full] — данные игры (Contents/Data) к подготовленному приложению
# отдельно от бинарников: их копируют на телефон один раз.
# skeleton (по умолчанию) — без крупного контента (текстуры, модели, звук, видео, озвучка, Gustav.pak):
#   ~2.6 ГБ, хватает проверить старт движка, архивы, шейдеры и рендерер; full — все 145 ГБ (клонами APFS).
# У .metallib сбрасывается бит macOS в заголовке, как в stage_mac_app.sh.
set -e
SRC=$1; DST_DIR=$2; MODE=${3:-skeleton}
DST="$DST_DIR/$(basename "$SRC")/Contents/Data"
mkdir -p "$DST"
if [ "$MODE" = full ]; then
    # Клоны APFS (cp -c): 145 ГБ не занимают места на диске Mac. Уже лежащие файлы того же размера не трогаем.
    (cd "$SRC/Contents/Data" && find . -type f) | while read -r f; do
        [ -f "$DST/$f" ] && [ "$(stat -f %z "$DST/$f")" = "$(stat -f %z "$SRC/Contents/Data/$f")" ] && continue
        mkdir -p "$DST/$(dirname "$f")"
        cp -c "$SRC/Contents/Data/$f" "$DST/$f"
    done
else
    rsync -a --delete \
        --exclude "Gustav.pak" --exclude "Gustav_Textures.pak" --exclude "Gustav_Video.pak" --exclude "Gustav_NavCloud.pak" \
        --exclude "Models.pak" --exclude "SharedSounds.pak" --exclude "Textures*.pak" --exclude "VirtualTextures*.pak" \
        --exclude "Localization/Voice.pak" --exclude "Localization/English_Animations.pak" \
        "$SRC/Contents/Data/" "$DST/"
fi
find "$DST" -name "*.metallib" -print0 | xargs -0 -I{} python3 -I -c '
import sys
p = sys.argv[1]
with open(p, "r+b") as f:
    head = f.read(6)
    if head[:4] == b"MTLB" and head[5] == 0x80:
        f.seek(5); f.write(b"\0"); print("metallib:", p.rsplit("/", 1)[-1], "→ iOS")
' {}
du -sh "$DST"
