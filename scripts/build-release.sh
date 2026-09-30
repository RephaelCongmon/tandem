#!/bin/bash
# Builds a signed Release Tandem.app and packages it as dist/Tandem-<version>.zip and .dmg.
# Notarize afterwards with: xcrun notarytool submit dist/Tandem-<version>.dmg --keychain-profile <profile> --wait
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$ROOT/App" && xcodegen generate >/dev/null)
xcodebuild -project "$ROOT/App/Tandem.xcodeproj" -scheme Tandem -configuration Release \
  -derivedDataPath "$ROOT/build/Release.noindex" -destination 'platform=macOS' build 2>&1 | grep -E "error:|BUILD" | tail -2
APP="$ROOT/build/Release.noindex/Build/Products/Release/Tandem.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/Tandem-$VERSION.zip" "$ROOT/dist/Tandem-$VERSION.dmg"
ditto -c -k --keepParent "$APP" "$ROOT/dist/Tandem-$VERSION.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Tandem $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$ROOT/dist/Tandem-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
# The build copy isn't where people run Tandem from; keep it out of LaunchServices.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
echo "✓ dist/Tandem-$VERSION.zip and dist/Tandem-$VERSION.dmg"
