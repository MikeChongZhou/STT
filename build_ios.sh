#!/usr/bin/env bash
set -euo pipefail

PROJECT="iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS.xcodeproj"
SCHEME="ScreenTimeGuardianIOS"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-build/ios-derived}"
DESTINATION="${IOS_DESTINATION:-generic/platform=iOS}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required to build the iOS app. Current developer tools are not enough." >&2
  exit 1
fi

if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  echo "iPhoneOS SDK not found. Install full Xcode and select it with xcode-select." >&2
  exit 1
fi

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED}" \
  build
