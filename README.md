# Screen Time Guardian

Screen Time Guardian V1.0.9 is a cross-device screen time guardian app designed by TimberTrail.

This repository currently contains:

- A runnable macOS menu bar app.
- An iOS/iPadOS SwiftUI Xcode project with foreground tracking, reports, settings, OpenRouter tracking, Screen Time authorization, all-activity DeviceActivity threshold monitoring, shared Screen Time event logging, and Screen Time usage reports. It only records and reminds; it does not block apps.
- A Windows tray app scaffold under `windows/`.
- An Android app scaffold under `android/`.
- A shared P2P sync contract under `shared/sync/`.

## Current macOS Features

- Starts as a menu bar app named `STG`.
- Records screen usage sessions.
- Ends the current session on report opening, sleep, screen sleep, lock, wake transitions, and app exit.
- Shows report, settings, tracking, about, and quit menu items.
- Shows configurable eye rest prompts, defaulting to 3 minutes for testing.
- Shows posture switch prompts on every second eye-rest reminder cycle when posture switch is enabled.
- Supports meeting mode, which allows rest prompts to close immediately.
- Stores local data in `~/Library/Application Support/ScreenTimeGuardian`.
- Uses local-first screen session storage with the shared P2P sync contract.
- Supports weekly plan prompts on Mondays.
- Supports daily timeout reminders after the planned daily screen time is exceeded.
- Reads OpenRouter LLM Ranking cache files from local app storage.
- Fetches OpenRouter weekly prompt-token Top 20 when the current-week cache is missing or the user refreshes tracking data.
- Reports last week's average daily screen time across all synced platforms, plus per-platform averages.

## Build

macOS:

```sh
bash build_macos.sh
```

The app bundle is created at:

```text
dist/ScreenTimeGuardian.app
```

iOS/iPadOS:

```text
iOS/ScreenTimeGuardianIOS/ScreenTimeGuardianIOS.xcodeproj
```

Open the project in full Xcode, set your Apple Developer Team, enable the Family Controls capability and the `group.com.timbertrail.screentimeguardian` App Group for the app, monitor extension, and report extension targets, then build for an iPhone/iPad simulator or device.

For local compile validation without signing:

```sh
bash build_ios.sh
```

Windows:

```powershell
cd windows\ScreenTimeGuardian
dotnet run
```

Published Windows builds are framework-dependent to keep the app small. Install Microsoft .NET 8 Desktop Runtime x64 if the target machine does not already have it:

```text
https://dotnet.microsoft.com/download/dotnet/8.0/runtime
```

Use the generated `ScreenTimeGuardian-<version>-win-x64.zip` package and extract the full zip before running. Do not copy `ScreenTimeGuardian.exe` alone; the `.runtimeconfig.json`, `.deps.json`, and companion DLL files must stay next to it.

Android:

```text
android/
```

Open the Android folder in Android Studio.

## OpenRouter LLM Ranking

The tracking window first reads the current ISO week file:

```text
ScreenTimeGuardian/tracking/llm-ranking/YYYY-WW.json
```

If the file does not exist, or if the user clicks refresh, the app fetches:

```text
https://openrouter.ai/api/frontend/v1/rankings/models?view=week
https://openrouter.ai/api/frontend/v1/stats/effective-pricing?permaslug=MODEL&variant=VARIANT
```

The app sorts the returned weekly rows by `total_prompt_tokens` descending. The top 20 rows are enriched with `weightedInputPrice` and `weightedOutputPrice`.

OpenRouter effective prices are treated as USD per 1M tokens:

```text
weekly_revenue =
  prompt_tokens / 1,000,000 * weighted_average_input_price
  + output_tokens / 1,000,000 * weighted_average_output_price
```

Example:

```json
{
  "week_id": "2026-W27",
  "period_start": "2026-06-29",
  "period_end": "2026-07-05",
  "source": "openrouter",
  "fetched_at_utc": "2026-06-30T12:00:00Z",
  "rows": [
    {
      "rank": 1,
      "llm_name": "example-model",
      "prompt_tokens": 1000000,
      "output_tokens": 250000,
      "weighted_average_input_price": 0.000001,
      "weighted_average_output_price": 0.000003,
      "weekly_revenue": 1.75
    }
  ]
}
```

## Sync

Screen usage data now targets P2P sync instead of a cloud-drive folder. See:

```text
docs/P2P_SYNC.md
shared/sync/
```

To pair devices, open Settings on each device and enter the same six-digit P2P pairing code. Devices on the same LAN discover peers through Bonjour/mDNS and exchange encrypted screen-session snapshots over TCP.

## Next Targets

- Run cross-device LAN smoke tests across macOS, iOS, Windows, and Android hardware.
- Add a stable OpenRouter data adapter once the exact ranking source endpoint is finalized.
- Complete Windows startup packaging and richer report/settings UI.
- Complete Android foreground service collection, boot receiver, and battery optimization guidance.
