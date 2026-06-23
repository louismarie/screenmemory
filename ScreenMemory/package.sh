#!/bin/bash
# Package ScreenMemory as a signed .app bundle so TCC (Screen Recording) sticks.
set -e
cd "$(dirname "$0")"

echo "[1/5] build release"
swift build -c release >/dev/null 2>&1

BIN=.build/release/ScreenMemory
RESBUNDLE=.build/release/ScreenMemory_ScreenMemory.bundle
APP="$HOME/Applications/ScreenMemory.app"

echo "[2/5] bundle skeleton -> $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScreenMemory</string>
    <key>CFBundleDisplayName</key><string>ScreenMemory</string>
    <key>CFBundleIdentifier</key><string>com.screenmemory.app</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleExecutable</key><string>ScreenMemory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ScreenMemory indexes on-screen text for local semantic search.</string>
</dict>
</plist>
PLIST

echo "[3/5] copy binary + resource bundle"
cp "$BIN" "$APP/Contents/MacOS/ScreenMemory"
# Resources/ only: a copy next to the executable makes codesign reject the bundle
# ("bundle format unrecognized" on the nested .bundle subcomponent).
cp -R "$RESBUNDLE" "$APP/Contents/Resources/"

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ]; then
  echo "[4/5] codesign with stable identity: $IDENTITY"
  codesign --force --deep --identifier com.screenmemory.app --sign "$IDENTITY" "$APP"
else
  echo "[4/5] ad-hoc codesign (TCC resets after binary changes)"
  codesign --force --deep --identifier com.screenmemory.app --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Sealed" || true

echo "[5/5] done -> $APP"
