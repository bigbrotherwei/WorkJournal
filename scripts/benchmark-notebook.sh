#!/bin/bash
# Run scripts/test.sh first, or pass an existing SwiftPM Xcode build-products directory.
set -euo pipefail
cd "$(dirname "$0")/.."
products="${1:-$PWD/.build/out/Products/Debug}"
if [[ $# -eq 0 && ! -f "$products/JournalCore.o" ]]; then products="$PWD/.build/debug"; fi
if [[ ! -f "$products/JournalCore.o" || ! -f "$products/SwiftSoup.o" ]]; then
  echo "Build JournalCore first, then pass its out/Products/Debug directory." >&2
  exit 1
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/workjournal-benchmark.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swiftc scripts/benchmark-notebook.swift "$products/JournalCore.o" "$products/SwiftSoup.o" \
  -I "$products" -I Sources/CSQLite -target "$(uname -m)-apple-macos14.0" -lsqlite3 \
  -o "$temporary/benchmark"
"$temporary/benchmark"
