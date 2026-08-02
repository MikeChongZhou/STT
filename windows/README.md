# Screen Time Guardian Windows

This folder contains the Windows tray implementation.

## Scope

- Windows tray app named `STG`.
- Records screen sessions with the shared `screen_session` schema.
- Ends sessions on lock, suspend, shutdown, and app exit.
- Stores local data in `%LOCALAPPDATA%\ScreenTimeGuardian`.
- Uses the shared P2P sync contract in `../shared/sync`.
- Includes encrypted TCP sync with Bonjour/mDNS LAN discovery.
- Provides editable settings for device name, posture switch, planned daily hours/minutes, P2P enablement, and pairing code.
- Shows discovered paired devices and supports manual sync from the tray or settings window.

## Build

Install .NET 8 SDK on Windows, then run:

```powershell
cd windows\ScreenTimeGuardian
dotnet run
```

From macOS with a local SDK installed at `.dotnet`, publish a Windows build from the repository root:

```bash
./build_windows.sh
```

The published app is written to `dist/windows/`. It is framework-dependent to keep the executable small. Use the generated `ScreenTimeGuardian-<version>-win-x64.zip` package and extract the full zip before running. Do not copy `ScreenTimeGuardian.exe` alone; the `.runtimeconfig.json`, `.deps.json`, and companion DLL files must stay next to it.

Target Windows machines need Microsoft .NET 8 Desktop Runtime x64:

```text
https://dotnet.microsoft.com/download/dotnet/8.0/runtime
```

If the runtime is missing, the .NET app host detects it before the app starts and shows the missing framework plus Microsoft download link.
