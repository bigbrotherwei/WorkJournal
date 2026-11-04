#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release -debug-info-format none
BIN_DIR=$(swift build --disable-sandbox --cache-path "$PWD/.build/cache" -c release -debug-info-format none --show-bin-path)
APP="$PWD/dist/WorkJournal.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/WorkJournal" "$APP/Contents/MacOS/WorkJournal"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WorkJournal</string>
<key>CFBundleIdentifier</key><string>local.workjournal.app</string>
<key>CFBundleName</key><string>工作随记</string>
<key>CFBundleDisplayName</key><string>工作随记</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.22.0</string>
<key>CFBundleVersion</key><string>28</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
