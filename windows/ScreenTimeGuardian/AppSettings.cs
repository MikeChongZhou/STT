using System.Text.Json.Serialization;

namespace ScreenTimeGuardian;

internal sealed class AppSettings
{
    public const int MinimumPairingCodeLength = 6;

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = Environment.MachineName;

    [JsonPropertyName("language")]
    public string Language { get; set; } = "zh";

    [JsonPropertyName("tracking_object")]
    public string TrackingObject { get; set; } = "LLM Ranking";

    [JsonPropertyName("data_directory")]
    public string DataDirectory { get; set; } = "";

    [JsonPropertyName("p2p_sync_enabled")]
    public bool P2PSyncEnabled { get; set; } = true;

    [JsonPropertyName("p2p_pairing_code")]
    public string P2PPairingCode { get; set; } = Random.Shared.Next(100000, 999999).ToString();

    [JsonPropertyName("p2p_sync_interval_minutes")]
    public int P2PSyncIntervalMinutes { get; set; } = 5;

    [JsonPropertyName("trusted_peer_ids")]
    public List<string> TrustedPeerIds { get; set; } = [];

    [JsonPropertyName("rejected_peer_ids")]
    public List<string> RejectedPeerIds { get; set; } = [];

    [JsonPropertyName("peer_sync_states")]
    public List<PeerSyncState> PeerSyncStates { get; set; } = [];

    [JsonPropertyName("posture_interval_minutes")]
    public int PostureIntervalMinutes { get; set; } = 6;

    [JsonPropertyName("posture_switch_enabled")]
    public bool PostureSwitchEnabled { get; set; } = true;

    [JsonPropertyName("eye_rest_interval_minutes")]
    public int EyeRestIntervalMinutes { get; set; } = 3;

    [JsonPropertyName("posture_rest_interval_minutes")]
    public int PostureRestIntervalMinutes { get; set; } = 6;

    [JsonPropertyName("planned_daily_minutes")]
    public int PlannedDailyMinutes { get; set; } = 480;

    [JsonPropertyName("last_weekly_plan_minutes")]
    public int? LastWeeklyPlanMinutes { get; set; }

    [JsonPropertyName("last_timeout_prompt_at_utc")]
    public DateTimeOffset? LastTimeoutPromptAtUtc { get; set; }

    [JsonPropertyName("last_timeout_prompt_date")]
    public string? LastTimeoutPromptDate { get; set; }

    [JsonPropertyName("meeting_mode")]
    public bool MeetingMode { get; set; }

    [JsonPropertyName("auto_start_enabled")]
    public bool AutoStartEnabled { get; set; } = true;

    public AppSettings Clone()
    {
        return new AppSettings
        {
            DeviceId = DeviceId,
            DeviceName = DeviceName,
            Language = Language,
            TrackingObject = TrackingObject,
            DataDirectory = DataDirectory,
            P2PSyncEnabled = P2PSyncEnabled,
            P2PPairingCode = P2PPairingCode,
            P2PSyncIntervalMinutes = P2PSyncIntervalMinutes,
            TrustedPeerIds = TrustedPeerIds.ToList(),
            RejectedPeerIds = RejectedPeerIds.ToList(),
            PeerSyncStates = PeerSyncStates
                .Select(state => state.Clone())
                .ToList(),
            PostureIntervalMinutes = PostureIntervalMinutes,
            PostureSwitchEnabled = PostureSwitchEnabled,
            EyeRestIntervalMinutes = EyeRestIntervalMinutes,
            PostureRestIntervalMinutes = PostureRestIntervalMinutes,
            PlannedDailyMinutes = PlannedDailyMinutes,
            LastWeeklyPlanMinutes = LastWeeklyPlanMinutes,
            LastTimeoutPromptAtUtc = LastTimeoutPromptAtUtc,
            LastTimeoutPromptDate = LastTimeoutPromptDate,
            MeetingMode = MeetingMode,
            AutoStartEnabled = AutoStartEnabled
        };
    }

