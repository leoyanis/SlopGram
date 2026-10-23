#!/usr/bin/env bash
# Builds SlopLab (the simulator stand-in) from the same SlopGram sources the tweak uses.
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-build}"
SRC=../src/SlopGram
APP="$OUT/SlopLab.app"
THEOS="${THEOS:-$HOME/theos}"

rm -rf "$APP" && mkdir -p "$APP" "$OUT/gen"
"$THEOS/vendor/logos/bin/logos.pl" "$SRC/SGHooks.xm" > "$OUT/gen/SGHooks.mm"
"$THEOS/vendor/logos/bin/logos.pl" "$SRC/SGSideload.xm" > "$OUT/gen/SGSideload.mm"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" \
    -fobjc-arc -fmodules -O0 -g -Wall -Wno-unused-function -I"$SRC" \
    "$SRC/SGEngine.m" "$SRC/SGGate.m" "$SRC/SGOverlayView.m" "$OUT/gen/SGHooks.mm" "$OUT/gen/SGSideload.mm" Harness.m \
    -framework UIKit -framework AVFoundation -framework Security -framework QuartzCore -lc++ \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __entitlements -Xlinker entitlements.plist \
    -o "$APP/SlopLab"

cp Info.plist "$APP/Info.plist"
if [ ! -f "$OUT/sample.mp4" ]; then
    ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=360x640:rate=30:duration=4" -pix_fmt yuv420p -c:v libx264 "$OUT/sample.mp4"
fi
cp "$OUT/sample.mp4" "$APP/sample.mp4"
codesign -s - --force "$APP" >/dev/null 2>&1
echo "$APP"
