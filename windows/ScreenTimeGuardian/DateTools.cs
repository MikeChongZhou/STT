using System.Globalization;

namespace ScreenTimeGuardian;

internal static class DateTools
{
    public static string DateString(DateTime value) => value.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static string DateTimeString(DateTimeOffset value) => value.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    public static DateTime CurrentWeekStart(DateTime? now = null)
    {
        var today = (now ?? DateTime.Now).Date;
        var daysSinceMonday = ((int)today.DayOfWeek + 6) % 7;
        return today.AddDays(-daysSinceMonday);
    }

    public static string WeekId(DateTime? now = null)
    {
        var date = now ?? DateTime.Now;
        var calendar = CultureInfo.InvariantCulture.Calendar;
        var week = calendar.GetWeekOfYear(date, CalendarWeekRule.FirstFourDayWeek, DayOfWeek.Monday);
        return $"{date.Year}-W{week:00}";
    }

    public static string FormatDuration(int seconds, string language = "zh")
    {
        seconds = Math.Max(0, seconds);
        var hours = seconds / 3600;
        var minutes = seconds % 3600 / 60;
        var secs = seconds % 60;
        if (language == "en")
        {
            if (hours > 0)
            {
                return $"{hours}h {minutes}m";
            }

            if (minutes > 0)
            {
                return $"{minutes}m {secs}s";
            }

            return $"{secs}s";
        }

        if (hours > 0)
        {
            return $"{hours}小时{minutes}分钟";
        }

        if (minutes > 0)
        {
            return $"{minutes}分钟{secs}秒";
        }

        return $"{secs}秒";
    }

    public static string PlatformTitle(string platform) => platform.ToLowerInvariant() switch
    {
        "macos" => "macOS",
        "ios" => "iOS",
        "ipados" => "iPadOS",
        "windows" => "Windows",
        "android" => "Android",
        _ => string.IsNullOrWhiteSpace(platform) ? "Unknown" : platform
    };

    public static string StopActionTitle(string? action, string language = "zh") => language == "en"
        ? action switch
        {
            "report_opened" => "Report opened",
            "eye_rest_prompt" => "Eye rest prompt",
            "posture_rest_prompt" => "Posture switch prompt",
            "screen_locked" => "Screen locked",
            "screensaver_started" => "Screen saver",
            "standby_started" => "Sleep or standby",
            "shutdown_started" => "Shutdown",
            "app_exit" => "App exit",
            "app_backgrounded" => "App backgrounded",
            "date_rollover" => "Date rollover",
            "timeout_prompt" => "Plan timeout prompt",
            "crash_recovered" => "Crash recovered",
            null or "" => "In progress",
            _ => action
        }
        : action switch
    {
        "report_opened" => "打开报告",
        "eye_rest_prompt" => "用眼休息提示",
        "posture_rest_prompt" => "姿势切换提示",
        "screen_locked" => "锁屏",
        "screensaver_started" => "屏保/屏幕关闭",
        "standby_started" => "待机/休眠",
        "shutdown_started" => "关机",
        "app_exit" => "退出 App",
        "app_backgrounded" => "App 后台",
        "date_rollover" => "跨日切分",
        "timeout_prompt" => "超过计划提醒",
        "crash_recovered" => "异常恢复",
        null or "" => "进行中",
        _ => action
    };
}
