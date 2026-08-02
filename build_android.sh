#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="${ROOT_DIR}/android"
OUTPUT_DIR="${ROOT_DIR}/dist/android"

if [ -z "${JAVA_HOME:-}" ]; then
  if [ -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  fi
fi

if [ -z "${ANDROID_HOME:-}" ]; then
  if [ -d "${HOME}/Library/Android/sdk" ]; then
    export ANDROID_HOME="${HOME}/Library/Android/sdk"
  fi
fi

if [ -x "${ANDROID_DIR}/gradlew" ]; then
  GRADLE="${ANDROID_DIR}/gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE="$(command -v gradle)"
elif [ -x "${HOME}/.gradle/wrapper/dists/gradle-8.14-all/c2qonpi39x1mddn7hk5gh9iqj/gradle-8.14/bin/gradle" ]; then
  GRADLE="${HOME}/.gradle/wrapper/dists/gradle-8.14-all/c2qonpi39x1mddn7hk5gh9iqj/gradle-8.14/bin/gradle"
elif [ -x "${HOME}/.gradle/wrapper/dists/gradle-8.12-all/ejduaidbjup3bmmkhw3rie4zb/gradle-8.12/bin/gradle" ]; then
  GRADLE="${HOME}/.gradle/wrapper/dists/gradle-8.12-all/ejduaidbjup3bmmkhw3rie4zb/gradle-8.12/bin/gradle"
else
  echo "Gradle not found. Open android/ in Android Studio once, or install Gradle." >&2
  exit 1
fi

if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME}/bin/java" ]; then
  echo "Java not found. Install a JDK or Android Studio." >&2
  exit 1
fi

if [ -z "${ANDROID_HOME:-}" ] || [ ! -d "${ANDROID_HOME}/platforms" ]; then
  echo "Android SDK not found. Set ANDROID_HOME." >&2
  exit 1
fi

(
  cd "${ANDROID_DIR}"
  "${GRADLE}" :app:assembleDebug
)

mkdir -p "${OUTPUT_DIR}"
cp "${ANDROID_DIR}/app/build/outputs/apk/debug/app-debug.apk" "${OUTPUT_DIR}/ScreenTimeGuardian-debug.apk"
echo "Built ${OUTPUT_DIR}/ScreenTimeGuardian-debug.apk"
