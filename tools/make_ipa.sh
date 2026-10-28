#!/bin/sh
# make_ipa.sh — публичная сборка BG3iOS для AltStore/SideStore: заменители, Release (без служебного и без файлов
# игры) → build/BG3iOS.ipa. Подпись — ad hoc, только чтобы в IPA были права приложения (повышенный лимит памяти):
# AltStore переподписывает приложение сертификатом пользователя и запрашивает для него те же права. Профиля
# разработчика (с его устройствами и именем) в IPA нет.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
sh "$ROOT/shims/build.sh"
# Папки служебных ресурсов есть только у разработчика (в git их нет), а xcodegen без них не создаёт проект.
# В Release их содержимое всё равно убирается.
mkdir -p "$ROOT/lab/GameFiles" "$ROOT/lab/MacApps"
cd "$ROOT/lab"
xcodegen generate >/dev/null
xcodebuild -project MacportLab.xcodeproj -scheme MacportLab -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/build/lab" CODE_SIGNING_ALLOWED=NO -quiet build
APP="$ROOT/build/lab/Build/Products/Release-iphoneos/MacportLab.app"
for dev in GameFiles MacApps embedded.mobileprovision; do
    if [ -e "$APP/$dev" ]; then echo "в сборке остался $dev" >&2; exit 1; fi
done
OUT=$(mktemp -d)
mkdir "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
codesign -f -s - --entitlements "$ROOT/lab/Sources/MacportLab/MacportLab.entitlements" --timestamp=none \
    "$OUT/Payload/MacportLab.app"
rm -f "$ROOT/build/BG3iOS.ipa"
(cd "$OUT" && zip -qry "$ROOT/build/BG3iOS.ipa" Payload)
rm -rf "$OUT"
ls -l "$ROOT/build/BG3iOS.ipa"
