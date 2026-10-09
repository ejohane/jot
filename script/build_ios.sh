#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -d Web/node_modules ]] || npm --prefix Web ci
npm --prefix Web run build
xcodegen generate --spec apps/ios/project.yml
if [[ "${1:-}" == --device ]]; then
  : "${JOT_DEVICE_ID:?Set JOT_DEVICE_ID to the paired iPhone UDID}"
  xcodebuild -project apps/ios/JotIOS.xcodeproj -scheme JotIOS \
    -destination "platform=iOS,id=$JOT_DEVICE_ID" -derivedDataPath .build/ios-device \
    -allowProvisioningUpdates build
  xcrun devicectl device install app --device "$JOT_DEVICE_ID" .build/ios-device/Build/Products/Debug-iphoneos/JotIOS.app
  xcrun devicectl device process launch --device "$JOT_DEVICE_ID" --terminate-existing com.erikjohansson.Jot.ios
else
  xcodebuild -project apps/ios/JotIOS.xcodeproj -scheme JotIOS \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios-sim build
fi
