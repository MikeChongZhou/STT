# Screen Time Guardian Android

This folder contains the Android implementation.

## Scope

- Native Android app.
- Uses a foreground service, screen state broadcasts, and Android Usage Access signals for screen usage collection.
- Stores records with the shared `screen_session` schema.
- Uses the shared P2P sync contract in `../shared/sync`.
- Includes encrypted TCP sync with Android NSD/Bonjour LAN discovery.
- Reports aggregate all synced platform sessions.
- Includes settings, daily/multi-day reports, OpenRouter LLM Ranking tracking, rest prompts, posture prompts, daily plan prompts, boot restart, and overlay/notification prompt fallback.

## Build

From the repository root:

```bash
./build_android.sh
```

The script uses Android Studio's bundled JBR and the local Android SDK when they are available, then copies the debug APK to:

```text
dist/android/ScreenTimeGuardian-debug.apk
```

You can also open this folder in Android Studio. The project uses a native Kotlin app module:

```text
android/settings.gradle.kts
android/app/build.gradle.kts
```

Runtime permissions are requested in app where possible. Usage Access, overlay permission, and battery optimization settings must still be approved from Android system settings.
