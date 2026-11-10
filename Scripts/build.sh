#!/usr/bin/env bash
# Generates the Xcode project and builds Nexo (Debug by default).
# Usage: Scripts/build.sh [Debug|Release] [--run]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-Debug}"
cd "$root"

xcodegen generate --quiet

identity="Nexo Local Signing"
signArgs=()
if ! security find-identity -v -p codesigning | grep -q "\"$identity\""; then
  echo "warning: '$identity' not found (run Scripts/make-signing-cert.sh); falling back to ad-hoc signing." >&2
  signArgs=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual)
fi

mkdir -p build
log="build/last-build.log"
status=0
xcodebuild -project Nexo.xcodeproj -scheme Nexo -configuration "$config" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' \
  ${signArgs[@]+"${signArgs[@]}"} build >"$log" 2>&1 || status=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)|^/.*/Nexo/(App|Core|Modules)/.*warning:" "$log" || true
[[ $status -eq 0 ]] || { echo "Build failed (exit $status). Full log: $root/$log" >&2; exit "$status"; }

app="build/DerivedData/Build/Products/$config/Nexo.app"
echo "App: $root/$app"

if [[ "${2:-}" == "--run" ]]; then
  pkill -x Nexo 2>/dev/null || true
  open "$app"
fi
