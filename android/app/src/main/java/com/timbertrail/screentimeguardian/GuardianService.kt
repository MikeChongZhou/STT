package com.timbertrail.screentimeguardian

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class GuardianService : Service() {
    private lateinit var store: SessionStore
    private lateinit var p2pTransport: P2PTransport
    private lateinit var usageStatsBridge: UsageStatsBridge
    private val handler = Handler(Looper.getMainLooper())
    private var receiver: BroadcastReceiver? = null
    private var overlayView: View? = null
    private var pausedForReport = false
    private var promptShowing = false
    private var activePromptStopAction: String? = null
    private var eyeActiveSeconds = 0
    private var postureActiveSeconds = 0
    private var lastSampleAtMillis = 0L
    private var lastHeartbeatAtMillis = 0L
    private var lastSessionDate: LocalDate? = null
    private val language: String
        get() = store.language

    private val tickRunnable = object : Runnable {
        override fun run() {
            tick()
            handler.postDelayed(this, 10_000L)
        }
    }

    override fun onCreate() {
        super.onCreate()
        store = SessionStore(this)
        usageStatsBridge = UsageStatsBridge(this)
        store.recoverOpenSessions()
        p2pTransport = P2PTransport(this, store)
        p2pTransport.onStateChanged = { updateStatus("P2P：${L10n.syncStatus(p2pTransport.status, language)}") }
        GuardianRuntime.p2pTransport = p2pTransport
        createNotificationChannel()
        startAsForeground()
        registerScreenReceiver()
        p2pTransport.start()
        resetReminderSampling()
        if (isActiveScreen(Instant.now())) {
            store.startSession()
            lastSessionDate = LocalDate.now(ZoneId.systemDefault())
        }
        handler.post(tickRunnable)
        updateStatus(L10n.text("后台计时已启动", "Background timing started", language))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                store.endOpenSessions("app_exit")
                stopSelf()
            }
            ACTION_PROMPT_CLOSED -> closePromptAndResume()
            ACTION_REPORT_OPENED -> {
                pausedForReport = true
                store.endOpenSessions("report_opened")
                resetReminderSampling()
                updateStatus(L10n.text("报告已打开，暂停当前计时", "Report opened; current timing paused", language))
            }
            ACTION_REPORT_CLOSED -> {
                pausedForReport = false
                resumeCountingAfterPause()
            }
            ACTION_SYNC_NOW -> p2pTransport.syncNow()
            else -> Unit
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tickRunnable)
        removeOverlay()
        receiver?.let { unregisterReceiver(it) }
        receiver = null
        p2pTransport.stop()
        GuardianRuntime.p2pTransport = null
        store.endOpenSessions("app_exit")
        updateStatus(L10n.text("后台服务已停止", "Background service stopped", language))
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun tick() {
        if (pausedForReport || promptShowing) {
            lastSampleAtMillis = System.currentTimeMillis()
            return
        }

        val now = Instant.now()
        store.closeExpiredOpenSessions(now)
        if (!isActiveScreen(now)) {
            store.endOpenSessions("standby_started", now)
            resetReminderCounters()
            updateStatus(L10n.text("屏幕未激活，已保存用时", "Screen inactive; usage saved", language))
            return
        }

        rolloverAtLocalMidnight(now)
        store.startSession(now)
        if (System.currentTimeMillis() - lastHeartbeatAtMillis >= 60_000L) {
            store.heartbeatOpenSession(now)
            lastHeartbeatAtMillis = System.currentTimeMillis()
        }

        accumulateReminderSeconds()
        checkTimeoutPlan(now)
        if (!promptShowing) checkRestReminders()
        updateStatus("${L10n.text("后台计时中，今日", "Background timing; today", language)} ${DateTools.formatDuration(store.currentDayTotalSeconds(now), language)}")
    }

    private fun rolloverAtLocalMidnight(now: Instant) {
        val today = LocalDate.now(ZoneId.systemDefault())
        val open = store.openSession()
        val openDate = open?.startAtUtc?.atZone(ZoneId.systemDefault())?.toLocalDate()
        if (open != null && openDate != null && openDate.isBefore(today)) {
            val midnight = today.atStartOfDay(ZoneId.systemDefault()).toInstant()
            store.endOpenSessions("app_backgrounded", midnight)
            store.startSession(midnight)
            resetReminderCounters()
        }
        lastSessionDate = today
    }

    private fun checkRestReminders() {
        val eyeRestMinutes = store.eyeRestIntervalMinutes.coerceAtLeast(1)
        val eyeRestSeconds = eyeRestMinutes * 60
        val postureRestSeconds = SessionStore.derivedPostureRestIntervalMinutes(eyeRestMinutes) * 60
        val postureDue = store.postureSwitchEnabled && postureActiveSeconds >= postureRestSeconds
        if (eyeActiveSeconds >= eyeRestSeconds || postureDue) {
            resetEyeReminderCounter()
            if (postureDue) {
                postureActiveSeconds = 0
            }
            val includePosture = postureDue
            showPrompt(
                title = if (includePosture) {
                    L10n.text("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder", language)
                } else {
                    L10n.text("用眼休息提醒", "Eye Rest Reminder", language)
                },
                message = if (includePosture) {
                    L10n.text("请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。", "Switch between sitting and standing, then look 20 feet away to rest your eyes.", language)
                } else {
                    L10n.text("请看 20 英尺外 20 秒。", "Look at something 20 feet away for 20 seconds.", language)
                },
                stopAction = if (includePosture) "posture_rest_prompt" else "eye_rest_prompt",
                countdownSeconds = if (includePosture) 60 else 20
            )
        }
    }

    private fun checkTimeoutPlan(now: Instant) {
        val total = store.currentDayTotalSeconds(now)
        val plannedSeconds = store.plannedDailyMinutes * 60
        if (total < plannedSeconds) return

        val today = DateTools.dateString(LocalDate.now(ZoneId.systemDefault()))
        val lastAt = store.lastTimeoutPromptAtMillis
        val throttled = store.lastTimeoutPromptDate == today &&
            lastAt > 0 &&
            System.currentTimeMillis() - lastAt < 25 * 60_000L
        if (throttled) return

        store.lastTimeoutPromptDate = today
        store.lastTimeoutPromptAtMillis = System.currentTimeMillis()
        showPrompt(
            title = L10n.text("每日计划提醒", "Daily Plan Reminder", language),
            message = L10n.text("今天屏幕总用时已超过", "Today's total screen time has exceeded", language) + " ${DateTools.formatDuration(store.plannedDailyMinutes * 60, language)}。",
            stopAction = "timeout_prompt",
            countdownSeconds = 120
        )
    }

    private fun showPrompt(title: String, message: String, stopAction: String, countdownSeconds: Int) {
        if (promptShowing) return
        promptShowing = true
        activePromptStopAction = stopAction
        store.endOpenSessions(stopAction)
        resetReminderSampling()
        val immediateClose = store.meetingMode
        val canCloseAtMillis = if (immediateClose) {
            System.currentTimeMillis()
        } else {
            System.currentTimeMillis() + countdownSeconds.coerceAtLeast(0) * 1000L
        }
        if (Settings.canDrawOverlays(this)) {
            showPromptNotification(title, message, countdownSeconds, immediateClose, canCloseAtMillis)
            showOverlayPrompt(title, message, immediateClose, canCloseAtMillis)
        } else {
            showPromptActivity(title, message, countdownSeconds, immediateClose, canCloseAtMillis)
        }
    }

    private fun showOverlayPrompt(title: String, message: String, immediateClose: Boolean, canCloseAtMillis: Long) {
        removeOverlay()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.argb(232, 18, 24, 32))
            setPadding(48, 48, 48, 48)
        }
        val titleView = TextView(this).apply {
            text = title
            textSize = 26f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        val messageView = TextView(this).apply {
            text = message
            textSize = 18f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
            setPadding(0, 20, 0, 20)
        }
        val countdownView = TextView(this).apply {
            textSize = 18f
            typeface = Typeface.MONOSPACE
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        val closeButton = Button(this).apply {
            text = L10n.text("关闭", "Close", language)
            isEnabled = immediateClose
            setOnClickListener { closePromptAndResume() }
        }
        root.addView(titleView)
        root.addView(messageView)
        root.addView(countdownView)
        root.addView(closeButton)
        overlayView = root

        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
            android.graphics.PixelFormat.TRANSLUCENT
        )
        val windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        windowManager.addView(root, params)
        runCountdown(immediateClose, canCloseAtMillis, countdownView, closeButton)
    }

    private fun runCountdown(immediateClose: Boolean, canCloseAtMillis: Long, countdownView: TextView, closeButton: Button) {
        if (immediateClose) {
            countdownView.text = L10n.text("会议模式：可以立即关闭", "Meeting mode: can close immediately", language)
            closeButton.isEnabled = true
            return
        }
        val runnable = object : Runnable {
            override fun run() {
                if (!promptShowing) return
                val remaining = (((canCloseAtMillis - System.currentTimeMillis()) + 999L) / 1000L).toInt()
                if (remaining <= 0) {
                    countdownView.text = L10n.text("可以关闭", "Ready to close", language)
                    closeButton.isEnabled = true
                    return
                }
                countdownView.text = if (language == "en") "${remaining} seconds remaining" else "剩余 ${remaining} 秒"
                handler.postDelayed(this, 1000L)
            }
        }
        handler.post(runnable)
    }

    private fun showPromptActivity(title: String, message: String, countdownSeconds: Int, immediateClose: Boolean, canCloseAtMillis: Long) {
        val activityIntent = Intent(this, RestPromptActivity::class.java)
            .putExtra(EXTRA_PROMPT_TITLE, title)
            .putExtra(EXTRA_PROMPT_MESSAGE, message)
            .putExtra(EXTRA_PROMPT_COUNTDOWN, countdownSeconds)
            .putExtra(EXTRA_PROMPT_IMMEDIATE, immediateClose)
            .putExtra(EXTRA_PROMPT_CAN_CLOSE_AT, canCloseAtMillis)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        runCatching { startActivity(activityIntent) }
        showPromptNotification(title, message, countdownSeconds, immediateClose, canCloseAtMillis)
    }

    private fun showPromptNotification(title: String, message: String, countdownSeconds: Int, immediateClose: Boolean, canCloseAtMillis: Long) {
        val activityIntent = Intent(this, RestPromptActivity::class.java)
            .putExtra(EXTRA_PROMPT_TITLE, title)
            .putExtra(EXTRA_PROMPT_MESSAGE, message)
            .putExtra(EXTRA_PROMPT_COUNTDOWN, countdownSeconds)
            .putExtra(EXTRA_PROMPT_IMMEDIATE, immediateClose)
            .putExtra(EXTRA_PROMPT_CAN_CLOSE_AT, canCloseAtMillis)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val pendingIntent = PendingIntent.getActivity(
            this,
            20,
            activityIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val promptChannelId = if (immediateClose) PROMPT_SILENT_CHANNEL_ID else PROMPT_CHANNEL_ID
        val builder = notificationBuilder(promptChannelId)
            .setSmallIcon(R.drawable.stg_icon)
            .setContentTitle(title)
            .setContentText(message)
            .setContentIntent(pendingIntent)
            .setAutoCancel(false)
            .setOngoing(true)
        if (immediateClose) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                @Suppress("DEPRECATION")
                builder.setSound(null)
                @Suppress("DEPRECATION")
                builder.setVibrate(longArrayOf(0L))
            }
        } else if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setDefaults(Notification.DEFAULT_SOUND)
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_HIGH)
        }
        val notification = builder.build()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).notify(PROMPT_NOTIFICATION_ID, notification)
    }

    private fun closePromptAndResume() {
        activePromptStopAction = null
        promptShowing = false
        removeOverlay()
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(PROMPT_NOTIFICATION_ID)
        resetReminderSampling()
        if (!pausedForReport && isActiveScreen(Instant.now())) {
            store.startSession()
        }
        updateStatus(L10n.text("提醒已关闭，计时已恢复", "Reminder closed; timing resumed", language))
    }

    private fun resumeCountingAfterPause() {
        resetReminderSampling()
        if (!promptShowing && isActiveScreen(Instant.now())) {
            store.startSession()
        }
        updateStatus(L10n.text("计时已恢复", "Timing resumed", language))
    }

    private fun removeOverlay() {
        val view = overlayView ?: return
        overlayView = null
        runCatching {
            (getSystemService(WINDOW_SERVICE) as WindowManager).removeView(view)
        }
    }

    private fun registerScreenReceiver() {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_USER_PRESENT)
            addAction(Intent.ACTION_SHUTDOWN)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    Intent.ACTION_SCREEN_OFF -> {
                        store.endOpenSessions("standby_started")
                        resetReminderCounters()
                    }
                    Intent.ACTION_SCREEN_ON, Intent.ACTION_USER_PRESENT -> {
                        if (!pausedForReport && !promptShowing) {
                            store.startSession()
                            resetReminderCounters()
                        }
                    }
                    Intent.ACTION_SHUTDOWN -> store.endOpenSessions("shutdown_started")
                }
            }
        }
        registerReceiver(receiver, filter)
    }

    private fun accumulateReminderSeconds() {
        val now = System.currentTimeMillis()
        if (lastSampleAtMillis <= 0L) {
            lastSampleAtMillis = now
            return
        }
        val delta = ((now - lastSampleAtMillis) / 1000L).toInt()
        if (delta > 0) {
            eyeActiveSeconds += delta
            postureActiveSeconds += delta
            lastSampleAtMillis = now
        }
    }

    private fun resetReminderCounters() {
        eyeActiveSeconds = 0
        postureActiveSeconds = 0
        resetReminderSampling()
    }

    private fun resetEyeReminderCounter() {
        eyeActiveSeconds = 0
        resetReminderSampling()
    }

    private fun resetReminderSampling() {
        lastSampleAtMillis = System.currentTimeMillis()
    }

    private fun isInteractive(): Boolean =
        (getSystemService(POWER_SERVICE) as PowerManager).isInteractive

    private fun isActiveScreen(now: Instant): Boolean =
        isInteractive() || usageStatsBridge.sawForegroundActivitySince(now.minusSeconds(75), now)

    private fun updateStatus(status: String) {
        GuardianRuntime.serviceStatus = status
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val statusChannel = NotificationChannel(STATUS_CHANNEL_ID, "Screen Time Guardian", NotificationManager.IMPORTANCE_LOW)
            statusChannel.description = L10n.text("Screen Time Guardian 后台计时和局域网同步", "Screen Time Guardian background timing and local network sync", language)
            val promptChannel = NotificationChannel(PROMPT_CHANNEL_ID, "Screen Time Guardian Reminders", NotificationManager.IMPORTANCE_HIGH)
            promptChannel.description = L10n.text("护眼、姿势切换和计划超时提醒", "Eye rest, posture switch, and daily plan reminders", language)
            promptChannel.enableVibration(true)
            val silentPromptChannel = NotificationChannel(PROMPT_SILENT_CHANNEL_ID, "Screen Time Guardian Meeting Reminders", NotificationManager.IMPORTANCE_HIGH)
            silentPromptChannel.description = L10n.text("会议模式下的静音提醒", "Silent reminders used while meeting mode is on", language)
            silentPromptChannel.setSound(null, null)
            silentPromptChannel.enableVibration(false)
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).apply {
                createNotificationChannel(statusChannel)
                createNotificationChannel(promptChannel)
                createNotificationChannel(silentPromptChannel)
            }
        }
    }

    private fun startAsForeground() {
        val notification = statusNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun statusNotification(): Notification {
        val mainIntent = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, GuardianService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val syncIntent = PendingIntent.getService(
            this,
            3,
            Intent(this, GuardianService::class.java).setAction(ACTION_SYNC_NOW),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return notificationBuilder()
            .setSmallIcon(R.drawable.stg_icon)
            .setContentTitle("Screen Time Guardian")
            .setContentText(L10n.text("正在记录屏幕用时并同步已同意设备", "Recording screen time and syncing approved devices", language))
            .setContentIntent(mainIntent)
            .addAction(R.drawable.stg_icon, L10n.text("立即同步", "Sync Now", language), syncIntent)
            .addAction(R.drawable.stg_icon, L10n.text("停止", "Stop", language), stopIntent)
            .setOngoing(true)
            .build()
    }

    private fun notificationBuilder(channelId: String = STATUS_CHANNEL_ID): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

    companion object {
        const val ACTION_START = "com.timbertrail.screentimeguardian.START"
        const val ACTION_STOP = "com.timbertrail.screentimeguardian.STOP"
        const val ACTION_PROMPT_CLOSED = "com.timbertrail.screentimeguardian.PROMPT_CLOSED"
        const val ACTION_REPORT_OPENED = "com.timbertrail.screentimeguardian.REPORT_OPENED"
        const val ACTION_REPORT_CLOSED = "com.timbertrail.screentimeguardian.REPORT_CLOSED"
        const val ACTION_SYNC_NOW = "com.timbertrail.screentimeguardian.SYNC_NOW"
        const val EXTRA_PROMPT_TITLE = "prompt_title"
        const val EXTRA_PROMPT_MESSAGE = "prompt_message"
        const val EXTRA_PROMPT_COUNTDOWN = "prompt_countdown"
        const val EXTRA_PROMPT_IMMEDIATE = "prompt_immediate"
        const val EXTRA_PROMPT_CAN_CLOSE_AT = "prompt_can_close_at"
        private const val STATUS_CHANNEL_ID = "screen_time_guardian"
        const val PROMPT_CHANNEL_ID = "screen_time_guardian_prompt"
        private const val PROMPT_SILENT_CHANNEL_ID = "screen_time_guardian_prompt_silent"
        private const val NOTIFICATION_ID = 1106
        private const val PROMPT_NOTIFICATION_ID = 1107

        fun start(context: Context) {
            val intent = Intent(context, GuardianService::class.java).setAction(ACTION_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun sendAction(context: Context, action: String) {
            val intent = Intent(context, GuardianService::class.java).setAction(action)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun overlaySettingsIntent(context: Context): Intent =
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${context.packageName}"))
    }
}
