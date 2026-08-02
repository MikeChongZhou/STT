using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed record WeeklySummary(
    [property: JsonPropertyName("week_id")] string WeekId,
    [property: JsonPropertyName("planned_daily_minutes")] int PlannedDailyMinutes,
    [property: JsonPropertyName("previous_week_total_seconds")] int PreviousWeekTotalSeconds,
    [property: JsonPropertyName("previous_week_average_daily_seconds")] int PreviousWeekAverageDailySeconds,
    [property: JsonPropertyName("created_by_device_id")] string CreatedByDeviceId,
    [property: JsonPropertyName("created_at_utc")] DateTimeOffset CreatedAtUtc);

internal sealed record HistoricalWeeklyUsageSummary(
    [property: JsonPropertyName("week_id")] string WeekId,
    [property: JsonPropertyName("period_start")] string PeriodStart,
    [property: JsonPropertyName("period_end")] string PeriodEnd,
    [property: JsonPropertyName("total_seconds")] int TotalSeconds,
    [property: JsonPropertyName("source_session_count")] int SourceSessionCount,
    [property: JsonPropertyName("platforms")] IReadOnlyList<PlatformUsageSummary> Platforms,
    [property: JsonPropertyName("devices")] IReadOnlyList<DeviceUsageSummary> Devices,
    [property: JsonPropertyName("created_by_device_id")] string CreatedByDeviceId,
    [property: JsonPropertyName("created_at_utc")] DateTimeOffset CreatedAtUtc);
