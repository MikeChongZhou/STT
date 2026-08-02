package com.timbertrail.screentimeguardian

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.provider.Settings
import java.time.Instant

class SettingsActivity : Activity() {
    private lateinit var store: SessionStore
    private lateinit var languageInput: EditText
    private lateinit var deviceNameInput: EditText
    private lateinit var postureSwitchBox: CheckBox
    private lateinit var eyeRestIntervalInput: EditText
    private lateinit var postureRestIntervalInput: EditText
    private lateinit var plannedDailyHoursInput: EditText
    private lateinit var plannedDailyMinutesInput: EditText
    private lateinit var trackingInput: EditText
    private lateinit var meetingModeBox: CheckBox
    private lateinit var autoStartBox: CheckBox
    private lateinit var p2pEnabledBox: CheckBox
    private lateinit var pairingCodeInput: EditText
    private lateinit var syncIntervalInput: EditText
    private lateinit var peerList: LinearLayout
    private lateinit var p2pStatusView: TextView
    private var selectedLanguage = "zh"
    private val currentLanguage: String
        get() = selectedLanguage

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SessionStore(this)
        GuardianService.start(this)
        buildUi()
    }

    private fun buildUi() {
        selectedLanguage = store.language
        val language = selectedLanguage
        val plannedDailyMinutes = store.plannedDailyMinutes
        languageInput = textInput(store.language)
        deviceNameInput = textInput(store.deviceName)
        plannedDailyHoursInput = numberInput(plannedDailyMinutes / 60)
        plannedDailyMinutesInput = numberInput(plannedDailyMinutes % 60)
        eyeRestIntervalInput = numberInput(store.eyeRestIntervalMinutes)
        postureRestIntervalInput = numberInput(SessionStore.derivedPostureRestIntervalMinutes(store.eyeRestIntervalMinutes)).apply {
            isEnabled = false
        }
        trackingInput = textInput(store.trackingObject)
        postureSwitchBox = CheckBox(this).apply {
            text = L10n.text("启用姿势切换", "Enable posture switch", language)
            isChecked = store.postureSwitchEnabled
        }
        meetingModeBox = CheckBox(this).apply {
            text = L10n.text("会议模式", "Meeting Mode", language)
            isChecked = store.meetingMode
        }
        autoStartBox = CheckBox(this).apply {
            text = L10n.text("系统启动时自动启动", "Launch at system startup", language)
            isChecked = store.autoStartEnabled
        }
        p2pEnabledBox = CheckBox(this).apply {
            text = L10n.text("启用局域网 P2P 同步", "Enable local network P2P sync", language)
            isChecked = store.p2pSyncEnabled
        }
        pairingCodeInput = numberInput(store.p2pPairingCode)
        syncIntervalInput = numberInput(store.p2pSyncIntervalMinutes)
        peerList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        val root = AppUi.pageStack(this).apply {
            addView(AppUi.title(this@SettingsActivity, L10n.text("设置", "Settings", language)))
            addView(AppUi.section(this@SettingsActivity, L10n.text("通用", "General", language), AppUi.surface(this@SettingsActivity).apply {
                addView(AppUi.segmentedControl(
                    this@SettingsActivity,
                    listOf("中文", "English"),
                    if (selectedLanguage == "en") 1 else 0
                ) { index ->
                    selectedLanguage = if (index == 1) "en" else "zh"
                    applySettingsFromControls(refreshP2P = false)
                    buildUi()
                })
            addRow(L10n.text("设备名称", "Device Name", language), deviceNameInput)
                addRow(L10n.text("跟踪对象", "Tracking Target", language), trackingInput)
                addView(TextView(this@SettingsActivity).apply {
                    text = "${L10n.text("数据目录", "Data Directory", language)}：${store.dataDirectory}"
                    setTextIsSelectable(true)
                    setPadding(0, 12, 0, 8)
                })
            }))
            addView(AppUi.section(this@SettingsActivity, L10n.text("提醒", "Reminders", language), AppUi.surface(this@SettingsActivity).apply {
            addView(postureSwitchBox)
            addRow(L10n.text("护眼间隔（分钟）", "Eye Rest Interval (minutes)", language), eyeRestIntervalInput)
            addRow(L10n.text("姿势提醒间隔", "Posture Interval", language), postureRestIntervalInput)
            addView(TextView(this@SettingsActivity).apply {
                text = L10n.text("姿势切换按护眼间隔的 2 倍提醒。", "Posture switch uses 2x the eye-rest interval.", language)
                setPadding(0, 4, 0, 8)
            })
            addView(TextView(this@SettingsActivity).apply {
                text = L10n.text("每日计划用时", "Daily Plan", language)
                setPadding(0, 8, 0, 0)
            })
            addView(plannedDailyPanel(language))
            addView(meetingModeBox)
            addView(autoStartBox)
            }))
            addView(AppUi.section(this@SettingsActivity, L10n.text("权限", "Permissions", language), AppUi.surface(this@SettingsActivity).apply {
                addView(statusLine(L10n.text("通知权限", "Notifications", language), if (hasNotificationPermission()) L10n.text("已授权", "Granted", language) else L10n.text("未授权", "Not granted", language)))
                addView(statusLine(L10n.text("非会议模式提醒声音", "Non-meeting reminder sound", language), promptSoundStatus(language)))
                addView(statusLine(L10n.text("悬浮窗提醒", "Overlay reminders", language), if (Settings.canDrawOverlays(this@SettingsActivity)) L10n.text("已授权", "Granted", language) else L10n.text("未授权", "Not granted", language)))
                addView(AppUi.buttonRow(
                    this@SettingsActivity,
                    AppUi.button(this@SettingsActivity, L10n.text("通知设置", "Notification Settings", language)) { openAppNotificationSettings() },
                    AppUi.button(this@SettingsActivity, L10n.text("提醒声音", "Reminder Sound", language)) { openPromptNotificationSettings() }
                ))
                addView(AppUi.buttonRow(
                    this@SettingsActivity,
                    AppUi.button(this@SettingsActivity, L10n.text("悬浮窗权限", "Overlay Permission", language)) { startActivity(GuardianService.overlaySettingsIntent(this@SettingsActivity)) },
                    AppUi.button(this@SettingsActivity, L10n.text("电池优化设置", "Battery Optimization", language)) { startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)) }
                ))
            }))
            addView(AppUi.section(this@SettingsActivity, "P2P ${L10n.text("同步", "Sync", language)}", AppUi.surface(this@SettingsActivity).apply {
            addView(p2pEnabledBox)
            addRow(L10n.text("P2P 配对码", "P2P Pairing Code", language), pairingCodeInput)
            addRow(L10n.text("同步间隔（分钟）", "Sync Interval (minutes)", language), syncIntervalInput)
                addView(AppUi.buttonRow(
                    this@SettingsActivity,
                    AppUi.button(this@SettingsActivity, L10n.text("立即同步", "Sync Now", language)) {
                    applySettingsFromControls(refreshP2P = true)
                    GuardianRuntime.p2pTransport?.syncNow()
                    refreshPeers()
                },
                    AppUi.button(this@SettingsActivity, L10n.text("刷新设备", "Refresh Devices", language)) { refreshPeers() }
            ))
            p2pStatusView = TextView(this@SettingsActivity).apply {
                text = L10n.syncStatus(GuardianRuntime.p2pTransport?.status ?: L10n.text("P2P 后台服务初始化中", "P2P background service is starting", language), language)
                setPadding(0, 12, 0, 8)
            }
            addView(p2pStatusView)
            }))
            addView(AppUi.section(this@SettingsActivity, L10n.text("同步设备", "Sync Devices", language), AppUi.surface(this@SettingsActivity).apply {
            addView(peerList)
            }))
            addView(AppUi.buttonRow(
                this@SettingsActivity,
                AppUi.button(this@SettingsActivity, L10n.text("保存", "Save", language)) { saveAndClose() },
                AppUi.button(this@SettingsActivity, L10n.text("取消", "Cancel", language)) { finish() }
            ))
        }
        setContentView(AppUi.page(this, root))
        refreshPeers()
    }

    private fun refreshPeers() {
        val language = currentLanguage
        if (::p2pStatusView.isInitialized) {
            p2pStatusView.text = L10n.syncStatus(GuardianRuntime.p2pTransport?.status ?: L10n.text("P2P 后台服务初始化中", "P2P background service is starting", language), language)
        }
        peerList.removeAllViews()
        val livePeers = GuardianRuntime.p2pTransport?.peersSnapshot().orEmpty()
        val devices = store.syncDeviceLedger(livePeers)
        if (devices.isEmpty()) {
            peerList.addView(TextView(this).apply {
                text = L10n.text("暂无发现设备。请确认设备在同一局域网，并使用相同配对码。", "No devices found. Make sure devices are on the same local network and use the same pairing code.", language)
                setPadding(0, 8, 0, 12)
            })
            return
        }
        devices.forEach { device ->
            val reachability = when {
                device.isLocal -> L10n.text("本机", "This device", language)
                device.isLive -> L10n.text("当前在线", "Online now", language)
                else -> L10n.text("当前未发现", "Not currently discovered", language)
            }
            val lastSeen = if (device.lastSeenAt == Instant.EPOCH) {
                ""
            } else {
                "\n${L10n.text("最后出现", "Last seen", language)}：${DateTools.dateTimeString(device.lastSeenAt)}"
            }
            peerList.addView(TextView(this).apply {
                text = "${device.deviceName} / ${DateTools.platformTitle(device.platform)} / $reachability\n${device.deviceId}\n${L10n.syncStatus(device.trustStatus, language)}，${L10n.syncStatus(device.lastStatus, language)}$lastSeen"
                setTextIsSelectable(true)
                setPadding(0, 12, 0, 4)
            })
            if (!device.isLocal) {
                val approveButton = button(L10n.text("同意", "Approve", language)) {
                    GuardianRuntime.p2pTransport?.approvePeer(device.deviceId) ?: store.trustPeer(device.deviceId)
                    refreshPeers()
                }.apply {
                    isEnabled = device.trustStatus != "已同意"
                }
                val rejectButton = button(L10n.text("拒绝", "Reject", language)) {
                    GuardianRuntime.p2pTransport?.rejectPeer(device.deviceId) ?: store.rejectPeer(device.deviceId)
                    refreshPeers()
                }.apply {
                    isEnabled = device.trustStatus != "已拒绝"
                }
                peerList.addView(buttonRow(approveButton, rejectButton))
            }
        }
    }

    private fun saveAndClose() {
        applySettingsFromControls(refreshP2P = true)
        finish()
    }

    private fun applySettingsFromControls(refreshP2P: Boolean) {
        store.language = selectedLanguage
        store.deviceName = deviceNameInput.text.toString()
        store.postureSwitchEnabled = postureSwitchBox.isChecked
        store.eyeRestIntervalMinutes = eyeRestIntervalInput.text.toString().toIntOrNull() ?: store.eyeRestIntervalMinutes
        store.postureRestIntervalMinutes = SessionStore.derivedPostureRestIntervalMinutes(store.eyeRestIntervalMinutes)
        store.plannedDailyMinutes = readPlannedDailyMinutes()
        store.trackingObject = trackingInput.text.toString().ifBlank { "LLM Ranking" }
        store.meetingMode = meetingModeBox.isChecked
        store.autoStartEnabled = autoStartBox.isChecked
        store.p2pSyncEnabled = p2pEnabledBox.isChecked
        store.p2pPairingCode = pairingCodeInput.text.toString()
        store.p2pSyncIntervalMinutes = syncIntervalInput.text.toString().toIntOrNull() ?: store.p2pSyncIntervalMinutes
        if (refreshP2P) {
            GuardianRuntime.p2pTransport?.refresh()
        }
    }

    private fun title(value: String): TextView =
        TextView(this).apply {
            text = value
            textSize = 22f
            gravity = Gravity.START
            setPadding(0, 12, 0, 8)
        }

    private fun textInput(value: String): EditText =
        EditText(this).apply {
            setText(value)
            setSingleLine(true)
            AppUi.styleTextField(this@SettingsActivity, this)
        }

    private fun numberInput(value: Int): EditText = numberInput(value.toString())

    private fun numberInput(value: String): EditText =
        EditText(this).apply {
            setText(value)
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_NUMBER
            AppUi.styleTextField(this@SettingsActivity, this)
        }

    private fun plannedDailyPanel(language: String): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            plannedDailyHoursInput.layoutParams = LinearLayout.LayoutParams(
                AppUi.dp(this@SettingsActivity, 74),
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            plannedDailyMinutesInput.layoutParams = LinearLayout.LayoutParams(
                AppUi.dp(this@SettingsActivity, 74),
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            addView(plannedDailyHoursInput)
            addView(TextView(this@SettingsActivity).apply {
                text = L10n.text("小时", "h", language)
                setPadding(AppUi.dp(this@SettingsActivity, 8), 0, AppUi.dp(this@SettingsActivity, 16), 0)
            })
            addView(plannedDailyMinutesInput)
            addView(TextView(this@SettingsActivity).apply {
                text = L10n.text("分钟", "min", language)
                setPadding(AppUi.dp(this@SettingsActivity, 8), 0, AppUi.dp(this@SettingsActivity, 16), 0)
            })
            addView(TextView(this@SettingsActivity).apply {
                text = L10n.text("默认 8小时0分钟", "Default 8h 0m", language)
            })
        }

    private fun readPlannedDailyMinutes(): Int {
        val hours = (plannedDailyHoursInput.text.toString().toIntOrNull() ?: 8).coerceIn(0, 24)
        val minutes = (plannedDailyMinutesInput.text.toString().toIntOrNull() ?: 0).coerceIn(0, 59)
        val total = hours * 60 + minutes
        return if (total <= 0) 480 else total.coerceIn(1, 1440)
    }

    private fun statusLine(label: String, value: String): TextView =
        AppUi.keyValueRow(this, label, value)

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun promptSoundStatus(language: String): String {
        if (!hasNotificationPermission()) return L10n.text("未授权", "Not granted", language)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = manager.getNotificationChannel(GuardianService.PROMPT_CHANNEL_ID)
            if (channel == null || channel.importance == NotificationManager.IMPORTANCE_NONE) {
                return L10n.text("已关闭", "Off", language)
            }
            return if (channel.sound == null) L10n.text("静音", "Silent", language) else L10n.text("已开启", "On", language)
        }
        return L10n.text("已开启", "On", language)
    }

    private fun openAppNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
        }
        startActivity(intent)
    }

    private fun openPromptNotificationSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                    .putExtra(Settings.EXTRA_CHANNEL_ID, GuardianService.PROMPT_CHANNEL_ID)
            )
        } else {
            openAppNotificationSettings()
        }
    }

    private fun LinearLayout.addRow(label: String, input: EditText) {
        addView(AppUi.fieldLabel(this@SettingsActivity, label))
        input.layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        )
        addView(input)
    }

    private fun button(title: String, action: () -> Unit): Button =
        AppUi.button(this, title, action)

    private fun buttonRow(vararg buttons: Button): LinearLayout =
        AppUi.buttonRow(this, *buttons)
}