    public void Normalize()
    {
        if (string.IsNullOrWhiteSpace(DeviceId))
        {
            DeviceId = Guid.NewGuid().ToString();
        }

        DeviceName = string.IsNullOrWhiteSpace(DeviceName) ? Environment.MachineName : DeviceName.Trim();
        Language = Language == "en" ? "en" : "zh";
        TrackingObject = string.IsNullOrWhiteSpace(TrackingObject) ? "LLM Ranking" : TrackingObject.Trim();
        DataDirectory = string.IsNullOrWhiteSpace(DataDirectory) ? "" : DataDirectory.Trim();
        P2PPairingCode = NormalizePairingCode(P2PPairingCode);
        P2PSyncIntervalMinutes = Math.Clamp(P2PSyncIntervalMinutes, 1, 1440);
        TrustedPeerIds = NormalizePeerIds(TrustedPeerIds);
        RejectedPeerIds = NormalizePeerIds(RejectedPeerIds)
            .Where(id => !TrustedPeerIds.Contains(id, StringComparer.OrdinalIgnoreCase))
            .ToList();
        PeerSyncStates = PeerSyncStates
            .Where(state => !string.IsNullOrWhiteSpace(state.DeviceId) &&
                !string.Equals(state.DeviceId, DeviceId, StringComparison.OrdinalIgnoreCase))
            .GroupBy(state => state.DeviceId.Trim(), StringComparer.OrdinalIgnoreCase)
            .Select(group => group
                .OrderByDescending(state => state.LastSyncAtUtc)
                .First()
                .Normalized())
            .OrderByDescending(state => state.LastSyncAtUtc)
            .ToList();
        PostureIntervalMinutes = Math.Clamp(PostureIntervalMinutes, 1, 1440);
        EyeRestIntervalMinutes = Math.Clamp(EyeRestIntervalMinutes, 1, 1440);
        PostureRestIntervalMinutes = DerivedPostureRestIntervalMinutes(EyeRestIntervalMinutes);
        PlannedDailyMinutes = Math.Clamp(PlannedDailyMinutes, 1, 1440);
    }

    public static int DerivedPostureRestIntervalMinutes(int eyeRestIntervalMinutes)
    {
        return Math.Clamp(Math.Max(1, eyeRestIntervalMinutes) * 2, 1, 1440);
    }

    public static string GeneratePairingCode()
    {
        return Random.Shared.Next(100000, 999999).ToString();
    }

    public static string NormalizePairingCode(string? value)
    {
        var digits = new string((value ?? "").Where(char.IsDigit).Take(MinimumPairingCodeLength).ToArray());
        if (digits.Length == 0)
        {
            return GeneratePairingCode();
        }

        return digits.PadRight(MinimumPairingCodeLength, '0');
    }

    public static List<string> NormalizeCapabilities(IEnumerable<string>? values)
    {
        return (values ?? [])
            .Select(value => value.Trim().ToLowerInvariant())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static List<string> NormalizePeerIds(IEnumerable<string>? values)
    {
        return (values ?? [])
            .Select(value => value.Trim())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }
}

internal sealed class PeerSyncState
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("last_sync_at_utc")]
    public DateTimeOffset LastSyncAtUtc { get; set; }

    [JsonPropertyName("capabilities")]
    public List<string> Capabilities { get; set; } = [];

    public PeerSyncState Clone()
    {
        return new PeerSyncState
        {
            DeviceId = DeviceId,
            LastSyncAtUtc = LastSyncAtUtc,
            Capabilities = Capabilities.ToList()
        };
    }

    public PeerSyncState Normalized()
    {
        return new PeerSyncState
        {
            DeviceId = DeviceId.Trim(),
            LastSyncAtUtc = LastSyncAtUtc,
            Capabilities = AppSettings.NormalizeCapabilities(Capabilities)
        };
    }
}
