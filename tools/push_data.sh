#!/bin/sh
# push_data.sh APP_DIR — докачать Contents/Data подготовленного приложения в Documents/MacApps на телефоне.
# Файл копируется, только если на телефоне его нет или размер другой; так обрыв (кабель, блокировка) не страшен —
# повторный запуск продолжит с недостающих. Сначала мелкие файлы и Gustav.pak, потом остальное по размеру.
# Места на телефоне скрипт не проверяет: при нехватке devicectl вернёт ошибку и копирование остановится.
# DRY=1 — только показать, что будет скопировано.
set -e
APP=$1
DEV=${DEVICE:-00008150-000415262178401C}
ID=com.redpax.macportlab
NAME=$(basename "$APP")
DATA="$APP/Contents/Data"
REMOTE="Documents/MacApps/$NAME/Contents/Data"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

xcrun devicectl device info files --device "$DEV" --domain-type appDataContainer --domain-identifier $ID \
    --subdirectory "$REMOTE" --json-output "$TMP/remote.json" >/dev/null 2>&1 || echo '{}' > "$TMP/remote.json"
# Список «размер путь» того, чего на телефоне нет или что другого размера; Gustav.pak — первым после мелких.
python3 -I - "$DATA" "$TMP/remote.json" > "$TMP/todo" <<'EOF'
import json, os, sys
data, remote = sys.argv[1], json.load(open(sys.argv[2]))
have = {f["relativePath"]: f["metadata"]["size"] for f in remote.get("result", {}).get("files", [])
        if not f["resources"]["isDirectory"]}
todo = []
for root, _, files in os.walk(data):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), data)
        size = os.path.getsize(os.path.join(root, f))
        if have.get(rel) != size:
            todo.append((0 if rel == "Gustav.pak" else 1, size if size < 2**30 else 2**40 + size, size, rel))
for _, _, size, rel in sorted(todo, key=lambda t: (t[1] >= 2**40, t[0], t[1])):
    print(size, rel)
EOF
count=$(wc -l < "$TMP/todo" | tr -d ' ')
total=$(awk '{s += $1} END {printf "%.1f", s / 1e9}' "$TMP/todo")
echo "докачать: $count файлов, $total ГБ"
[ "$DRY" = 1 ] && { cat "$TMP/todo"; exit 0; }
i=0
while read -r size rel; do
    i=$((i + 1))
    start=$(date +%s)
    if ! xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier $ID \
        --source "$DATA/$rel" --destination "$REMOTE/$rel" > "$TMP/out" 2>&1; then
        echo "ошибка на $rel:"; tail -5 "$TMP/out"; exit 1
    fi
    sec=$(( $(date +%s) - start ))
    echo "[$i/$count] $rel — $(awk -v s="$size" -v t="$sec" 'BEGIN {printf "%.2f ГБ за %d с, %.0f МБ/с", s/1e9, t, (t ? s/1e6/t : 0)}')"
done < "$TMP/todo"
echo "готово"
