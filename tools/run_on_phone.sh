#!/bin/sh
# run_on_phone.sh APP_DIR [СЕКУНД] — отправить подготовленное Mac-приложение в Documents/MacApps
# MacportLab на телефоне, запустить его там (--mac ИМЯ) и через СЕКУНД (20 по умолчанию) забрать журнал
# Documents/mac.log в build/mac.log. NOCOPY=1 — не копировать приложение (уже на телефоне);
# ONLY="Contents/Frameworks/MPAppKit.dylib …" — скопировать только эти файлы приложения.
# ENVJSON='{"MP_TRACE_FS":"1"}' — переменные окружения программы.
# ARGS="-NoLauncher YES" — дополнительные аргументы программе (вида -Ключ значение попадают в NSUserDefaults).
# Телефон должен быть разблокирован: пока он заблокирован, запуск повторяется.
set -e
APP=$1; WAIT=${2:-20}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEV=${DEVICE:-00008150-000415262178401C}
ID=com.redpax.macportlab
NAME=$(basename "$APP" .app)
dc() { a=$1; b=$2; shift 2; xcrun devicectl device "$a" "$b" --device "$DEV" "$@"; }
if [ -n "$ONLY" ]; then
    for f in $ONLY; do
        dc copy to --domain-type appDataContainer --domain-identifier $ID --source "$APP/$f" \
            --destination "Documents/MacApps/$NAME.app/$f" >/dev/null
        echo "скопировано: $f"
    done
elif [ "$NOCOPY" != 1 ]; then
    dc copy to --domain-type appDataContainer --domain-identifier $ID --source "$APP" \
        --destination "Documents/MacApps/$NAME.app" >/dev/null
    echo "скопировано: $NAME.app"
fi
dc copy to --domain-type appDataContainer --domain-identifier $ID --source /dev/null --destination Documents/mac.log >/dev/null
i=0
until out=$(dc process launch --terminate-existing ${ENVJSON:+--environment-variables "$ENVJSON"} $ID -- --mac "$NAME" $ARGS 2>&1); ! echo "$out" | grep -q Locked; do
    i=$((i + 1)); [ $i -gt 30 ] && { echo "телефон заблокирован"; exit 1; }
    [ $i = 1 ] && echo "телефон заблокирован — жду разблокировки"
    sleep 5
done
echo "$out" | grep -q "Launched application" || { echo "$out"; exit 1; }
sleep "$WAIT"
dc copy from --domain-type appDataContainer --domain-identifier $ID --source Documents/mac.log \
    --destination "$ROOT/build/mac.log" >/dev/null
alive=$(xcrun devicectl device info processes --device "$DEV" 2>/dev/null | grep -c "MacportLab.app/MacportLab" || true)
echo "журнал: build/mac.log ($(wc -l < "$ROOT/build/mac.log") строк), процесс $([ "$alive" -gt 0 ] && echo жив || echo завершён)"
