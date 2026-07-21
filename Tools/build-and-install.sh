#!/bin/sh
# Builds a Release build and installs it as /Applications/Ledge.app,
# so Cmd+Space always launches the version built by this script.
set -e

cd "$(dirname "$0")/.."

BUILD_DIR="build/install"
rm -rf "$BUILD_DIR"

xcodebuild -project Ledge.xcodeproj -scheme Ledge -configuration Release \
  -derivedDataPath "$BUILD_DIR" build

APP="$BUILD_DIR/Build/Products/Release/Ledge.app"

osascript -e 'quit app "Ledge"' 2>/dev/null || true
sleep 1

rm -rf /Applications/Ledge.app
cp -R "$APP" /Applications/Ledge.app
rm -rf "$BUILD_DIR"

echo "Installed /Applications/Ledge.app"
