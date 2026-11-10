#!/usr/bin/env bash
# Runs the NexoTests unit tests.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
xcodegen generate --quiet

signArgs=()
if ! security find-identity -v -p codesigning | grep -q '"Nexo Local Signing"'; then
  signArgs=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

mkdir -p build
log="build/last-test.log"
status=0
xcodebuild -project Nexo.xcodeproj -scheme Nexo -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' \
  ${signArgs[@]+"${signArgs[@]}"} test >"$log" 2>&1 || status=$?
grep -E "error:|Test Case .*failed|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)" "$log" || true
[[ $status -eq 0 ]] || { echo "Tests failed (exit $status). Full log: $root/$log" >&2; exit "$status"; }
