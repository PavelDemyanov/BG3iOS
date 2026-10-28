#!/bin/sh
# Сборка hello-mac под macOS (arm64) как .app: программа и hello.metallib в Resources.
set -e
cd "$(dirname "$0")"
OUT=../../build/hello-mac/hello-mac.app/Contents
mkdir -p "$OUT/MacOS" "$OUT/Resources"
xcrun -sdk macosx clang -arch arm64 -mmacos-version-min=11.0 -fobjc-arc -O2 -Wall \
    -framework AppKit -framework Metal -framework QuartzCore -framework CoreVideo \
    main.m -o "$OUT/MacOS/hello-mac"
xcrun -sdk macosx metal -c hello.metal -o ../../build/hello-mac/hello.air
xcrun -sdk macosx metallib ../../build/hello-mac/hello.air -o "$OUT/Resources/hello.metallib"
cat > "$OUT/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>hello-mac</string>
<key>CFBundleIdentifier</key><string>com.redpax.hello-mac</string>
<key>CFBundleName</key><string>hello-mac</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
codesign -f -s - "$OUT/.." >/dev/null 2>&1
echo "built: $OUT/.."
