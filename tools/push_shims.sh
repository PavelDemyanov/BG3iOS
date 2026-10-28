#!/bin/sh
# push_shims.sh APP_DIR [ЗАМЕНИТЕЛЬ…] — положить свежие заменители из build/shims в подготовленное приложение
# (Contents/Frameworks), подписать их (копией вне бандла, как stage_mac_app.sh) и напечатать список для
# ONLY= в run_on_phone.sh. Без имён — все MP*.dylib и libsteam_api.dylib.
set -e
APP=$1; shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ID=${IDENTITY:-"Apple Development: redpax@mail.ru (JBE9G67DN9)"}
[ $# -gt 0 ] || set -- $(cd "$ROOT/build/shims" && ls MP*.dylib libsteam_api.dylib)
list=""
for name in "$@"; do
    f="$APP/Contents/Frameworks/$name"
    tmp=$(mktemp -d); cp "$ROOT/build/shims/$name" "$tmp/x"
    codesign -f -s "$ID" --timestamp=none "$tmp/x" 2>/dev/null
    cp "$tmp/x" "$f"; rm -rf "$tmp"
    list="$list Contents/Frameworks/$name"
done
echo "$list"
