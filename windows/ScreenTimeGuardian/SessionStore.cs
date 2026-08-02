using System.Text.Json;
using System.Security.Cryptography;
using System.Text;
using System.IO.Compression;
using Microsoft.Win32;

namespace ScreenTimeGuardian;

internal sealed class SessionStore
{
    private const int OpenSessionHeartbeatValiditySeconds = 120;
    private const int SyncCursorOverlapSeconds = 10;
    private readonly object gate = new();
    private readonly string configDirectory;
    private string appDirectory;
    private string sessionsPath;
    private string deletedSessionsPath;
    private readonly string settingsPath;
    private readonly string identityPath;
    private string weeklySummariesDirectory;
    private string trackingDirectory;
    private string historyDirectory;
    private string historySessionsDirectory;
    private string historySummariesDirectory;
    private readonly JsonSerializerOptions jsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public SessionStore()
    {
        configDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ScreenTimeGuardian");
        settingsPath = Path.Combine(configDirectory, "settings.json");
        identityPath = Path.Combine(configDirectory, "device_id");
        appDirectory = DefaultDataDirectory();
        sessionsPath = Path.Combine(appDirectory, "sessions.json");
        deletedSessionsPath = Path.Combine(appDirectory, "deleted_sessions.json");
        weeklySummariesDirectory = Path.Combine(appDirectory, "weekly_summaries");
        trackingDirectory = Path.Combine(appDirectory, "tracking", "llm-ranking");
        historyDirectory = Path.Combine(appDirectory, "history");
        historySessionsDirectory = Path.Combine(historyDirectory, "screen_sessions");
        historySummariesDirectory = Path.Combine(historyDirectory, "weekly_summaries");
        Directory.CreateDirectory(configDirectory);
        Settings = LoadSettings();
        ConfigureDataDirectory(ResolveDataDirectory(Settings.DataDirectory), migrateFrom: configDirectory);
        Settings.DataDirectory = appDirectory;
        SaveSettingsLocked();
        Sessions = LoadSessions();
        DeletedSessions = LoadDeletedSessions();
        if (RemoveDuplicateScreenTimeSessionsLocked() > 0)
        {
            SaveSessionsLocked();
        }
        RefreshHistoricalArchives();
    }

    public string AppDirectory => appDirectory;

    public string WeeklySummaryPath(string weekId) => Path.Combine(weeklySummariesDirectory, $"{weekId}.json");

    public string TrackingCachePath(string weekId) => Path.Combine(trackingDirectory, $"{weekId}.json");

    public AppSettings Settings { get; private set; }

    public List<ScreenSession> Sessions { get; private set; }

    public List<DeletedSession> DeletedSessions { get; private set; }

    public AppSettings GetSettingsSnapshot()
    {
        lock (gate)
        {
            return Settings.Clone();
        }
    }

    public void UpdateSettings(AppSettings settings)
    {
        settings.Normalize();
        lock (gate)
        {
            settings.DeviceId = EnsurePersistentDeviceId(settings.DeviceId);
            Settings = settings.Clone();
            ConfigureDataDirectory(ResolveDataDirectory(Settings.DataDirectory), migrateFrom: appDirectory);
            Settings.DataDirectory = appDirectory;
            SaveSettingsLocked();
            SaveIdentityLocked();
            SaveSessionsLocked();
            SaveDeletedSessionsLocked();
        }
    }

    public void UpdateDataDirectory(string path)
    {
        lock (gate)
        {
            Settings.DataDirectory = ResolveDataDirectory(path);
            ConfigureDataDirectory(Settings.DataDirectory, migrateFrom: appDirectory);
            Settings.DataDirectory = appDirectory;
            SaveSettingsLocked();
            SaveSessionsLocked();
            SaveDeletedSessionsLocked();
        }
    }

