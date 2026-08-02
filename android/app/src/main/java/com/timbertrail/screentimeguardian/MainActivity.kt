package com.timbertrail.screentimeguardian

import android.Manifest
import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class MainActivity : Activity() {
    private lateinit var store: SessionStore
    private val handler = Handler(Looper.getMainLooper())
    private val refreshRunnable = object : Runnable {
        override fun run() {
            render()
            handler.postDelayed(this, 5000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SessionStore(this)
        GuardianService.start(this)
        requestRuntimePermissionsIfNeeded()
        render()
        handler.postDelayed(refreshRunnable, 5000L)
    }

    override fun onResume() {
        super.onResume()
        render()
    }

    override fun onDestroy() {
        handler.removeCallbacks(refreshRunnable)
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        GuardianRuntime.p2pTransport?.refresh()
        render()
    }

    private fun render() {
        val language = store.language
        val today = LocalDate.now(ZoneId.systemDefault())
        val summary = store.previousWeekSummary()
        val p2p = GuardianRuntime.p2pTransport
        val todaySeconds = store.currentDayTotalSeconds(Instant.now())
        val plannedSeconds = store.plannedDailyMinutes * 60
        val syncDeviceCount = store.syncDeviceLedger(p2p?.peersSnapshot().orEmpty()).size
        val syncState = L10n.syncStatus(
            p2p?.status ?: L10n.text("后台服务初始化中", "background service is starting", language),
            language
        )
        val topPlatform = summary.platforms.maxByOrNull { it.totalSeconds }
        val weekAverage = DateTools.formatDuration(summary.averageDailySeconds, language)
        val topPlatformText = topPlatform?.let { DateTools.platformTitle(it.platform) } ?: L10n.text("暂无", "None", language)
        val root = AppUi.pageStack(this).apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                window.statusBarColor = AppUi.BACKGROUND_COLOR
                window.navigationBarColor = AppUi.BACKGROUND_COLOR
            }
            addView(AppUi.title(this@MainActivity, "Screen Time Guardian"))
            addView(AppUi.subtitle(this@MainActivity, "${L10n.text("版本", "Version", language)}：${SessionStore.APP_VERSION}    ${L10n.text("免费使用", "Free to use", language)}"))
            addView(AppUi.heroCard(
                context = this@MainActivity,
                label = L10n.text("今日屏幕用时", "Today", language),
                value = DateTools.formatDuration(todaySeconds, language),
                plan = "${L10n.text("计划", "Plan", language)} ${DateTools.formatDuration(plannedSeconds, language)}",
                progress = todaySeconds.toFloat() / plannedSeconds.coerceAtLeast(1).toFloat(),
                meta = "${syncDeviceCount} ${L10n.text("台同步设备", "sync devices", language)} · $syncState"
            ))
            addView(AppUi.primaryButton(this@MainActivity, L10n.text("立即同步", "Sync Now", language)) {
                GuardianService.sendAction(this@MainActivity, GuardianService.ACTION_SYNC_NOW)
                render()
            })
            addView(AppUi.actionList(
                this@MainActivity,
                listOf(
                    UiActionItem(
                        icon = "R",
                        title = L10n.text("报告", "Report", language),
                        subtitle = L10n.text("查看日报、多日报和设备明细", "Daily, multi-day, and device details", language)
                    ) { startActivity(Intent(this@MainActivity, ReportActivity::class.java)) },
                    UiActionItem(
                        icon = "S",
                        title = L10n.text("设置", "Settings", language),
                        subtitle = L10n.text("同步码、提醒和权限", "Sync code, reminders, and permissions", language)
                    ) { startActivity(Intent(this@MainActivity, SettingsActivity::class.java)) },
                    UiActionItem(
                        icon = "T",
                        title = L10n.text("跟踪", "Tracking", language),
                        subtitle = "LLM Ranking"
                    ) { startActivity(Intent(this@MainActivity, TrackingActivity::class.java)) },
                    UiActionItem(
                        icon = "?",
                        title = L10n.text("关于", "About", language),
                        subtitle = L10n.text("版本、说明和隐私", "Version, usage, and privacy", language)
                    ) { showAbout() }
                )
            ))
            addView(AppUi.section(
                this@MainActivity,
                L10n.text("上周摘要", "Previous Week", language),
                AppUi.summaryCard(
                    this@MainActivity,
                    L10n.text("跨平台统计", "Cross-device summary", language),
                    listOf(
                        L10n.text("平均每天", "Daily average", language) to weekAverage,
                        L10n.text("总用时", "Total", language) to DateTools.formatDuration(summary.totalSeconds, language),
                        L10n.text("最多平台", "Top platform", language) to topPlatformText
                    )
                )
            ))
            addView(AppUi.section(
                this@MainActivity,
                L10n.text("状态", "Status", language),
                AppUi.summaryCard(
                    this@MainActivity,
                    L10n.text("权限和同步", "Permissions and sync", language),
                    listOf(
                        "Usage Access" to if (hasUsageAccess()) L10n.text("已授权", "Granted", language) else L10n.text("未授权", "Not granted", language),
                        L10n.text("通知权限", "Notifications", language) to if (hasNotificationPermission()) L10n.text("已授权", "Granted", language) else L10n.text("未授权", "Not granted", language),
                        L10n.text("悬浮窗提醒", "Overlay reminders", language) to if (Settings.canDrawOverlays(this@MainActivity)) L10n.text("已授权", "Granted", language) else L10n.text("未授权", "Not granted", language),
                        "P2P ${L10n.text("状态", "Status", language)}" to syncState,
                        L10n.text("日期", "Date", language) to DateTools.dateString(today)
                    )
                )
            ))
        }
        setContentView(AppUi.page(this, root))
    }

    private fun showAbout() {
        val language = store.language
        val usageGuide = L10n.text(
            "使用说明：\n1. 本 App 利用 P2P 同步你的不同设备，以统计你总的屏幕使用时间。请在各平台 App 中设置统一的同步码，建议不要使用本 App 默认的同步码。\n2. 本 App 不使用云端数据，所有数据都保存在你的本地设备，请放心使用。\n3. 只有你同意的设备才会同步。",
            "Usage:\n1. This app uses P2P to sync your devices and calculate your total screen time. Set the same sync code in every app, and avoid using the default code.\n2. This app does not use cloud data. All data stays on your local devices.\n3. Only devices you approve can sync.",
            language
        )
        android.app.AlertDialog.Builder(this)
            .setTitle("Screen Time Guardian")
            .setMessage("${L10n.text("开发者", "Developer", language)}：TimberTrail\n${L10n.text("版本", "Version", language)}：${SessionStore.APP_VERSION}\n${L10n.text("免费使用", "Free to use", language)}\n\n$usageGuide")
            .setPositiveButton(L10n.text("关闭", "Close", language), null)
            .show()
    }

    private fun hasUsageAccess(): Boolean {
        val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                android.os.Process.myUid(),
                packageName
            )
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun requestRuntimePermissionsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        val permissions = mutableListOf<String>()
        if (checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (permissions.isNotEmpty()) {
            requestPermissions(permissions.toTypedArray(), REQUEST_RUNTIME_PERMISSIONS)
        }
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val REQUEST_RUNTIME_PERMISSIONS = 2001
    }
}
