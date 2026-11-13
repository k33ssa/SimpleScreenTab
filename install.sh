#!/bin/bash
# One-line installer/updater for SimpleScreenTab.
#   curl -fsSL https://raw.githubusercontent.com/k33ssa/SimpleScreenTab/master/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- uninstall
set -e

REPO="https://github.com/k33ssa/SimpleScreenTab.git"
APP="/Applications/SimpleScreenTab.app"
LABEL="local.simplescreentab"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "$1" = "uninstall" ]; then
  echo "Uninstalling SimpleScreenTab..."
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x SimpleScreenTab 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "Done. (Its Accessibility entry can be removed in System Settings -> Privacy & Security.)"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Xcode Command Line Tools are required. Installing..."
  xcode-select --install || true
  echo "Re-run this command once the tools finish installing."
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Fetching latest SimpleScreenTab..."
git clone --depth 1 "$REPO" "$TMP/src"
cd "$TMP/src"
bash build.sh
