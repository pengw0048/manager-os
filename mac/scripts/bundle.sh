#!/bin/sh
# Build ManagerOS.app (release, ad-hoc signed, no sandbox) into mac/build/.
set -e
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/ManagerOS.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ManagerOS" "$APP/Contents/MacOS/ManagerOS"
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.manager-os</string>
  <key>CFBundleName</key><string>Manager OS</string>
  <key>CFBundleDisplayName</key><string>Manager OS</string>
  <key>CFBundleExecutable</key><string>ManagerOS</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Opens Claude sessions in Terminal.</string>
</dict></plist>
EOF
codesign --force --deep -s - "$APP"
echo "Built $APP"
