using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class ScreenSession
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "windows";

    [JsonPropertyName("measurement_scope")]
    public string MeasurementScope { get; set; } = "global_exact";

    [JsonPropertyName("start_at_utc")]
    public DateTimeOffset StartAtUtc { get; set; }

    [JsonPropertyName("start_timezone")]
    public string StartTimezone { get; set; } = TimeZoneInfo.Local.Id;

    [JsonPropertyName("end_at_utc")]
    public DateTimeOffset? EndAtUtc { get; set; }

    [JsonPropertyName("end_timezone")]
    public string? EndTimezone { get; set; }

    [JsonPropertyName("duration_seconds")]
    public int DurationSeconds { get; set; }

    [JsonPropertyName("stop_action")]
    public string? StopAction { get; set; }

    [JsonPropertyName("heartbeat_at_utc")]
    public DateTimeOffset? HeartbeatAtUtc { get; set; }

    [JsonPropertyName("created_at_utc")]
    public DateTimeOffset CreatedAtUtc { get; set; }

    [JsonPropertyName("updated_at_utc")]
    public DateTimeOffset UpdatedAtUtc { get; set; }

    [JsonPropertyName("revision")]
    public int Revision { get; set; } = 1;

    [JsonPropertyName("sync_status")]
    public string SyncStatus { get; set; } = "local";
}
