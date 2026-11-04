#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then
  printf 'Usage: bash scripts/build-app.sh\n' >&2
  exit 1
fi
VERSION=$(cat VERSION)
BUILD_NUMBER=$(cat BUILD_NUMBER)
if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'VERSION must contain three nonnegative integers, for example 0.22.0.\n' >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]; then
  printf 'BUILD_NUMBER must contain a positive integer of up to nine digits.\n' >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
export MACOSX_DEPLOYMENT_TARGET=14.0
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --arch arm64 -c release -debug-info-format none
BIN_DIR=$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" --arch arm64 -c release -debug-info-format none --show-bin-path)
APP="$PWD/dist/WorkJournal.app"
mkdir -p "$PWD/dist"
STAGING_DIR=$(mktemp -d "$PWD/dist/.app-build.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/WorkJournal.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/WorkJournal" "$STAGED_APP/Contents/MacOS/WorkJournal"
cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WorkJournal</string>
<key>CFBundleIdentifier</key><string>local.workjournal.app</string>
<key>CFBundleName</key><string>工作随记</string>
<key>CFBundleDisplayName</key><string>工作随记</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
# Replace only this generated app, after the fresh bundle has passed validation.
rm -rf "$APP"
mv "$STAGED_APP" "$APP"
printf 'Built: %s\n' "$APP"
