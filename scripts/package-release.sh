#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 0 ]]; then
  printf 'Usage: bash scripts/package-release.sh\n' >&2
  exit 1
fi

# build-app validates metadata before compilation and always creates a fresh bundle.
bash scripts/build-app.sh
VERSION=$(cat VERSION)
BUILD_NUMBER=$(cat BUILD_NUMBER)
APP="$PWD/dist/WorkJournal.app"
PLIST="$APP/Contents/Info.plist"
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST") == "$VERSION" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") == "$BUILD_NUMBER" ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST") == 'local.workjournal.app' ]]
[[ $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST") == '14.0' ]]
[[ $(lipo -archs "$APP/Contents/MacOS/WorkJournal") == 'arm64' ]]
codesign --verify --deep --strict "$APP"

STAGING_DIR=$(mktemp -d "$PWD/dist/.release-package.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
ARCHIVE_NAME="WorkJournal-${VERSION}-macOS-arm64"
ZIP_NAME="$ARCHIVE_NAME.zip"
DMG_NAME="$ARCHIVE_NAME.dmg"
mkdir -p "$STAGING_DIR/disk" "$STAGING_DIR/output" "$STAGING_DIR/zip-check"

# Stage only the distributable app and the standard install shortcut.
ditto --norsrc --noextattr --noacl "$APP" "$STAGING_DIR/disk/WorkJournal.app"
ln -s /Applications "$STAGING_DIR/disk/Applications"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$STAGING_DIR/output/$ZIP_NAME"
ditto -x -k "$STAGING_DIR/output/$ZIP_NAME" "$STAGING_DIR/zip-check"
codesign --verify --deep --strict "$STAGING_DIR/zip-check/WorkJournal.app"
hdiutil create -volname "WorkJournal $VERSION" -srcfolder "$STAGING_DIR/disk" \
  -format UDZO -fs HFS+ "$STAGING_DIR/output/$DMG_NAME"
hdiutil verify "$STAGING_DIR/output/$DMG_NAME"
(
  cd "$STAGING_DIR/output"
  shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

# Keep unrelated output files. Replace only the assets for this version and checksums.
mkdir -p "$PWD/dist/release"
mv -f "$STAGING_DIR/output/$ZIP_NAME" "$PWD/dist/release/$ZIP_NAME"
mv -f "$STAGING_DIR/output/$DMG_NAME" "$PWD/dist/release/$DMG_NAME"
mv -f "$STAGING_DIR/output/SHA256SUMS.txt" "$PWD/dist/release/SHA256SUMS.txt"
printf 'Release assets: %s\n' "$PWD/dist/release"
