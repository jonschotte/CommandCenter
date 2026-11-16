#!/bin/zsh
# Builds "Command Center.app" without Xcode/SwiftPM (uses swiftc directly).
set -e
cd "$(dirname "$0")"
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | tail -1)
[ -n "$SDK" ] && export SDKROOT="$SDK"
TARGET=arm64-apple-macos14.0
mkdir -p build

if [ ! -f build/libSwiftTerm.a ] || [ "$1" = "--clean" ]; then
  echo "▶ Building SwiftTerm…"
  swiftc -O -parse-as-library -module-name SwiftTerm -target $TARGET \
    -emit-module -emit-module-path build/SwiftTerm.swiftmodule \
    -emit-library -static -o build/libSwiftTerm.a \
    $(find Vendor/SwiftTerm/Sources/SwiftTerm -name "*.swift" -not -path "*/iOS/*") Vendor/SwiftTermExtra/BuildInfo.swift
fi

echo "▶ Building cc-keeper…"
cc -O2 -Wall -o build/cc-keeper Keeper/cc-keeper.c

echo "▶ Building Command Center…"
swiftc -O -parse-as-library -module-name CommandCenter -target $TARGET \
  -I build -L build -lSwiftTerm \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Charts -framework UserNotifications -framework Metal -framework MetalKit -framework CoreText \
  Sources/CommandCenter/*.swift -o build/CommandCenter

APP="build/Command Center.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/CommandCenter "$APP/Contents/MacOS/CommandCenter"
cp build/cc-keeper "$APP/Contents/MacOS/cc-keeper"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Command Center</string>
  <key>CFBundleDisplayName</key><string>Command Center</string>
  <key>CFBundleIdentifier</key><string>local.commandcenter</string>
  <key>CFBundleExecutable</key><string>CommandCenter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Command Center mirrors and types into your Terminal and iTerm2 sessions so you can control them from one place.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
SIGN="$HOME/Documents/Code Projects/Chief of Staff/tools/sign.sh"
if [ -x "$SIGN" ]; then "$SIGN" "$APP" local.commandcenter; else codesign --force --sign - "$APP" >/dev/null 2>&1 || true; fi
echo "✅ Built: $APP"
[ "$1" = "--install" ] && { rm -rf "/Applications/Command Center.app"; cp -R "$APP" /Applications/ && echo "✅ Installed to /Applications"; }
exit 0
