#!/bin/sh
# bench_bg3.sh ИМЯ [ПЕРЕМЕННАЯ=ЗНАЧЕНИЕ …] — замер BG3 в Нижнем городе: загрузка сохранения «Каменный зал»,
# профиль Time Profiler 160 с (build/bench-ИМЯ.trace) с переменными окружения, затем:
# - профиль по 10-секундным окнам (последние — игра после загрузки): всего ядер, P-ядра, главные потоки;
# - журнал хоста за последние 50 с: FPS, время видеокарты на кадр, её занятость, нагрев.
# SAVE="…" — другое сохранение (имя папки), SECONDS_=… — длительность.
set -e
NAME=$1; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=${DEVICE:-00008150-000415262178401C}
ID=com.redpax.macportlab
SAVE=${SAVE:-"Карлах-18161232286__Каменный зал - 7ч 36м"}
LIMIT=${SECONDS_:-160}
ENVS=""
for kv in "$@"; do ENVS="$ENVS --env $kv"; done
cd "$ROOT"
xcrun devicectl device copy to --device "$DEV" --domain-type appDataContainer --domain-identifier $ID \
    --source /dev/null --destination Documents/mac.log >/dev/null 2>&1
rm -rf "build/bench-$NAME.trace"
# shellcheck disable=SC2086
xcrun xctrace record --device "$DEV" --template 'Time Profiler' --time-limit "${LIMIT}s" \
    --output "build/bench-$NAME.trace" $ENVS --launch -- $ID --mac "Baldur's Gate 3" --fps -loadSaveGame "$SAVE" \
    >/dev/null 2>&1
xcrun xctrace export --input "build/bench-$NAME.trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "build/bench-$NAME.xml" 2>/dev/null
echo "== $NAME $*"
python3 -I tools/profile_timeline.py "build/bench-$NAME.xml" 10 | sed -n '1p;$!p' | tail -6
xcrun devicectl device copy from --device "$DEV" --domain-type appDataContainer --domain-identifier $ID \
    --source Documents/mac.log --destination "build/bench-$NAME.log" >/dev/null 2>&1
grep "кадров/с" "build/bench-$NAME.log" | tail -5 | sed 's/.*кадров\/с/кадров\/с/'
