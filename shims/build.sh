#!/bin/sh
# Сборка заменителей под iOS arm64 в build/shims. Каждый — @rpath/MPX.dylib; заменитель существующего в iOS
# фреймворка реэкспортирует настоящий (-reexport_framework / -reexport_library).
set -e
cd "$(dirname "$0")"
OUT=../build/shims
mkdir -p "$OUT"
CC="xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -dynamiclib -O2 -Wall -fobjc-arc"
lib() { name=$1; shift; $CC -install_name "@rpath/$name.dylib" -current_version 1 -compatibility_version 1 "$@" -o "$OUT/$name.dylib"; }

lib MPAppKit MPAppKit.m -framework Foundation -framework QuartzCore -framework CoreGraphics -Wl,-reexport_framework,UIKit
lib MPCoreVideo MPCoreVideo.m -framework Foundation -framework UIKit -framework QuartzCore -Wl,-reexport_framework,CoreVideo
lib MPSystem MPSystem.c -lc++abi -Wl,-reexport_library,/usr/lib/libSystem.B.dylib
# Пустые — вместо фреймворков macOS, из которых программа ничего не берёт; у каждого своё имя.
for empty in MPEmpty MPCocoa MPCarbon MPOpenGL MPForceFeedback; do lib $empty MPEmpty.c; done
lib MPAudioUnit MPEmpty.c -Wl,-reexport_framework,AudioToolbox
lib MPCoreGraphics MPCoreGraphics.m -framework Foundation -framework UIKit -Wl,-reexport_framework,CoreGraphics
lib MPSecurity MPSecurity.c -framework CoreFoundation -Wl,-reexport_framework,Security
lib MPCoreServices MPCoreServices.c -framework CoreFoundation -Wl,-reexport_framework,CoreServices -Wl,-reexport_library,/usr/lib/libSystem.B.dylib
lib MPAudioToolbox MPAudioToolbox.c -Wl,-reexport_framework,AudioToolbox
lib MPCoreAudio MPCoreAudio.c -framework CoreFoundation -Wl,-reexport_framework,CoreAudio
lib MPMetal MPMetal.m -framework Foundation -framework QuartzCore -framework UIKit -framework GameController -Wl,-reexport_framework,Metal
# Замена libsteam_api.dylib игры: то же имя установки, что у оригинала.
xcrun -sdk iphoneos clang++ -arch arm64 -miphoneos-version-min=17.0 -dynamiclib -O2 -Wall -std=c++17 \
    -install_name @rpath/libsteam_api.dylib MPSteam.cpp -o "$OUT/libsteam_api.dylib"
ls -l "$OUT"
