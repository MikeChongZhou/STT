package com.timbertrail.screentimeguardian

import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.temporal.TemporalAdjusters

object DateTools {
    private val dateFormatter = DateTimeFormatter.ISO_LOCAL_DATE
    private val dateTimeFormatter = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")

    fun currentWeekStartDate(): LocalDate =
        LocalDate.now(ZoneId.systemDefault()).with(TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))

    fun weekId(date: LocalDate = currentWeekStartDate()): String =
        date.format(DateTimeFormatter.ISO_LOCAL_DATE)

    fun dateString(date: LocalDate): String = date.format(dateFormatter)

    fun dateTimeString(instant: Instant): String =
        dateTimeFormatter.format(instant.atZone(ZoneId.systemDefault()))

    fun parseDateOrToday(value: String): LocalDate =
        runCatching { LocalDate.parse(value.trim(), dateFormatter) }.getOrDefault(LocalDate.now(ZoneId.systemDefault()))

    fun parseInstant(value: String): Instant {
        val trimmed = value.trim()
        return runCatching { Instant.parse(trimmed) }
            .getOrElse { OffsetDateTime.parse(trimmed, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant() }
    }

    fun formatDuration(seconds: Int, language: String = "zh"): String {
        val safe = maxOf(0, seconds)
        val hours = safe / 3600
        val minutes = safe % 3600 / 60
        val secs = safe % 60
        if (language == "en") {
            return when {
                hours > 0 -> "${hours}h ${minutes}m"
                minutes > 0 -> "${minutes}m ${secs}s"
                else -> "${secs}s"
            }
        }
        return when {
            hours > 0 -> "${hours}小时${minutes}分钟"
            minutes > 0 -> "${minutes}分钟${secs}秒"
            else -> "${secs}秒"
        }
    }

    fun stopActionTitle(action: String?, language: String = "zh"): String {
        if (language == "en") {
            return when (action) {
                "report_opened" -> "Report opened"
                "eye_rest_prompt" -> "Eye rest prompt"
                "posture_rest_prompt" -> "Posture switch prompt"
                "screen_locked" -> "Screen locked"
                "screensaver_started" -> "Screen saver"
                "standby_started" -> "Sleep or standby"
                "shutdown_started" -> "Shutdown"
                "app_exit" -> "App exit"
                "app_backgrounded" -> "App backgrounded"
                "date_rollover" -> "Date rollover"
                "timeout_prompt" -> "Plan timeout prompt"
                "crash_recovered" -> "Crash recovered"
                else -> "In progress"
            }
        }
        return when (action) {
            "report_opened" -> "打开报告"
            "eye_rest_prompt" -> "护眼提醒"
            "posture_rest_prompt" -> "姿势提醒"
            "screen_locked" -> "锁屏"
            "screensaver_started" -> "屏保/屏幕关闭"
            "standby_started" -> "待机/屏幕关闭"
            "shutdown_started" -> "关机"
            "app_exit" -> "退出"
            "app_backgrounded" -> "应用后台/跨日"
            "timeout_prompt" -> "计划超时"
            "crash_recovered" -> "异常恢复"
            else -> "进行中"
        }
    }

    fun platformTitle(platform: String): String = when (normalizedPlatform(platform)) {
        "macos" -> "macOS"
        "ios" -> "iOS"
        "ipados" -> "iPadOS"
        "windows" -> "Windows"
        "android" -> "Android"
        else -> "Unknown"
    }
}
