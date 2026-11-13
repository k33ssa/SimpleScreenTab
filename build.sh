#!/bin/bash
# Build SimpleScreenTab.app from main.swift, install to /Applications, set login item, launch.
set -e
cd "$(dirname "$0")"

APP="/Applications/SimpleScreenTab.app"
LABEL="local.simplescreentab"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Compiling..."
mkdir -p build
swiftc -O main.swift -o build/SimpleScreenTab -framework Cocoa -framework ApplicationServices -framework ServiceManagement

echo "Stopping running instance..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x SimpleScreenTab 2>/dev/null || true
sleep 0.5

echo "Assembling app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/SimpleScreenTab "$APP/Contents/MacOS/SimpleScreenTab"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SimpleScreenTab</string>
  <key>CFBundleDisplayName</key><string>SimpleScreenTab</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>SimpleScreenTab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLISTEOF

echo "Signing..."
ID=$(security find-identity -p codesigning 2>/dev/null | awk "/ScreenTab Local Signing/{print \$2; exit}"); codesign --force --deep --sign "${ID:--}" "$APP"

# новая подпись = старая галочка недействительна; сбросить, чтобы macOS спросила заново
if [ -z "$ID" ]; then tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true; fi

echo "Installing login item..."
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/SimpleScreenTab</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
PLISTEOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo
echo "Installed. If Cmd-Tab is not overridden yet, grant Accessibility:"
echo "  System Settings -> Privacy & Security -> Accessibility -> enable SimpleScreenTab"
