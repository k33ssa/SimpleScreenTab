#!/bin/bash
# Maintainer script: ./release.sh 1.0.0
# Builds a universal SimpleScreenTab.app, zips it, publishes a GitHub release
# and bumps the cask in k33ssa/homebrew-tap.
set -euo pipefail
cd "$(dirname "$0")"
VER="${1:?usage: ./release.sh <version>}"
NAME=SimpleScreenTab
OUT="dist"
APP="$OUT/$NAME.app"
ZIP="$OUT/$NAME-$VER.zip"

rm -rf "$OUT" && mkdir -p "$OUT" build
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" main.swift -o "build/$NAME-$arch" \
    -framework Cocoa -framework ApplicationServices -framework ServiceManagement
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "build/$NAME-arm64" "build/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
cp AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.simplescreentab</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# one stable certificate for every release -> Accessibility grant survives updates
ID=$(security find-identity -p codesigning | awk '/ScreenTab Local Signing/{print $2; exit}')
codesign --force --deep --sign "${ID:?signing identity missing}" "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')

gh release create "v$VER" "$ZIP" -R k33ssa/$NAME --title "$NAME $VER" --notes-file - <<EOF
Per-monitor Cmd-Tab for macOS: the switcher lists only the apps on the display under your mouse.

## Downloads

| Platform | File | Install |
|---|---|---|
| macOS 13+ (Apple Silicon + Intel) | [$NAME-$VER.zip](https://github.com/k33ssa/$NAME/releases/download/v$VER/$NAME-$VER.zip) | \`brew install --cask k33ssa/tap/simplescreentab\` |

macOS only: the app is built on macOS window and Accessibility APIs, there is no Windows or Linux version.

**Update:** \`brew upgrade --cask simplescreentab\`. Automatic background updates: \`brew tap homebrew/autoupdate && brew autoupdate start --upgrade --cleanup\`.

**Zip without Homebrew:** unzip, move $NAME.app to Applications, open it. The app is free and not notarized; if macOS refuses to open it, run \`xattr -dr com.apple.quarantine /Applications/$NAME.app\` once. Grant Accessibility when asked.
EOF

# bump cask in the tap
TAP=$(mktemp -d)
gh repo clone k33ssa/homebrew-tap "$TAP" -- -q
sed -i '' -E "s/version \"[^\"]+\"/version \"$VER\"/; s/sha256 \"[^\"]+\"/sha256 \"$SHA\"/" "$TAP/Casks/simplescreentab.rb"
git -C "$TAP" commit -qam "simplescreentab $VER" && git -C "$TAP" push -q
rm -rf "$TAP"
echo "released $VER  sha256=$SHA"
