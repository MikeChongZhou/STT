using Microsoft.Win32;
using System.Drawing;
using System.Windows.Forms;

namespace ScreenTimeGuardian;

internal sealed class TrayAppContext : ApplicationContext
{
    private readonly SessionStore store = new();
    private readonly NotifyIcon notifyIcon;
    private readonly P2PTransport p2pTransport;
    private readonly System.Windows.Forms.Timer heartbeatTimer = new();
    private readonly System.Windows.Forms.Timer reminderTimer = new();
    private ScreenSession? currentSession;
    private bool promptActive;
    private DateTimeOffset? lastReminderSampleAtUtc;
    private DateTimeOffset? lastActivityTimerTickAtUtc;
    private int eyeActiveSeconds;
    private int postureActiveSeconds;

    public TrayAppContext()
    {
        p2pTransport = new P2PTransport(store);
        notifyIcon = new NotifyIcon
        {
            Text = "STG",
            Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            Visible = true,
            ContextMenuStrip = BuildMenu()
        };

        SystemEvents.SessionSwitch += OnSessionSwitch;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionEnding += OnSessionEnding;
        ConfigureTimers();
        store.RecoverOpenSessions();
        StartSession();
        ResetReminderCounters(DateTimeOffset.UtcNow);
        StartActivityTimers();
        p2pTransport.Start();
        ConfigureAutoStart();
        CheckWeeklySummaryIfNeeded();
    }

