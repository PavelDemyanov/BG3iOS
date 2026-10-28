#!/bin/sh
# install_dev.sh [UDID] — публичная сборка (Release), подписанная сертификатом разработчика, на телефон рядом
# с установленной через AltStore/AltServer: «BG3iOS Dev» (com.redpax.macportlab, у AltServer — с суффиксом команды).
# Сертификат для игры — тот же разработчика: Signing Certificate → Import .p12 File (iOS грузит библиотеки игры,
# только если их подписала команда приложения). Данные приложения при переустановке сохраняются.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UDID=${1:-00008150-000415262178401C}
ID=${IDENTITY:-"Apple Development: redpax@mail.ru (JBE9G67DN9)"}
sh "$ROOT/shims/build.sh"
cd "$ROOT/lab"
xcodegen generate >/dev/null
xcodebuild -project MacportLab.xcodeproj -scheme MacportLab -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$ROOT/build/lab-dev" -allowProvisioningUpdates -quiet build
APP="$ROOT/build/lab-dev/Build/Products/Release-iphoneos/MacportLab.app"
XCENT="$ROOT/build/lab-dev/Build/Intermediates.noindex/MacportLab.build/Release-iphoneos/MacportLab.build/MacportLab.app.xcent"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 'BG3iOS Dev'" "$APP/Info.plist"
codesign -f -s "$ID" --entitlements "$XCENT" --timestamp=none "$APP"
codesign --verify --strict "$APP"
xcrun devicectl device install app --device "$UDID" "$APP"
