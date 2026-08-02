# Screen Time Guardian V1.0.9 Design

This document captures the approved implementation direction.

Last updated: 2026-08-02

## Product

- Name: Screen Time Guardian
- Developer: TimberTrail
- Version: V1.0.9
- License: Free to use

## Platform Strategy

- Windows: full mode with startup, tray, background timing, screen state detection, and rest prompts.
- macOS: full mode with startup, menu bar, background timing, sleep/wake detection, and rest prompts.
- Android: near-full mode using foreground service, usage stats, overlay permission, boot receiver, and battery optimization guidance.
- iPhone/iPad: Screen Time compliant mode using FamilyControls, DeviceActivity, DeviceActivityReport, and local notifications.

iOS/iPadOS records all-activity Screen Time thresholds where Apple's API provides callbacks. It can remind with local notifications, but cannot guarantee custom overlays across all apps.

## V1.0.9 Scope Notes

- This release aligns cross-platform settings, reminders, sync, history archive, notification localization, and version metadata.
- The iOS Screen Time timing model is intentionally unchanged in this release. It still relies on `DeviceActivityMonitor` threshold callbacks and App Group event import; timing-model changes will be handled separately.
- Historical data compaction is implemented as a local archive/summary foundation only. Active detailed records remain available until reports and trusted peer acknowledgements can safely rely on summaries.

## V1.0.9 Reminder And Permission Rules

- Rest reminders share one configurable eye-rest cycle across all platforms. The default is 3 minutes for faster testing. Odd cycles show the eye-rest reminder; even cycles show posture switch plus eye rest when posture switch is enabled.
- The posture-switch interval is derived from the eye-rest interval and is always 2x the eye-rest value; it is no longer independently editable.
- Meeting mode is the only state that allows immediate reminder dismissal. When meeting mode is on, the prompt says `会议模式：可以立即关闭`; when it is off, the close button is disabled until the countdown ends.
- Meeting mode notifications must be silent. Non-meeting iOS and Android reminder notifications should request/use notification sound when the user has allowed sound.
- Daily plan timeout reminders use the same dismissal rule as rest reminders. They should not claim meeting mode unless meeting mode is actually enabled.
- iOS and Android prompt countdowns are based on an absolute `can_close_at` time, not on decrementing a foreground timer. Returning from background, lock screen, or screen off must recompute the remaining time from wall-clock time.

## V1.0.9 Mobile Notification Permissions

- iOS requests notification alert, badge, and sound permission on first launch when the user has not decided yet.
- iOS settings show notification authorization, alert/banner availability, sound, alert style, and time-sensitive status, with a button to open the app's system settings. Persistent banner style remains a user-controlled iOS setting and cannot be forced by code.
- iOS Screen Time reminders use local notifications only. The app must never shield, block, or limit other apps. The notification is sounded only outside meeting mode.
- Android 13+ requests `POST_NOTIFICATIONS` at runtime. Android settings show notification permission, prompt channel sound status, and overlay permission, with buttons to open app notification settings, prompt channel settings, overlay permission, and battery optimization settings.
- Android prompt notifications use a separate high-importance reminder channel. Meeting-mode prompt notifications are sent silently.

## V1.0.9 Screen Time Data Import

- iOS Screen Time `DeviceActivityMonitor` threshold events are recorded to the App Group event log at the configurable checkpoint interval. The current default is 2 minutes.
- Silent checkpoint events are imported as incremental `screen_session` records. Every eye-rest interval also sends an eye-rest reminder, and every second reminder includes posture switching when that setting is enabled.
- Imported iOS Screen Time records use measurement scope `ios_screen_time_selected`, are included in local reports, and sync through the existing P2P `sync_snapshot` path like any other session.
- iOS Screen Time extension system notifications use the language selected in the app settings.
- The threshold/callback timing behavior itself is not changed in V1.0.9.

## V1.0.9 Daily Plan Input

- All platforms present daily planned screen time as hours plus minutes, for example `8 小时 0 分钟`.
- Storage and sync remain unchanged: `planned_daily_minutes` stores total minutes.
- Valid range remains 1 to 1440 minutes. A blank or zero value falls back to the default 480 minutes.

## V1.0.9 About Copy

- Every platform's About view explains that the app uses P2P sync across the user's own devices to calculate total screen time.
- The About view asks users to set the same sync code on every platform and recommends changing the default sync code.
- The About view states that the app does not use cloud storage and keeps data on local devices.
- The About view states that only approved devices can sync.

## V1.0.9 Windows Packaging

- Windows release builds are framework-dependent to reduce app size.
- Target machines need Microsoft .NET 8 Desktop Runtime x64.
- Release packages must include `ScreenTimeGuardian.exe`, `ScreenTimeGuardian.dll`, `.runtimeconfig.json`, `.deps.json`, and companion DLL files in the same extracted folder.
- If the runtime is missing, the .NET apphost detects the missing framework before app startup and shows the Microsoft download link.

## Core Record

The global aggregation unit is `screen_session`.

Required fields:

- `id`
- `device_id`
- `device_name`
- `platform`
- `measurement_scope`
- `start_at_utc`
- `start_timezone`
- `end_at_utc`
- `end_timezone`
- `duration_seconds`
- `stop_action`
- `created_at_utc`
- `updated_at_utc`
- `revision`
- `sync_status`

## Sync

Sync is local-first P2P. The old user-selected cloud-drive folder mode is removed from the product surface.

Each trusted device exchanges a `sync_snapshot` payload:

```text
shared/sync/sync-snapshot.schema.json
shared/sync/screen-session.schema.json
```

The transport should use local-network discovery plus encrypted peer exchange. Reports aggregate every locally stored `screen_session`, including sessions received from other platforms.

V1.0.9 sync transport details:

- Discovery uses Bonjour/DNS-SD service `_stg-sync._tcp.local`.
- Bonjour TXT, encrypted envelopes, and snapshots advertise protocol capabilities.
- Current V1.0.9 capabilities are `delta_sync`, `gzip`, and `history_compaction`.
- Trusted peers that support `delta_sync` receive only records and tombstones changed since their last successful sync, with a small overlap window.
- Trusted peers that support `gzip` receive gzip-compressed snapshot JSON before AES-GCM encryption.
- Capability negotiation is also used for historical-data behavior. A peer that has not advertised compatible history or acknowledgement capabilities must not be assumed to have accepted summary-only history.
- Capability names such as `weekly_manifest`, `daily_summary`, and `tombstone_ack` are reserved for later compatibility, but they are not active V1.0.9 behaviors.
- Current and previous week stay in the active detail store. Older records are also written to local-only weekly `.jsonl.gz` history archives and weekly summary JSON files under `history/`; the active detail store is not automatically pruned yet.
- History files are not exchanged through P2P in V1.0.9.

## LLM Ranking

The tracking target is OpenRouter prompt token ranking top 20 for the current week.

Rankings endpoint:

```text
/api/frontend/v1/rankings/models?view=week
```

Effective pricing endpoint:

```text
/api/frontend/v1/stats/effective-pricing?permaslug={model_permaslug}&variant={variant}
```

Columns:

- LLM name
- Prompt token count
- Output token count
- Weighted average input price
- Weighted average output price
- Weekly revenue

Formula:

```text
weekly_revenue =
  prompt_tokens * weighted_average_input_price
  + output_tokens * weighted_average_output_price
```

OpenRouter effective prices are treated as per 1M tokens:

```text
weekly_revenue =
  prompt_tokens / 1,000,000 * weighted_average_input_price_per_1m
  + output_tokens / 1,000,000 * weighted_average_output_price_per_1m
```
