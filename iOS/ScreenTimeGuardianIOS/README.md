# Screen Time Guardian iOS

This folder contains the iOS/iPadOS SwiftUI app project for Screen Time Guardian V1.0.9.

## Current Scope

- Records all-activity Screen Time checkpoints by default. App foreground sessions are only used as a fallback when system Screen Time recording is turned off.
- Ends fallback foreground sessions when the app goes inactive/background.
- Provides Report, Settings, Tracking, and About views; Screen Time recording is controlled from Settings permissions.
- Shows foreground eye-rest and posture-switch prompts while the app is active.
- Requests FamilyControls authorization and uses the system Family Activity picker to save the apps/categories/websites that should be counted.
- Includes a DeviceActivityMonitor extension that records selected-activity Screen Time checkpoints at the configured interval, sends local notifications on the configured eye-rest cycle, and logs shared threshold events. It does not block or shield apps.
- Includes a DeviceActivityReport extension that shows all-activity Screen Time usage totals in the Report view.
- Uses Bonjour/TCP for local P2P discovery on iOS, matching macOS, Windows, and Android.
- Uses the shared P2P sync contract instead of a cloud-drive directory.
- Shows last week's average daily screen time across synced platforms, plus per-platform averages.
- Fetches OpenRouter weekly model rankings from:

```text
https://openrouter.ai/api/frontend/v1/rankings/models?view=week
```

- Sorts by `total_prompt_tokens`, takes top 20, fetches effective pricing, and calculates weekly revenue.
- Reads/writes JSON data under the app support directory.

## Screen Time API

iOS/iPadOS cannot provide the same full-device always-on behavior as the macOS app. The Settings permissions section requests FamilyControls authorization, asks for notification permission, and lets the user choose the apps/categories/websites that should be counted. The app does not shield or block selected apps.

The monitor extension handles threshold callbacks by writing shared Screen Time event logs through the App Group container. Checkpoints are recorded silently for the selected activity scope; each eye-rest threshold also sends an eye-rest or posture reminder based on the current settings. The extension deliberately does not shield or block apps. The main app imports those event logs as `ios_screen_time_selected` sessions so they can be included in local reports and P2P sync snapshots. The report extension provides system Screen Time totals. Extension notifications follow the language selected in the app settings.

## Build

Open this project in Xcode:

```text
iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS.xcodeproj
```

Then set your Apple Developer Team on `ScreenTimeGuardianIOS`, `ScreenTimeGuardianMonitorExtension`, and `ScreenTimeGuardianReportExtension` before building.

Family Controls and the `group.com.timbertrail.screentimeguardian` App Group must be enabled for the Apple Developer account and for all three targets' signing profiles.

For local compile validation without signing, run from the repository root:

```sh
bash build_ios.sh
```
