#!/bin/bash
# Invalid release metadata must fail before the compiler or bundle output is touched.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/workjournal-metadata-test.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
FIXTURE="$TEMP_DIR/repository with spaces"
mkdir -p "$FIXTURE/scripts" "$TEMP_DIR/bin"
cp "$ROOT/scripts/build-app.sh" "$FIXTURE/scripts/build-app.sh"
cat > "$TEMP_DIR/bin/swift" <<'STUB'
#!/bin/bash
touch "$COMPILER_MARKER"
exit 91
STUB
chmod +x "$TEMP_DIR/bin/swift"
export PATH="$TEMP_DIR/bin:$PATH"
export COMPILER_MARKER="$TEMP_DIR/compiler-called"

expect_invalid() {
  local version="$1" build="$2" label="$3"
  printf '%s\n' "$version" > "$FIXTURE/VERSION"
  printf '%s\n' "$build" > "$FIXTURE/BUILD_NUMBER"
  rm -f "$COMPILER_MARKER"
  if bash "$FIXTURE/scripts/build-app.sh" > "$TEMP_DIR/output" 2>&1; then
    printf 'FAIL: accepted invalid %s\n' "$label" >&2
    exit 1
  fi
  if [[ -e "$COMPILER_MARKER" || -e "$FIXTURE/dist" ]]; then
    printf 'FAIL: invalid %s reached compilation or changed output\n' "$label" >&2
    exit 1
  fi
}

expect_invalid '' '28' 'empty version'
expect_invalid 'v0.22.0' '28' 'tag-prefixed version'
expect_invalid '0.22' '28' 'incomplete version'
expect_invalid '0.22.0-beta' '28' 'prerelease version'
expect_invalid '0.22.0/../other' '28' 'path in version'
expect_invalid '0.022.0' '28' 'leading zero in version'
expect_invalid $'0.22.0\nother' '28' 'multiline version'
expect_invalid '0.22.0' '' 'empty build number'
expect_invalid '0.22.0' '0' 'zero build number'
expect_invalid '0.22.0' '01' 'leading zero in build number'
expect_invalid '0.22.0' '-1' 'negative build number'
expect_invalid '0.22.0' '28.1' 'noninteger build number'
expect_invalid '0.22.0' '99999999999999999999' 'oversized build number'

printf '0.22.0\n' > "$FIXTURE/VERSION"
printf '28\n' > "$FIXTURE/BUILD_NUMBER"
rm -f "$COMPILER_MARKER"
if bash "$FIXTURE/scripts/build-app.sh" > "$TEMP_DIR/output" 2>&1; then
  printf 'FAIL: expected compiler stub to stop the valid build\n' >&2
  exit 1
fi
[[ -e "$COMPILER_MARKER" ]] || { cat "$TEMP_DIR/output" >&2; exit 1; }
printf 'Release metadata checks passed (13 invalid cases and a valid build boundary).\n'