    private ContextMenuStrip BuildMenu()
    {
        var language = store.Settings.Language;
        var menu = new ContextMenuStrip();
        menu.Items.Add(L10n.Text("报告", "Report", language), null, (_, _) => ShowReport());
        menu.Items.Add(L10n.Text("设置", "Settings", language), null, (_, _) => ShowSettings());
        menu.Items.Add(L10n.Text("跟踪", "Tracking", language), null, (_, _) => ShowTracking());
        menu.Items.Add(L10n.Text("关于", "About", language), null, (_, _) => ShowAbout());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L10n.Text("退出", "Exit", language), null, (_, _) => Exit());
        return menu;
    }

    private void ConfigureTimers()
    {
        heartbeatTimer.Interval = 60 * 1000;
        heartbeatTimer.Tick += (_, _) =>
        {
            var now = DateTimeOffset.UtcNow;
            if (!HandleActivityTimerTick(now))
            {
                UpdateCurrentSession();
            }
        };
        reminderTimer.Interval = 10 * 1000;
        reminderTimer.Tick += (_, _) =>
        {
            var now = DateTimeOffset.UtcNow;
            if (!HandleActivityTimerTick(now))
            {
                CheckReminders();
            }
        };
    }

    private void StartActivityTimers()
    {
        lastActivityTimerTickAtUtc = DateTimeOffset.UtcNow;
        if (!heartbeatTimer.Enabled)
        {
            heartbeatTimer.Start();
        }

        if (!reminderTimer.Enabled)
        {
            reminderTimer.Start();
        }
    }

    private void StopActivityTimers()
    {
        heartbeatTimer.Stop();
        reminderTimer.Stop();
        lastActivityTimerTickAtUtc = null;
    }

    private bool HandleActivityTimerTick(DateTimeOffset now)
    {
        if (lastActivityTimerTickAtUtc is { } last &&
            now - last > TimeSpan.FromSeconds(90))
        {
            EndSessionAt("standby_started", last);
            ResetReminderCounters(now);
            if (currentSession is null)
            {
                StartSession(now);
            }

            lastActivityTimerTickAtUtc = now;
            p2pTransport.Restart();
            return true;
        }

        lastActivityTimerTickAtUtc = now;
        return false;
    }

    private void StartSession(DateTimeOffset? startAtUtc = null)
    {
        var now = DateTimeOffset.UtcNow;
        var start = startAtUtc ?? now;
        store.CloseOpenSessionsForCurrentDevice(null, "crash_recovered", start);
        var durationSeconds = Math.Max(0, (int)(now - start).TotalSeconds);
        currentSession = new ScreenSession
        {
            DeviceId = store.Settings.DeviceId,
            DeviceName = store.Settings.DeviceName,
            Platform = "windows",
            MeasurementScope = "global_exact",
            StartAtUtc = start,
            StartTimezone = TimeZoneInfo.Local.Id,
            DurationSeconds = durationSeconds,
            CreatedAtUtc = now,
            UpdatedAtUtc = now,
            HeartbeatAtUtc = now
        };
        store.Upsert(currentSession);
    }

    private void UpdateCurrentSession()
    {
        if (currentSession is null)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        RollOverCurrentSessionIfNeeded(now);
        if (currentSession is null)
        {
            return;
        }

        currentSession.HeartbeatAtUtc = now;
        currentSession.DurationSeconds = Math.Max(0, (int)(now - currentSession.StartAtUtc).TotalSeconds);
        currentSession.UpdatedAtUtc = now;
        currentSession.Revision += 1;
        store.Upsert(currentSession);
    }

    private void EndSession(string action)
    {
        EndSessionAt(action, DateTimeOffset.UtcNow);
    }

    private void EndSessionAt(string action, DateTimeOffset endAtUtc)
    {
        if (currentSession is null)
        {
            if (store.LatestOpenSessionForCurrentDevice() is { } open)
            {
                currentSession = open;
            }
            else
            {
                return;
            }
        }

        if (currentSession.EndAtUtc is not null)
        {
            currentSession = null;
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var effectiveEnd = store.EffectiveEndUtc(currentSession, endAtUtc);
        currentSession.EndAtUtc = effectiveEnd;
        currentSession.EndTimezone = TimeZoneInfo.Local.Id;
        currentSession.DurationSeconds = Math.Max(0, (int)(effectiveEnd - currentSession.StartAtUtc).TotalSeconds);
        currentSession.StopAction = action;
        currentSession.HeartbeatAtUtc = effectiveEnd;
        currentSession.UpdatedAtUtc = now;
        currentSession.Revision += 1;
        store.Upsert(currentSession);
        currentSession = null;
    }

    private void RollOverCurrentSessionIfNeeded(DateTimeOffset now)
    {
        if (currentSession is null)
        {
            return;
        }

        var sessionLocalDate = currentSession.StartAtUtc.ToLocalTime().Date;
        var currentLocalDate = now.ToLocalTime().Date;
        if (sessionLocalDate == currentLocalDate)
        {
            return;
        }

        var localMidnight = DateTime.SpecifyKind(currentLocalDate, DateTimeKind.Unspecified);
        var rolloverAtUtc = new DateTimeOffset(localMidnight, TimeZoneInfo.Local.GetUtcOffset(localMidnight)).ToUniversalTime();
        if (rolloverAtUtc <= currentSession.StartAtUtc || rolloverAtUtc > now)
        {
            rolloverAtUtc = now;
        }

        EndSessionAt("date_rollover", rolloverAtUtc);
        StartSession(rolloverAtUtc);
        CheckWeeklySummaryIfNeeded();
    }

    private void ResetReminderCounters(DateTimeOffset now)
    {
        eyeActiveSeconds = 0;
        postureActiveSeconds = 0;
        lastReminderSampleAtUtc = now;
    }

    private void ResetReminderSampling(DateTimeOffset now)
    {
        lastReminderSampleAtUtc = now;
    }

    private void AccumulateReminderSeconds(DateTimeOffset now)
    {
        if (lastReminderSampleAtUtc is not { } last || now < last)
        {
            lastReminderSampleAtUtc = now;
            return;
        }

        var deltaSeconds = (int)(now - last).TotalSeconds;
        if (deltaSeconds <= 0)
        {
            return;
        }

        eyeActiveSeconds += deltaSeconds;
        postureActiveSeconds += deltaSeconds;
        lastReminderSampleAtUtc = now;
    }

    private void ShowReport()
    {
        EndSession("report_opened");
        using var report = new ReportForm(store, p2pTransport);
        report.ShowDialog();
        StartSession();
    }

    private void ShowSettings()
    {
        using var settings = new SettingsForm(store, p2pTransport);
        if (settings.ShowDialog() == DialogResult.OK)
        {
            UpdateCurrentDeviceInfo();
            ConfigureAutoStart();
            notifyIcon.ContextMenuStrip = BuildMenu();
        }
    }

    private void ShowTracking()
    {
        using var tracking = new TrackingForm(store);
        tracking.ShowDialog();
    }

    private void ShowAbout()
    {
        var language = store.Settings.Language;
        var usageGuide = L10n.Text(
            "使用说明：\n1. 本 App 利用 P2P 同步你的不同设备，以统计你总的屏幕使用时间。请在各平台 App 中设置统一的同步码，建议不要使用本 App 默认的同步码。\n2. 本 App 不使用云端数据，所有数据都保存在你的本地设备，请放心使用。\n3. 只有你同意的设备才会同步。",
            "Usage:\n1. This app uses P2P to sync your devices and calculate your total screen time. Set the same sync code in every app, and avoid using the default code.\n2. This app does not use cloud data. All data stays on your local devices.\n3. Only devices you approve can sync.",
            language);
        MessageBox.Show(
            $"Screen Time Guardian\n{L10n.Text("版本", "Version", language)}：1.0.9\n{L10n.Text("开发者", "Developer", language)}：TimberTrail\n{L10n.Text("免费使用", "Free to use", language)}\n\n{usageGuide}",
            L10n.Text("关于", "About", language),
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void UpdateCurrentDeviceInfo()
    {
        if (currentSession is null)
        {
            return;
        }

        currentSession.DeviceId = store.Settings.DeviceId;
        currentSession.DeviceName = store.Settings.DeviceName;
        currentSession.UpdatedAtUtc = DateTimeOffset.UtcNow;
        currentSession.Revision += 1;
        store.Upsert(currentSession);
    }

    private void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
    {
        if (e.Reason == SessionSwitchReason.SessionLock)
        {
            EndSession("screen_locked");
            StopActivityTimers();
        }
        else if (e.Reason == SessionSwitchReason.SessionUnlock && currentSession is null)
        {
            StartSession();
            ResetReminderCounters(DateTimeOffset.UtcNow);
            StartActivityTimers();
        }
    }

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
        {
            EndSession("standby_started");
            StopActivityTimers();
        }
        else if (e.Mode == PowerModes.Resume && currentSession is null)
        {
            StartSession();
            ResetReminderCounters(DateTimeOffset.UtcNow);
            StartActivityTimers();
        }
    }

    private void OnSessionEnding(object sender, SessionEndingEventArgs e)
    {
        EndSession("shutdown_started");
    }

    private void Exit()
    {
        EndSession("app_exit");
        StopActivityTimers();
        heartbeatTimer.Dispose();
        reminderTimer.Dispose();
        notifyIcon.Visible = false;
        notifyIcon.Dispose();
        p2pTransport.Dispose();
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionEnding -= OnSessionEnding;
        Application.Exit();
    }

    private void CheckReminders()
    {
        if (promptActive)
        {
            return;
        }

        if (currentSession is null)
        {
            StartSession();
            ResetReminderSampling(DateTimeOffset.UtcNow);
            return;
        }

        var now = DateTimeOffset.UtcNow;
        RollOverCurrentSessionIfNeeded(now);
        if (currentSession is null)
        {
            return;
        }

        AccumulateReminderSeconds(now);

        var eyeRestMinutes = Math.Max(1, store.Settings.EyeRestIntervalMinutes);
        var eyeRestSeconds = eyeRestMinutes * 60;
        var postureRestSeconds = AppSettings.DerivedPostureRestIntervalMinutes(eyeRestMinutes) * 60;
        var postureDue = store.Settings.PostureSwitchEnabled && postureActiveSeconds >= postureRestSeconds;
        if (eyeActiveSeconds >= eyeRestSeconds || postureDue)
        {
            eyeActiveSeconds = 0;
            if (postureDue)
            {
                postureActiveSeconds = 0;
            }
            var language = store.Settings.Language;
            var includePosture = postureDue;
            ShowRestPrompt(
                includePosture
                    ? L10n.Text("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder", language)
                    : L10n.Text("用眼休息提醒", "Eye Rest Reminder", language),
                includePosture
                    ? L10n.Text("请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。", "Switch between sitting and standing, then look 20 feet away to rest your eyes.", language)
                    : L10n.Text("请看 20 英尺外 20 秒。", "Look at something 20 feet away for 20 seconds.", language),
                includePosture ? "posture_rest_prompt" : "eye_rest_prompt",
                includePosture ? 60 : 20);
            return;
        }

        CheckTimeoutPlan();
    }

    private void ShowRestPrompt(string title, string message, string action, int countdownSeconds)
    {
        promptActive = true;
        StopActivityTimers();
        EndSession(action);
        using (var prompt = new RestPromptForm(title, message, countdownSeconds, store.Settings.MeetingMode, store.Settings.Language))
        {
            prompt.ShowDialog();
        }
        StartSession();
        ResetReminderSampling(DateTimeOffset.UtcNow);
        StartActivityTimers();
        promptActive = false;
    }

    private void CheckTimeoutPlan()
    {
        var plannedMinutes = store.Settings.PlannedDailyMinutes;
        if (plannedMinutes <= 0)
        {
            return;
        }

        var today = DateTools.DateString(DateTime.Now);
        var total = store.TotalSecondsForDayIncludingOpen(DateTime.Now);

        if (total <= plannedMinutes * 60)
        {
            return;
        }

        if (store.Settings.LastTimeoutPromptDate == today &&
            store.Settings.LastTimeoutPromptAtUtc is { } last &&
            DateTimeOffset.UtcNow - last < TimeSpan.FromMinutes(25))
        {
            return;
        }

        promptActive = true;
        StopActivityTimers();
        EndSession("timeout_prompt");
        var language = store.Settings.Language;
        var planText = DateTools.FormatDuration(plannedMinutes * 60, language);
        using (var prompt = new RestPromptForm(
            L10n.Text("超过计划提醒", "Daily Plan Reached", language),
            $"{L10n.Text("今日累计用时", "Today's total screen time", language)}：{DateTools.FormatDuration(total, language)}\n{L10n.Text("本周每天计划", "Daily plan this week", language)}：{planText}\n{L10n.Text("如果继续用屏，25 分钟后会再次提醒。", "If you keep using the screen, this reminder will appear again in 25 minutes.", language)}",
            120,
            store.Settings.MeetingMode,
            language))
        {
            prompt.ShowDialog();
        }

        var settings = store.GetSettingsSnapshot();
        settings.LastTimeoutPromptAtUtc = DateTimeOffset.UtcNow;
        settings.LastTimeoutPromptDate = today;
        store.UpdateSettings(settings);
        StartSession();
        StartActivityTimers();
        promptActive = false;
    }

    private void CheckWeeklySummaryIfNeeded()
    {
        if (DateTime.Now.DayOfWeek != DayOfWeek.Monday)
        {
            return;
        }

        var weekId = DateTools.WeekId();
        if (File.Exists(store.WeeklySummaryPath(weekId)))
        {
            return;
        }

        var thisWeekStart = DateTools.CurrentWeekStart();
        var previousWeekStart = thisWeekStart.AddDays(-7);
        var previousWeekTotal = store.TotalSeconds(previousWeekStart.ToUniversalTime(), thisWeekStart.ToUniversalTime());
        var previousWeekAverage = previousWeekTotal / 7;
        var defaultMinutes = store.Settings.LastWeeklyPlanMinutes ?? Math.Max(1, previousWeekAverage / 60);

        using var form = new WeeklyPlanForm(previousWeekTotal, previousWeekAverage, defaultMinutes, store.Settings.Language);
        if (form.ShowDialog() != DialogResult.OK)
        {
            return;
        }

        var settings = store.GetSettingsSnapshot();
        settings.PlannedDailyMinutes = form.PlannedMinutes;
        settings.LastWeeklyPlanMinutes = form.PlannedMinutes;
        store.UpdateSettings(settings);
        store.SaveWeeklySummary(new WeeklySummary(
            weekId,
            form.PlannedMinutes,
            previousWeekTotal,
            previousWeekAverage,
            store.Settings.DeviceId,
            DateTimeOffset.UtcNow));
    }

    private void ConfigureAutoStart()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run", writable: true);
            if (key is null)
            {
                return;
            }

            if (store.Settings.AutoStartEnabled)
            {
                key.SetValue("ScreenTimeGuardian", $"\"{Application.ExecutablePath}\"");
            }
            else
            {
                key.DeleteValue("ScreenTimeGuardian", throwOnMissingValue: false);
            }
        }
        catch
        {
            // Autostart is helpful but non-critical; settings should still save normally.
        }
    }
}
