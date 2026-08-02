package com.timbertrail.screentimeguardian

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

class ReportActivity : Activity() {
    private lateinit var store: SessionStore
    private lateinit var controlsHost: LinearLayout
    private lateinit var reportHost: LinearLayout
    private lateinit var dateInput: EditText
    private lateinit var startInput: EditText
    private lateinit var endInput: EditText
    private var mode = 0
    private val language: String
        get() = store.language

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SessionStore(this)
        GuardianService.sendAction(this, GuardianService.ACTION_REPORT_OPENED)
        buildUi()
    }

    override fun onDestroy() {
        GuardianService.sendAction(this, GuardianService.ACTION_REPORT_CLOSED)
        super.onDestroy()
    }

    private fun buildUi() {
        val root = AppUi.pageStack(this)
        root.addView(AppUi.title(this, L10n.text("报告", "Report", language)))
        root.addView(AppUi.segmentedControl(
            this,
            listOf(L10n.text("日报", "Daily", language), L10n.text("多日报", "Multi-Day", language)),
            mode
        ) { index ->
            mode = index
            rebuildControls()
        })

        controlsHost = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, AppUi.dp(this@ReportActivity, 12), 0, 0)
        }
        reportHost = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(controlsHost)
        root.addView(reportHost)
        root.addView(AppUi.buttonRow(
            this,
            AppUi.button(this, L10n.text("关闭", "Close", language)) { finish() }
        ))
        setContentView(AppUi.page(this, root))
        rebuildControls()
    }

    private fun rebuildControls() {
        controlsHost.removeAllViews()
        val today = LocalDate.now(ZoneId.systemDefault())
        val weekStart = DateTools.currentWeekStartDate()
        if (mode == 0) {
            val value = if (::dateInput.isInitialized) dateInput.text.toString() else DateTools.dateString(today)
            dateInput = dateEdit(value)
            controlsHost.addView(controlSurface(
                L10n.text("日期", "Date", language),
                listOf(dateInput),
                L10n.text("查看日报", "View Daily Report", language)
            ) { fillDaily() })
            controlsHost.addView(AppUi.buttonRow(
                this,
                AppUi.button(this, L10n.text("清除当日记录", "Clear Day Records", language)) { confirmClearDaily() }
            ))
            fillDaily()
        } else {
            val startValue = if (::startInput.isInitialized) startInput.text.toString() else DateTools.dateString(weekStart)
            val endValue = if (::endInput.isInitialized) endInput.text.toString() else DateTools.dateString(today)
            startInput = dateEdit(startValue)
            endInput = dateEdit(endValue)
            controlsHost.addView(controlSurface(
                L10n.text("日期范围", "Date Range", language),
                listOf(
                    labeledInput(L10n.text("开始", "Start", language), startInput),
                    labeledInput(L10n.text("结束", "End", language), endInput)
                ),
                L10n.text("查看多日报", "View Multi-Day Report", language)
            ) { fillMultiDay() })
            fillMultiDay()
        }
    }

    private fun fillDaily() {
        store.closeExpiredOpenSessions()
        val date = DateTools.parseDateOrToday(dateInput.text.toString())
        val zone = ZoneId.systemDefault()
        val start = date.atStartOfDay(zone).toInstant()
        val end = date.plusDays(1).atStartOfDay(zone).toInstant()
        val total = store.totalSecondsForDay(date)
        val details = store.sessionsForDay(date)
        reportHost.removeAllViews()
        reportHost.addView(summarySurface(
            "${L10n.text("日报", "Daily", language)} ${DateTools.dateString(date)}",
            listOf(L10n.text("去重总用时", "Deduplicated Total", language) to DateTools.formatDuration(total, language))
        ))
        addDeviceUsageTable(reportHost, start, end, 1)
        addWeeklyPlatformTable(reportHost)
        addSessionDetailsTable(reportHost, details, start, end)
    }

    private fun confirmClearDaily() {
        AlertDialog.Builder(this)
            .setTitle(L10n.text("清除当日记录？", "Clear this day's records?", language))
            .setMessage(L10n.text(
                "将清除所选日期已记录的屏幕用时，并通过 P2P 同步删除到已同意设备。清除后新产生的记录会继续保存。",
                "This clears recorded screen time for the selected date and syncs the deletion to approved devices. New records after clearing will continue to be saved.",
                language
            ))
            .setPositiveButton(L10n.text("清除", "Clear", language)) { _, _ ->
                val removed = store.clearSessionsForDate(DateTools.parseDateOrToday(dateInput.text.toString()))
                GuardianRuntime.p2pTransport?.syncNow()
                fillDaily()
                reportHost.addView(summarySurface(
                    L10n.text("已清除记录", "Cleared records", language),
                    listOf(L10n.text("数量", "Count", language) to removed.toString())
                ), 0)
            }
            .setNegativeButton(L10n.text("取消", "Cancel", language), null)
            .show()
    }

    private fun fillMultiDay() {
        var startDate = DateTools.parseDateOrToday(startInput.text.toString())
        var endDate = DateTools.parseDateOrToday(endInput.text.toString())
        if (endDate.isBefore(startDate)) {
            val tmp = startDate
            startDate = endDate
            endDate = tmp
        }
        val zone = ZoneId.systemDefault()
        val start = startDate.atStartOfDay(zone).toInstant()
        val endExclusive = endDate.plusDays(1).atStartOfDay(zone).toInstant()
        val dayCount = Duration.between(startDate.atStartOfDay(), endDate.plusDays(1).atStartOfDay()).toDays().toInt().coerceAtLeast(1)
        val total = store.totalUsage(start, endExclusive)
        val dailyRows = store.dailyUsage(startDate, endDate)
        val details = store.sessionsForRange(start, endExclusive)
        reportHost.removeAllViews()
        reportHost.addView(summarySurface(
            "${L10n.text("多日报", "Multi-Day", language)} ${DateTools.dateString(startDate)} ${L10n.text("至", "to", language)} ${DateTools.dateString(endDate)}",
            listOf(
                L10n.text("去重总用时", "Deduplicated Total", language) to DateTools.formatDuration(total, language),
                L10n.text("每天平均", "Daily Average", language) to DateTools.formatDuration(total / dayCount, language)
            )
        ))
        addDeviceUsageTable(reportHost, start, endExclusive, dayCount)
        addWeeklyPlatformTable(reportHost)
        addTableSection(
            parent = reportHost,
            title = L10n.text("每日汇总", "Daily Summary", language),
            columns = listOf(
                UiTableColumn(L10n.text("日期", "Date", language), 140),
                UiTableColumn(L10n.text("去重总用时", "Deduplicated Total", language), 170, Gravity.END or Gravity.CENTER_VERTICAL)
            ),
            rows = dailyRows.map {
                listOf(DateTools.dateString(it.date), DateTools.formatDuration(it.totalSeconds, language))
            }
        )
        addSessionDetailsTable(reportHost, details, start, endExclusive)
    }

    private fun addDeviceUsageTable(parent: LinearLayout, start: Instant, end: Instant, dayCount: Int) {
        addTableSection(
            parent = parent,
            title = L10n.text("本报告范围各设备用时", "Device Usage in This Report", language),
            columns = listOf(
                UiTableColumn(L10n.text("设备", "Device", language), 190),
                UiTableColumn(L10n.text("平台", "Platform", language), 100),
                UiTableColumn(L10n.text("总用时", "Total", language), 140, Gravity.END or Gravity.CENTER_VERTICAL),
                UiTableColumn(L10n.text("平均每天", "Daily Average", language), 150, Gravity.END or Gravity.CENTER_VERTICAL)
            ),
            rows = store.deviceUsage(start, end, dayCount).map {
                listOf(
                    it.deviceName,
                    DateTools.platformTitle(it.platform),
                    DateTools.formatDuration(it.totalSeconds, language),
                    DateTools.formatDuration(it.averageDailySeconds, language)
                )
            }
        )
    }

    private fun addWeeklyPlatformTable(parent: LinearLayout) {
        val weekly = store.previousWeekSummary()
        val rows = mutableListOf(
            listOf(
                L10n.text("全部平台去重", "All Platforms Deduplicated", language),
                DateTools.formatDuration(weekly.totalSeconds, language),
                DateTools.formatDuration(weekly.averageDailySeconds, language)
            )
        )
        rows.addAll(weekly.platforms.map {
            listOf(
                DateTools.platformTitle(it.platform),
                DateTools.formatDuration(it.totalSeconds, language),
                DateTools.formatDuration(it.averageDailySeconds, language)
            )
        })
        addTableSection(
            parent = parent,
            title = L10n.text("上周各平台统计", "Previous Week by Platform", language),
            columns = listOf(
                UiTableColumn(L10n.text("平台", "Platform", language), 210),
                UiTableColumn(L10n.text("上周总计", "Weekly Total", language), 150, Gravity.END or Gravity.CENTER_VERTICAL),
                UiTableColumn(L10n.text("平均每天", "Daily Average", language), 150, Gravity.END or Gravity.CENTER_VERTICAL)
            ),
            rows = rows
        )
    }

    private fun addSessionDetailsTable(parent: LinearLayout, sessions: List<ScreenSession>, start: Instant, end: Instant) {
        val now = Instant.now()
        addTableSection(
            parent = parent,
            title = L10n.text("明细", "Details", language),
            columns = listOf(
                UiTableColumn(L10n.text("开始", "Start", language), 155),
                UiTableColumn(L10n.text("结束", "End", language), 155),
                UiTableColumn(L10n.text("时长", "Duration", language), 115, Gravity.END or Gravity.CENTER_VERTICAL),
                UiTableColumn(L10n.text("停止动作", "Stop Action", language), 150),
                UiTableColumn(L10n.text("平台", "Platform", language), 95),
                UiTableColumn(L10n.text("设备", "Device", language), 180),
                UiTableColumn(L10n.text("范围", "Scope", language), 190)
            ),
            rows = sessions.map { session ->
                val effectiveStart = maxOf(session.startAtUtc, start)
                val effectiveEnd = minOf(store.effectiveEnd(session, now), end)
                listOf(
                    DateTools.dateTimeString(effectiveStart),
                    if (store.isLocalOpenSession(session)) L10n.text("进行中", "In progress", language) else DateTools.dateTimeString(effectiveEnd),
                    DateTools.formatDuration(Duration.between(effectiveStart, effectiveEnd).seconds.toInt(), language),
                    DateTools.stopActionTitle(session.stopAction, language),
                    DateTools.platformTitle(session.platform),
                    session.deviceName,
                    session.measurementScope
                )
            }
        )
    }

    private fun addTableSection(parent: LinearLayout, title: String, columns: List<UiTableColumn>, rows: List<List<String>>) {
        parent.addView(AppUi.section(
            this,
            title,
            AppUi.table(
                context = this,
                columns = columns,
                rows = rows,
                emptyText = L10n.text("暂无记录", "No records", language)
            )
        ))
    }

    private fun summarySurface(title: String, metrics: List<Pair<String, String>>): LinearLayout =
        AppUi.surface(this).apply {
            addView(TextView(this@ReportActivity).apply {
                text = title
                textSize = 18f
                typeface = Typeface.DEFAULT_BOLD
                setPadding(0, 0, 0, AppUi.dp(this@ReportActivity, 8))
            })
            metrics.forEach { (label, value) ->
                addView(AppUi.keyValueRow(this@ReportActivity, label, value))
            }
        }

    private fun controlSurface(title: String, inputs: List<android.view.View>, actionTitle: String, action: () -> Unit): LinearLayout =
        AppUi.surface(this).apply {
            addView(AppUi.fieldLabel(this@ReportActivity, title))
            inputs.forEach { addView(it) }
            addView(AppUi.buttonRow(
                this@ReportActivity,
                AppUi.button(this@ReportActivity, actionTitle, action)
            ))
        }

    private fun labeledInput(label: String, input: EditText): LinearLayout =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(AppUi.fieldLabel(this@ReportActivity, label))
            addView(input)
        }

    private fun dateEdit(value: String): EditText =
        EditText(this).apply {
            setText(value)
            setSingleLine(true)
            inputType = InputType.TYPE_CLASS_DATETIME
            AppUi.styleTextField(this@ReportActivity, this)
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        }
}
