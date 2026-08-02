#!/usr/bin/env bash
set -euo pipefail

APP_NAME="ScreenTimeGuardian"
BUNDLE_DIR="dist/${APP_NAME}.app"
MACOS_DIR="${BUNDLE_DIR}/Contents/MacOS"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE_DIR="${PWD}/build/module-cache"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-14.5}"

if [ ! -d "${SDK_PATH}" ]; then
  echo "Required macOS SDK not found: ${SDK_PATH}" >&2
  echo "Install Xcode or the Command Line Tools, then run xcode-select to choose them." >&2
  exit 1
fi

mkdir -p "${MACOS_DIR}" "${BUNDLE_DIR}/Contents/Resources" "${MODULE_CACHE_DIR}"
cp macos/Info.plist "${BUNDLE_DIR}/Contents/Info.plist"
cp macos/Assets/AppIcon.icns "${BUNDLE_DIR}/Contents/Resources/AppIcon.icns"

swiftc \
  -O \
  -sdk "${SDK_PATH}" \
  -target "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" \
  -module-cache-path "${MODULE_CACHE_DIR}" \
  -framework AppKit \
  -framework CryptoKit \
  -framework Foundation \
  -framework Network \
  -framework Security \
  -framework ServiceManagement \
  Sources/main.swift \
  -o "${MACOS_DIR}/${APP_NAME}"

touch "${BUNDLE_DIR}" "${BUNDLE_DIR}/Contents" "${MACOS_DIR}"

echo "Built ${BUNDLE_DIR}"
