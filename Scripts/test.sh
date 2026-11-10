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

xcodebuild -project Nexo.xcodeproj -scheme Nexo -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' \
  ${signArgs[@]+"${signArgs[@]}"} test 2>&1 \
  | grep -E "error:|Test Case .*(passed|failed)|Executed|TEST (SUCCEEDED|FAILED)"