    public void TrustPeer(string deviceId)
    {
        lock (gate)
        {
            deviceId = deviceId.Trim();
            if (string.IsNullOrWhiteSpace(deviceId) || deviceId == Settings.DeviceId)
            {
                return;
            }

            Settings.RejectedPeerIds.RemoveAll(id => string.Equals(id, deviceId, StringComparison.OrdinalIgnoreCase));
            if (!Settings.TrustedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase))
            {
                Settings.TrustedPeerIds.Add(deviceId);
            }

            Settings.Normalize();
            SaveSettingsLocked();
        }
    }

    public void RejectPeer(string deviceId)
    {
        lock (gate)
        {
            deviceId = deviceId.Trim();
            if (string.IsNullOrWhiteSpace(deviceId) || deviceId == Settings.DeviceId)
            {
                return;
            }

            Settings.TrustedPeerIds.RemoveAll(id => string.Equals(id, deviceId, StringComparison.OrdinalIgnoreCase));
            if (!Settings.RejectedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase))
            {
                Settings.RejectedPeerIds.Add(deviceId);
            }

            Settings.Normalize();
            SaveSettingsLocked();
        }
    }

    public string TrustStatus(string deviceId)
    {
        lock (gate)
        {
            if (Settings.TrustedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase))
            {
                return "已同意";
            }

            if (Settings.RejectedPeerIds.Contains(deviceId, StringComparer.OrdinalIgnoreCase))
            {
                return "已拒绝";
            }

            return "待确认";
        }
    }

    public void Upsert(ScreenSession session)
    {
        lock (gate)
        {
            if (IsDeletedLocked(session))
            {
                return;
            }
            var index = Sessions.FindIndex(row => row.Id == session.Id);
            if (index >= 0)
            {
                Sessions[index] = session;
            }
            else
            {
                Sessions.Add(session);
            }

            Sessions = Sessions.OrderBy(row => row.StartAtUtc).ToList();
            SaveSessionsLocked();
        }
    }

    public void CloseOpenSessionsForCurrentDevice(string? exceptSessionId, string action, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (gate)
        {
            var changed = false;
            foreach (var session in Sessions.Where(row =>
                         row.EndAtUtc is null &&
                         string.Equals(row.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase) &&
                         !string.Equals(row.Id, exceptSessionId, StringComparison.OrdinalIgnoreCase)))
            {
                var end = EffectiveOpenSessionEnd(session, current);
                session.EndAtUtc = end;
                session.EndTimezone = TimeZoneInfo.Local.Id;
                session.DurationSeconds = Math.Max(0, (int)(end - session.StartAtUtc).TotalSeconds);
                session.StopAction = action;
                session.UpdatedAtUtc = current;
                session.Revision += 1;
                changed = true;
            }

            if (changed)
            {
                Sessions = Sessions.OrderBy(row => row.StartAtUtc).ToList();
                SaveSessionsLocked();
            }
        }
    }

    public ScreenSession? LatestOpenSessionForCurrentDevice()
    {
        lock (gate)
        {
            return Sessions
                .Where(row => row.EndAtUtc is null && string.Equals(row.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(row => row.StartAtUtc)
                .FirstOrDefault();
        }
    }

    public void RecoverOpenSessions(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (gate)
        {
            var changed = false;
            foreach (var session in Sessions.Where(row =>
                         row.EndAtUtc is null &&
                         string.Equals(row.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase)))
            {
                var end = EffectiveOpenSessionEnd(session, current);

                session.EndAtUtc = end;
                session.EndTimezone = TimeZoneInfo.Local.Id;
                session.DurationSeconds = Math.Max(0, (int)(end - session.StartAtUtc).TotalSeconds);
                session.StopAction = "crash_recovered";
                session.UpdatedAtUtc = current;
                session.Revision += 1;
                changed = true;
            }

            if (changed)
            {
                Sessions = Sessions.OrderBy(row => row.StartAtUtc).ToList();
                SaveSessionsLocked();
            }
        }
    }

    public SyncSnapshot MakeSyncSnapshot(DateTimeOffset? since = null)
    {
        lock (gate)
        {
            CloseExpiredOpenSessionsLocked(DateTimeOffset.UtcNow);
            if (RemoveDuplicateScreenTimeSessionsLocked() > 0)
            {
                SaveSessionsLocked();
            }

            return new SyncSnapshot
            {
                ProtocolVersion = 1,
                Device = new SyncDeviceInfo
                {
                    DeviceId = Settings.DeviceId,
                    DeviceName = Settings.DeviceName,
                    Platform = "windows",
                    AppVersion = "V1.0.9",
                    Capabilities = P2PTransport.SyncCapabilities.ToList(),
                    UpdatedAtUtc = DateTimeOffset.UtcNow
                },
                Capabilities = P2PTransport.SyncCapabilities.ToList(),
                Cursor = new SyncCursor { SinceUpdatedAtUtc = since },
                Sessions = Sessions
                    .Where(session => since is null || session.UpdatedAtUtc > since)
                    .Where(session => session.EndAtUtc is not null)
                    .ToList(),
                DeletedSessions = DeletedSessions
                    .Where(tombstone => since is null || tombstone.UpdatedAtUtc > since)
                    .ToList()
            };
        }
    }

    public int MergeSyncSnapshot(SyncSnapshot snapshot)
    {
        lock (gate)
        {
            var changed = MergeDeletedSessionsLocked(snapshot.DeletedSessions);
            foreach (var session in snapshot.Sessions)
            {
                if (IsDeletedLocked(session))
                {
                    continue;
                }
                var index = Sessions.FindIndex(row => row.Id == session.Id);
                if (index >= 0)
                {
                    if (!ShouldReplace(Sessions[index], session))
                    {
                        continue;
                    }

                    Sessions[index] = session;
                    changed++;
                }
                else
                {
                    Sessions.Add(session);
                    changed++;
                }
            }

            if (changed > 0)
            {
                changed = Math.Max(0, changed - RemoveDuplicateScreenTimeSessionsLocked());
                Sessions = Sessions.OrderBy(row => row.StartAtUtc).ToList();
                SaveSessionsLocked();
                RefreshHistoricalArchives();
            }

            return changed;
        }
    }

    public DateTimeOffset? SyncSince(string deviceId)
    {
        lock (gate)
        {
            var lastSync = Settings.PeerSyncStates
                .FirstOrDefault(state => string.Equals(state.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase))
                ?.LastSyncAtUtc;
            return lastSync?.AddSeconds(-SyncCursorOverlapSeconds);
        }
    }

    public void RecordPeerSync(string deviceId, IEnumerable<string> capabilities, DateTimeOffset? syncedAtUtc = null)
    {
        deviceId = deviceId.Trim();
        if (string.IsNullOrWhiteSpace(deviceId) || string.Equals(deviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        lock (gate)
        {
            var now = syncedAtUtc ?? DateTimeOffset.UtcNow;
            var normalizedCapabilities = AppSettings.NormalizeCapabilities(capabilities);
            var existing = Settings.PeerSyncStates
                .FirstOrDefault(state => string.Equals(state.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase));
            if (existing is null)
            {
                Settings.PeerSyncStates.Add(new PeerSyncState
                {
                    DeviceId = deviceId,
                    LastSyncAtUtc = now,
                    Capabilities = normalizedCapabilities
                });
            }
            else
            {
                existing.LastSyncAtUtc = now;
                if (normalizedCapabilities.Count > 0)
                {
                    existing.Capabilities = normalizedCapabilities;
                }
            }

            Settings.Normalize();
            SaveSettingsLocked();
        }
    }

    public int ClearSessionsForDate(DateTime date)
    {
        var now = DateTimeOffset.UtcNow;
        var localDay = date.Date;
        var dayStart = new DateTimeOffset(localDay, TimeZoneInfo.Local.GetUtcOffset(localDay)).ToUniversalTime();
        var nextLocalDay = localDay.AddDays(1);
        var dayEnd = new DateTimeOffset(nextLocalDay, TimeZoneInfo.Local.GetUtcOffset(nextLocalDay)).ToUniversalTime();
        var rangeEnd = localDay == DateTimeOffset.Now.Date && now < dayEnd ? now : dayEnd;
        if (rangeEnd <= dayStart)
        {
            return 0;
        }

        lock (gate)
        {
            CloseExpiredOpenSessionsLocked(now);
            DeletedSessions.Add(new DeletedSession
            {
                Id = $"range-{DateTools.DateString(localDay)}-{Settings.DeviceId}-{now.ToUnixTimeSeconds()}",
                StartAtUtc = dayStart,
                EndAtUtc = rangeEnd,
                DeletedByDeviceId = Settings.DeviceId,
                DeletedAtUtc = now,
                UpdatedAtUtc = now
            });
            DeletedSessions = DeletedSessions.OrderByDescending(row => row.UpdatedAtUtc).ToList();
            var removed = RemoveDeletedSessionsLocked();
            SaveDeletedSessionsLocked();
            SaveSessionsLocked();
            return removed;
        }
    }

    public (int totalSeconds, int averageDailySeconds, IReadOnlyList<PlatformUsageSummary> platforms) PreviousWeekSummary()
    {
        var today = DateTimeOffset.Now.Date;
        var daysSinceMonday = ((int)today.DayOfWeek + 6) % 7;
        var thisWeekStart = new DateTimeOffset(today.AddDays(-daysSinceMonday), TimeZoneInfo.Local.GetUtcOffset(today));
        var previousWeekStart = thisWeekStart.AddDays(-7);
        var startUtc = previousWeekStart.UtcDateTime;
        var endUtc = thisWeekStart.UtcDateTime;
        var platforms = PlatformUsage(startUtc, endUtc, 7);
        var total = TotalSeconds(startUtc, endUtc);
        return (total, total / 7, platforms);
    }

    public IReadOnlyList<ScreenSession> SessionsForDate(DateTime date)
    {
        CloseExpiredOpenSessions();
        var start = date.Date;
        var end = start.AddDays(1);
        return SessionsOverlapping(start.ToUniversalTime(), end.ToUniversalTime())
            .OrderBy(row => row.StartAtUtc)
            .ToList();
    }

    public int TotalSecondsForDayIncludingOpen(DateTime date, DateTimeOffset? now = null)
    {
        var start = date.Date;
        var end = start.AddDays(1);
        return TotalSeconds(start.ToUniversalTime(), end.ToUniversalTime(), now);
    }

    public int TotalSeconds(DateTime startUtc, DateTime endUtc, DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        CloseExpiredOpenSessions(current);
        return UnionSeconds(SessionsOverlapping(startUtc, endUtc), startUtc, endUtc, current);
    }

    public void SaveWeeklySummary(WeeklySummary summary)
    {
        Directory.CreateDirectory(weeklySummariesDirectory);
        File.WriteAllText(WeeklySummaryPath(summary.WeekId), JsonSerializer.Serialize(summary, jsonOptions));
    }

    public void RefreshHistoricalArchives(DateTimeOffset? now = null)
    {
        var current = now ?? DateTimeOffset.UtcNow;
        lock (gate)
        {
            var thisWeekStart = DateTools.CurrentWeekStart(current.LocalDateTime);
            var cutoffLocal = thisWeekStart.AddDays(-14);
            var cutoffUtc = new DateTimeOffset(cutoffLocal, TimeZoneInfo.Local.GetUtcOffset(cutoffLocal)).ToUniversalTime();
            var eligible = Sessions
                .Where(session => session.EndAtUtc is not null && session.EndAtUtc < cutoffUtc)
                .ToList();
            if (eligible.Count == 0)
            {
                return;
            }

            Directory.CreateDirectory(historySessionsDirectory);
            Directory.CreateDirectory(historySummariesDirectory);
            foreach (var group in eligible.GroupBy(session => DateTools.WeekId(session.StartAtUtc.LocalDateTime)))
            {
                var weekSessions = group
                    .OrderBy(session => session.StartAtUtc)
                    .ToList();
                var lines = string.Join('\n', weekSessions.Select(session => JsonSerializer.Serialize(session, jsonOptions))) + "\n";
                WriteGzipText(Path.Combine(historySessionsDirectory, $"screen_sessions_{group.Key}.jsonl.gz"), lines);

                var weekStartLocal = DateTools.CurrentWeekStart(weekSessions.Min(session => session.StartAtUtc.LocalDateTime));
                var weekEndLocal = weekStartLocal.AddDays(7);
                var weekStartUtc = new DateTimeOffset(weekStartLocal, TimeZoneInfo.Local.GetUtcOffset(weekStartLocal)).ToUniversalTime();
                var weekEndUtc = new DateTimeOffset(weekEndLocal, TimeZoneInfo.Local.GetUtcOffset(weekEndLocal)).ToUniversalTime();
                var summary = new HistoricalWeeklyUsageSummary(
                    group.Key,
                    DateTools.DateString(weekStartLocal),
                    DateTools.DateString(weekStartLocal.AddDays(6)),
                    TotalSeconds(weekStartUtc.UtcDateTime, weekEndUtc.UtcDateTime, current),
                    weekSessions.Count,
                    PlatformUsage(weekStartUtc.UtcDateTime, weekEndUtc.UtcDateTime, 7),
                    DeviceUsage(weekStartUtc.UtcDateTime, weekEndUtc.UtcDateTime, 7),
                    Settings.DeviceId,
                    current);
                File.WriteAllText(
                    Path.Combine(historySummariesDirectory, $"weekly_usage_{group.Key}.json"),
                    JsonSerializer.Serialize(summary, jsonOptions));
            }
        }
    }

    public LLMRankingCache? LoadCurrentLLMRanking()
    {
        var path = TrackingCachePath(DateTools.WeekId());
        if (!File.Exists(path))
        {
            return null;
        }

        return JsonSerializer.Deserialize<LLMRankingCache>(File.ReadAllText(path), jsonOptions);
    }

    public void SaveLLMRankingCache(LLMRankingCache cache)
    {
        Directory.CreateDirectory(trackingDirectory);
        File.WriteAllText(TrackingCachePath(cache.WeekId), JsonSerializer.Serialize(cache, jsonOptions));
    }

    public IReadOnlyList<PlatformUsageSummary> PlatformUsage(DateTime startUtc, DateTime endUtc, int dayCount)
    {
        var sessions = SessionsOverlapping(startUtc, endUtc);
        var current = DateTimeOffset.UtcNow;
        var divisor = Math.Max(1, dayCount);
        return sessions
            .GroupBy(session => string.IsNullOrWhiteSpace(session.Platform) ? "unknown" : session.Platform.ToLowerInvariant(), StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var seconds = UnionSeconds(group, startUtc, endUtc, current);
                return new PlatformUsageSummary(group.Key, seconds, seconds / divisor);
            })
            .OrderByDescending(row => row.TotalSeconds)
            .ThenBy(row => row.Platform)
            .ToList();
    }

    public IReadOnlyList<DeviceUsageSummary> DeviceUsage(DateTime startUtc, DateTime endUtc, int dayCount)
    {
        var sessions = SessionsOverlapping(startUtc, endUtc);
        var current = DateTimeOffset.UtcNow;
        var divisor = Math.Max(1, dayCount);
        return sessions
            .GroupBy(session => string.IsNullOrWhiteSpace(session.DeviceId) ? $"{session.Platform}:{session.DeviceName}" : session.DeviceId, StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var first = group.First();
                var seconds = UnionSeconds(group, startUtc, endUtc, current);
                return new DeviceUsageSummary(
                    first.DeviceId,
                    string.IsNullOrWhiteSpace(first.DeviceName) ? "Unknown device" : first.DeviceName,
                    string.IsNullOrWhiteSpace(first.Platform) ? "unknown" : first.Platform.ToLowerInvariant(),
                    seconds,
                    seconds / divisor);
            })
            .OrderByDescending(row => row.TotalSeconds)
            .ThenBy(row => row.DeviceName)
            .ToList();
    }

    private List<ScreenSession> SessionsOverlapping(DateTime startUtc, DateTime endUtc)
    {
        List<ScreenSession> sessions;
        lock (gate)
        {
            sessions = Sessions.ToList();
        }

        return sessions
            .Where(session =>
            {
                var sessionEnd = EffectiveEndUtc(session, DateTimeOffset.UtcNow).UtcDateTime;
                return sessionEnd > startUtc && session.StartAtUtc.UtcDateTime < endUtc;
            })
            .ToList();
    }

    public DateTimeOffset EffectiveEndUtc(ScreenSession session, DateTimeOffset now)
    {
        if (session.EndAtUtc is { } ended)
        {
            return ended;
        }

        if (string.Equals(session.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase) &&
            !OpenSessionIsExpired(session, now))
        {
            return now;
        }

        return EffectiveOpenSessionEnd(session, now);
    }

    public bool IsLocalOpenSession(ScreenSession session)
    {
        return session.EndAtUtc is null &&
            string.Equals(session.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase);
    }

    private DateTimeOffset EffectiveOpenSessionEnd(ScreenSession session, DateTimeOffset now)
    {
        var end = session.HeartbeatAtUtc ?? session.UpdatedAtUtc;
        if (end <= session.StartAtUtc || end > now)
        {
            end = now;
        }

        return end;
    }

    private static bool OpenSessionIsExpired(ScreenSession session, DateTimeOffset now)
    {
        var candidate = session.HeartbeatAtUtc ?? session.UpdatedAtUtc;
        if (candidate <= session.StartAtUtc || candidate > now)
        {
            return false;
        }

        return now - candidate > TimeSpan.FromSeconds(OpenSessionHeartbeatValiditySeconds);
    }

    private int UnionSeconds(IEnumerable<ScreenSession> sessions, DateTime startUtc, DateTime endUtc, DateTimeOffset now)
    {
        var intervals = sessions
            .Select(session =>
            {
                var sessionEnd = EffectiveEndUtc(session, now);
                var overlapStart = session.StartAtUtc.UtcDateTime > startUtc ? session.StartAtUtc.UtcDateTime : startUtc;
                var overlapEnd = sessionEnd.UtcDateTime < endUtc ? sessionEnd.UtcDateTime : endUtc;
                return (Start: overlapStart, End: overlapEnd);
            })
            .Where(interval => interval.End > interval.Start)
            .OrderBy(interval => interval.Start)
            .ToList();

        if (intervals.Count == 0)
        {
            return 0;
        }

        var total = 0;
        var currentStart = intervals[0].Start;
        var currentEnd = intervals[0].End;
        foreach (var interval in intervals.Skip(1))
        {
            if (interval.Start <= currentEnd)
            {
                if (interval.End > currentEnd)
                {
                    currentEnd = interval.End;
                }
                continue;
            }

            total += (int)(currentEnd - currentStart).TotalSeconds;
            currentStart = interval.Start;
            currentEnd = interval.End;
        }

        total += (int)(currentEnd - currentStart).TotalSeconds;
        return total;
    }

    private static string DefaultDataDirectory()
    {
        return Path.GetFullPath(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    }

    private string ResolveDataDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return DefaultDataDirectory();
        }

        var expanded = Environment.ExpandEnvironmentVariables(path.Trim());
        return Path.GetFullPath(expanded);
    }

    private void ConfigureDataDirectory(string directory, string? migrateFrom)
    {
        Directory.CreateDirectory(directory);
        if (!string.IsNullOrWhiteSpace(migrateFrom) &&
            !string.Equals(Path.GetFullPath(migrateFrom), directory, StringComparison.OrdinalIgnoreCase))
        {
            MigrateDataFiles(migrateFrom, directory);
        }

        appDirectory = directory;
        sessionsPath = Path.Combine(appDirectory, "sessions.json");
        deletedSessionsPath = Path.Combine(appDirectory, "deleted_sessions.json");
        weeklySummariesDirectory = Path.Combine(appDirectory, "weekly_summaries");
        trackingDirectory = Path.Combine(appDirectory, "tracking", "llm-ranking");
        historyDirectory = Path.Combine(appDirectory, "history");
        historySessionsDirectory = Path.Combine(historyDirectory, "screen_sessions");
        historySummariesDirectory = Path.Combine(historyDirectory, "weekly_summaries");
    }

    private static void MigrateDataFiles(string sourceDirectory, string destinationDirectory)
    {
        foreach (var name in new[] { "sessions.json", "deleted_sessions.json", "weekly_summaries", "tracking", "history" })
        {
            var source = Path.Combine(sourceDirectory, name);
            var destination = Path.Combine(destinationDirectory, name);
            if (!File.Exists(source) && !Directory.Exists(source))
            {
                continue;
            }

            if (File.Exists(destination) || Directory.Exists(destination))
            {
                continue;
            }

            try
            {
                if (File.Exists(source))
                {
                    File.Copy(source, destination);
                }
                else
                {
                    CopyDirectory(source, destination);
                }
            }
            catch
            {
                // Best-effort migration; current in-memory sessions are still saved after changing directory.
            }
        }
    }

    private static void WriteGzipText(string path, string text)
    {
        using var file = File.Create(path);
        using var gzip = new GZipStream(file, CompressionLevel.Fastest);
        var bytes = Encoding.UTF8.GetBytes(text);
        gzip.Write(bytes);
    }

    private static void CopyDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);
        foreach (var file in Directory.GetFiles(sourceDirectory))
        {
            File.Copy(file, Path.Combine(destinationDirectory, Path.GetFileName(file)));
        }

        foreach (var directory in Directory.GetDirectories(sourceDirectory))
        {
            CopyDirectory(directory, Path.Combine(destinationDirectory, Path.GetFileName(directory)));
        }
    }

    private AppSettings LoadSettings()
    {
        AppSettings settings;
        if (!File.Exists(settingsPath))
        {
            settings = new AppSettings();
        }
        else
        {
            settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(settingsPath), jsonOptions) ?? new AppSettings();
        }

        settings.Normalize();
        settings.DeviceId = EnsurePersistentDeviceId(settings.DeviceId);
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(settings, jsonOptions));
        File.WriteAllText(identityPath, settings.DeviceId);
        return settings;
    }

    private List<ScreenSession> LoadSessions()
    {
        if (!File.Exists(sessionsPath))
        {
            return [];
        }

        return JsonSerializer.Deserialize<List<ScreenSession>>(File.ReadAllText(sessionsPath), jsonOptions) ?? [];
    }

    private List<DeletedSession> LoadDeletedSessions()
    {
        if (!File.Exists(deletedSessionsPath))
        {
            return [];
        }

        return JsonSerializer.Deserialize<List<DeletedSession>>(File.ReadAllText(deletedSessionsPath), jsonOptions) ?? [];
    }

    private void SaveSettingsLocked()
    {
        File.WriteAllText(settingsPath, JsonSerializer.Serialize(Settings, jsonOptions));
    }

    private void SaveIdentityLocked()
    {
        File.WriteAllText(identityPath, Settings.DeviceId);
    }

    private void SaveSessionsLocked()
    {
        File.WriteAllText(sessionsPath, JsonSerializer.Serialize(Sessions, jsonOptions));
    }

    private void SaveDeletedSessionsLocked()
    {
        File.WriteAllText(deletedSessionsPath, JsonSerializer.Serialize(DeletedSessions, jsonOptions));
    }

    public int CloseExpiredOpenSessions(DateTimeOffset? now = null)
    {
        lock (gate)
        {
            return CloseExpiredOpenSessionsLocked(now ?? DateTimeOffset.UtcNow);
        }
    }

    private int CloseExpiredOpenSessionsLocked(DateTimeOffset now)
    {
        var changed = 0;
        foreach (var session in Sessions.Where(row =>
                     row.EndAtUtc is null &&
                     string.Equals(row.DeviceId, Settings.DeviceId, StringComparison.OrdinalIgnoreCase) &&
                     OpenSessionIsExpired(row, now)))
        {
            var end = EffectiveOpenSessionEnd(session, now);
            session.EndAtUtc = end;
            session.EndTimezone = TimeZoneInfo.Local.Id;
            session.DurationSeconds = Math.Max(0, (int)(end - session.StartAtUtc).TotalSeconds);
            session.StopAction = "standby_started";
            session.HeartbeatAtUtc = end;
            session.UpdatedAtUtc = now;
            session.Revision += 1;
            changed++;
        }

        if (changed > 0)
        {
            Sessions = Sessions.OrderBy(row => row.StartAtUtc).ToList();
            SaveSessionsLocked();
        }

        return changed;
    }

    private int MergeDeletedSessionsLocked(IEnumerable<DeletedSession> incoming)
    {
        var changed = 0;
        foreach (var tombstone in incoming)
        {
            if (string.IsNullOrWhiteSpace(tombstone.Id))
            {
                continue;
            }

            var index = DeletedSessions.FindIndex(row => string.Equals(row.Id, tombstone.Id, StringComparison.OrdinalIgnoreCase));
            if (index >= 0)
            {
                if (tombstone.UpdatedAtUtc > DeletedSessions[index].UpdatedAtUtc)
                {
                    DeletedSessions[index] = tombstone;
                    changed++;
                }
            }
            else
            {
                DeletedSessions.Add(tombstone);
                changed++;
            }
        }

        var removed = RemoveDeletedSessionsLocked();
        if (changed > 0 || removed > 0)
        {
            DeletedSessions = DeletedSessions.OrderByDescending(row => row.UpdatedAtUtc).ToList();
            SaveDeletedSessionsLocked();
            if (removed > 0)
            {
                SaveSessionsLocked();
            }
        }

        return changed + removed;
    }

    private int RemoveDeletedSessionsLocked()
    {
        var original = Sessions.Count;
        Sessions = Sessions.Where(session => !IsDeletedLocked(session)).ToList();
        return Math.Max(0, original - Sessions.Count);
    }

    private bool IsDeletedLocked(ScreenSession session)
    {
        return DeletedSessions.Any(tombstone => TombstoneMatches(tombstone, session));
    }

    private bool TombstoneMatches(DeletedSession tombstone, ScreenSession session)
    {
        if (!string.IsNullOrWhiteSpace(tombstone.SessionId) &&
            string.Equals(session.Id, tombstone.SessionId, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (tombstone.StartAtUtc is not { } start || tombstone.EndAtUtc is not { } end || end <= start)
        {
            return false;
        }

        var sessionEnd = session.EndAtUtc ?? EffectiveOpenSessionEnd(session, DateTimeOffset.UtcNow);
        if (!(sessionEnd > start && session.StartAtUtc < end))
        {
            return false;
        }

        return SessionExistedBeforeDeletion(session, tombstone.DeletedAtUtc);
    }

    private static bool SessionExistedBeforeDeletion(ScreenSession session, DateTimeOffset deletedAt)
    {
        if (session.CreatedAtUtc <= deletedAt)
        {
            return true;
        }

        return session.EndAtUtc is { } end && end <= deletedAt;
    }

    private bool ShouldReplace(ScreenSession existing, ScreenSession incoming)
    {
        if (incoming.Revision != existing.Revision)
        {
            return incoming.Revision > existing.Revision;
        }

        if (incoming.UpdatedAtUtc != existing.UpdatedAtUtc)
        {
            return incoming.UpdatedAtUtc > existing.UpdatedAtUtc;
        }

        return CanonicalJson(incoming).CompareTo(CanonicalJson(existing)) > 0;
    }

    private int RemoveDuplicateScreenTimeSessionsLocked()
    {
        var originalCount = Sessions.Count;
        var cleaned = new List<ScreenSession>();
        var indexByKey = new Dictionary<(string DeviceId, string Scope, DateTimeOffset Start, DateTimeOffset End, int Duration), int>();

        foreach (var session in Sessions)
        {
            if (!IsIOSScreenTimeSession(session) || session.EndAtUtc is not { } end)
            {
                cleaned.Add(session);
                continue;
            }

            var key = (
                session.DeviceId.ToLowerInvariant(),
                session.MeasurementScope,
                session.StartAtUtc,
                end,
                session.DurationSeconds);

            if (indexByKey.TryGetValue(key, out var existingIndex))
            {
                cleaned[existingIndex] = PreferredScreenTimeSession(cleaned[existingIndex], session);
            }
            else
            {
                indexByKey[key] = cleaned.Count;
                cleaned.Add(session);
            }
        }

        Sessions = cleaned;
        return Math.Max(0, originalCount - cleaned.Count);
    }

    private static bool IsIOSScreenTimeSession(ScreenSession session)
    {
        return string.Equals(session.MeasurementScope, "ios_screen_time_selected", StringComparison.OrdinalIgnoreCase) ||
            session.Id.StartsWith("ios-screen-time-", StringComparison.OrdinalIgnoreCase);
    }

    private static ScreenSession PreferredScreenTimeSession(ScreenSession left, ScreenSession right)
    {
        var leftPriority = ScreenTimeActionPriority(left.StopAction);
        var rightPriority = ScreenTimeActionPriority(right.StopAction);
        if (leftPriority != rightPriority)
        {
            return rightPriority > leftPriority ? right : left;
        }

        if (left.UpdatedAtUtc != right.UpdatedAtUtc)
        {
            return right.UpdatedAtUtc > left.UpdatedAtUtc ? right : left;
        }

        if (left.CreatedAtUtc != right.CreatedAtUtc)
        {
            return right.CreatedAtUtc > left.CreatedAtUtc ? right : left;
        }

        return string.CompareOrdinal(right.Id, left.Id) < 0 ? right : left;
    }

    private static int ScreenTimeActionPriority(string? action)
    {
        return action switch
        {
            "posture_rest_prompt" => 4,
            "eye_rest_prompt" => 3,
            "screen_time_checkpoint" => 2,
            _ => 1
        };
    }

    private string CanonicalJson(ScreenSession session)
    {
        return JsonSerializer.Serialize(session, new JsonSerializerOptions(JsonSerializerDefaults.Web));
    }

    private string EnsurePersistentDeviceId(string candidate)
    {
        if (File.Exists(identityPath))
        {
            var persisted = File.ReadAllText(identityPath).Trim();
            if (!string.IsNullOrWhiteSpace(persisted))
            {
                return persisted;
            }
        }

        var machineId = StableMachineDeviceId();
        if (!string.IsNullOrWhiteSpace(machineId))
        {
            return machineId;
        }

        return string.IsNullOrWhiteSpace(candidate) ? Guid.NewGuid().ToString() : candidate;
    }

    private static string? StableMachineDeviceId()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            var machineGuid = key?.GetValue("MachineGuid")?.ToString();
            if (string.IsNullOrWhiteSpace(machineGuid))
            {
                return null;
            }

            using var sha256 = SHA256.Create();
            var bytes = sha256.ComputeHash(Encoding.UTF8.GetBytes($"STG-WINDOWS:{machineGuid}"));
            return new Guid(bytes.Take(16).ToArray()).ToString();
        }
        catch
        {
            return null;
        }
    }
}

internal sealed record PlatformUsageSummary(string Platform, int TotalSeconds, int AverageDailySeconds);

internal sealed record DeviceUsageSummary(string DeviceId, string DeviceName, string Platform, int TotalSeconds, int AverageDailySeconds);
