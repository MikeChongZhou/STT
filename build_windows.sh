#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET="${DOTNET:-${ROOT_DIR}/.dotnet/dotnet}"
PROJECT="${ROOT_DIR}/windows/ScreenTimeGuardian/ScreenTimeGuardian.csproj"
OUTPUT="${ROOT_DIR}/dist/windows"
VERSION="$(awk -F'[<>]' '/<Version>/ { print $3; exit }' "${PROJECT}")"
PACKAGE="${OUTPUT}/ScreenTimeGuardian-${VERSION}-win-x64.zip"

if [ ! -x "${DOTNET}" ]; then
  if command -v dotnet >/dev/null 2>&1; then
    DOTNET="$(command -v dotnet)"
  else
    echo "dotnet not found. Install .NET 8 SDK or place it at ${ROOT_DIR}/.dotnet/dotnet." >&2
    exit 1
  fi
fi

"${DOTNET}" publish "${PROJECT}" \
  --configuration Release \
  --runtime win-x64 \
  --self-contained false \
  --output "${OUTPUT}" \
  -p:PublishSingleFile=false \
  -p:DebugType=None \
  -p:DebugSymbols=false

echo "Built ${OUTPUT}/ScreenTimeGuardian.exe"
echo "Requires Microsoft .NET 8 Desktop Runtime x64: https://dotnet.microsoft.com/download/dotnet/8.0/runtime"

if command -v zip >/dev/null 2>&1; then
  (
    cd "${OUTPUT}"
    zip -q -FS "${PACKAGE}" \
      ScreenTimeGuardian.exe \
      ScreenTimeGuardian.dll \
      ScreenTimeGuardian.deps.json \
      ScreenTimeGuardian.runtimeconfig.json \
      Microsoft.Windows.SDK.NET.dll \
      WinRT.Runtime.dll
  )
  echo "Packaged ${PACKAGE}"
  echo "Extract the full zip before running; do not copy ScreenTimeGuardian.exe alone."
else
  echo "zip not found; copy the full ${OUTPUT} directory to Windows before running."
fi
