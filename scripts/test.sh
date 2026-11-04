#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
SWIFT_BIN=$(dirname "$(xcrun --find swift)")
PLUGIN="$SWIFT_BIN/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -f "$PLUGIN" ]]; then
  swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" --disable-sandbox --cache-path "$PWD/.build/cache" "$@"
else
  swift test --disable-sandbox --cache-path "$PWD/.build/cache" "$@"
fi
