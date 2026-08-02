using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class SyncSnapshot
{
    [JsonPropertyName("protocol_version")]
    public int ProtocolVersion { get; set; } = 1;

    [JsonPropertyName("capabilities")]
    public List<string> Capabilities { get; set; } = [];

    [JsonPropertyName("device")]
    public SyncDeviceInfo Device { get; set; } = new();

    [JsonPropertyName("cursor")]
    public SyncCursor? Cursor { get; set; }

    [JsonPropertyName("sessions")]
    public List<ScreenSession> Sessions { get; set; } = [];

    [JsonPropertyName("deleted_sessions")]
    public List<DeletedSession> DeletedSessions { get; set; } = [];
}

internal sealed class DeletedSession
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("session_id")]
    public string? SessionId { get; set; }

    [JsonPropertyName("device_id")]
    public string? DeviceId { get; set; }

    [JsonPropertyName("start_at_utc")]
    public DateTimeOffset? StartAtUtc { get; set; }

    [JsonPropertyName("end_at_utc")]
    public DateTimeOffset? EndAtUtc { get; set; }

    [JsonPropertyName("deleted_by_device_id")]
    public string DeletedByDeviceId { get; set; } = "";

    [JsonPropertyName("deleted_at_utc")]
    public DateTimeOffset DeletedAtUtc { get; set; }

    [JsonPropertyName("updated_at_utc")]
    public DateTimeOffset UpdatedAtUtc { get; set; }
}

internal sealed class SyncDeviceInfo
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("platform")]
    public string Platform { get; set; } = "windows";

    [JsonPropertyName("app_version")]
    public string AppVersion { get; set; } = "V1.0.9";

    [JsonPropertyName("capabilities")]
    public List<string> Capabilities { get; set; } = [];

    [JsonPropertyName("updated_at_utc")]
    public DateTimeOffset UpdatedAtUtc { get; set; } = DateTimeOffset.UtcNow;
}

internal sealed class SyncCursor
{
    [JsonPropertyName("since_updated_at_utc")]
    public DateTimeOffset? SinceUpdatedAtUtc { get; set; }
}
