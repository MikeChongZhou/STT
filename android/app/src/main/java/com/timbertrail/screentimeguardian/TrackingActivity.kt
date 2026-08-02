package com.timbertrail.screentimeguardian

import android.app.Activity
import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import java.time.ZoneId

class TrackingActivity : Activity() {
    private lateinit var store: SessionStore
    private lateinit var statusView: TextView
    private lateinit var tableHost: LinearLayout
    private var rows: List<LLMRankingRow> = emptyList()
    private var sortColumn = "prompt"
    private var sortAscending = false
    private var fetching = false
    private val language: String
        get() = store.language

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        store = SessionStore(this)
        buildUi()
        loadCacheOrFetch()
    }

    private fun buildUi() {
        val root = AppUi.pageStack(this)
        root.addView(AppUi.title(this, "${L10n.text("跟踪", "Tracking", language)} - LLM Ranking"))
        root.addView(AppUi.buttonRow(
            this,
            AppUi.button(this, L10n.text("刷新数据", "Refresh", language)) { fetchLatest() },
            AppUi.button(this, L10n.text("关闭", "Close", language)) { finish() }
        ))
        statusView = AppUi.subtitle(this, L10n.text("准备读取 LLM Ranking", "Preparing LLM Ranking", language))
        tableHost = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        root.addView(statusView)
        root.addView(tableHost)
        setContentView(AppUi.page(this, root))
    }

    private fun loadCacheOrFetch() {
        val cache = store.loadCurrentLLMRanking()
        if (cache != null) {
            applyCache(cache)
        } else {
            statusView.text = L10n.text("本周缓存不存在，将尝试获取。", "This week's cache does not exist; fetching now.", language)
            fetchLatest()
        }
    }

    private fun fetchLatest() {
        if (fetching) return
        fetching = true
        statusView.text = L10n.text("正在从 OpenRouter 获取本周 prompt token Top 20...", "Fetching this week's prompt token Top 20 from OpenRouter...", language)
        tableHost.removeAllViews()
        Thread {
            try {
                val cache = OpenRouterClient().fetchWeeklyPromptTokenTop20()
                store.saveLLMRankingCache(cache)
                runOnUiThread { applyCache(cache) }
            } catch (ex: Exception) {
                runOnUiThread {
                    statusView.text = "${L10n.text("OpenRouter 获取失败", "OpenRouter fetch failed", language)}：${ex.message}"
                    fillRows()
                }
            } finally {
                fetching = false
            }
        }.start()
    }

    private fun applyCache(cache: LLMRankingCache) {
        rows = cache.rows
        statusView.text =
            "${L10n.text("来源", "Source", language)}：${cache.source}  ${L10n.text("周", "Week", language)}：${cache.weekId}  ${L10n.text("抓取", "Fetched", language)}：${cache.fetchedAtUtc.atZone(ZoneId.systemDefault()).toLocalDateTime()}"
        fillRows()
    }

    private fun fillRows() {
        val sorted = when (sortColumn) {
            "rank" -> sort(rows) { it.rank }
            "name" -> sort(rows) { it.llmName.lowercase() }
            "output" -> sort(rows) { it.outputTokens }
            "inputPrice" -> sort(rows) { it.weightedAverageInputPrice }
            "outputPrice" -> sort(rows) { it.weightedAverageOutputPrice }
            "revenue" -> sort(rows) { it.weeklyRevenue }
            else -> sort(rows) { it.promptTokens }
        }
        tableHost.removeAllViews()
        tableHost.addView(AppUi.section(
            this,
            L10n.text("本周 Prompt Token Top 20", "This Week's Prompt Token Top 20", language),
            AppUi.table(
                context = this,
                columns = columns(),
                rows = sorted.map {
                    listOf(
                        it.rank.toString(),
                        it.llmName,
                        formatNumber(it.promptTokens),
                        formatNumber(it.outputTokens),
                        formatPrice(it.weightedAverageInputPrice),
                        formatPrice(it.weightedAverageOutputPrice),
                        formatWholeCurrency(it.weeklyRevenue)
                    )
                },
                emptyText = L10n.text("暂无记录", "No records", language),
                sortColumnIndex = columnIndex(sortColumn),
                sortAscending = sortAscending,
                onHeaderClick = { index -> setSortColumn(columnKey(index)) }
            )
        ))
        if (rows.isEmpty() && !fetching) {
            tableHost.addView(TextView(this).apply {
                text = L10n.text("暂无记录", "No records", language)
                gravity = Gravity.CENTER
                setPadding(0, AppUi.dp(this@TrackingActivity, 12), 0, 0)
            })
        }
    }

    private fun setSortColumn(column: String) {
        if (sortColumn == column) {
            sortAscending = !sortAscending
        } else {
            sortColumn = column
            sortAscending = column == "rank" || column == "name"
        }
        fillRows()
    }

    private fun columns(): List<UiTableColumn> =
        listOf(
            UiTableColumn(L10n.text("排名", "Rank", language), 72, Gravity.END or Gravity.CENTER_VERTICAL),
            UiTableColumn(L10n.text("LLM 名字", "LLM Name", language), 230),
            UiTableColumn("Prompt Tokens", 150, Gravity.END or Gravity.CENTER_VERTICAL),
            UiTableColumn("Output Tokens", 150, Gravity.END or Gravity.CENTER_VERTICAL),
            UiTableColumn("Input Price / 1M", 150, Gravity.END or Gravity.CENTER_VERTICAL),
            UiTableColumn("Output Price / 1M", 160, Gravity.END or Gravity.CENTER_VERTICAL),
            UiTableColumn("Weekly Revenue", 150, Gravity.END or Gravity.CENTER_VERTICAL)
        )

    private fun columnKey(index: Int): String =
        when (index) {
            0 -> "rank"
            1 -> "name"
            3 -> "output"
            4 -> "inputPrice"
            5 -> "outputPrice"
            6 -> "revenue"
            else -> "prompt"
        }

    private fun columnIndex(column: String): Int =
        when (column) {
            "rank" -> 0
            "name" -> 1
            "output" -> 3
            "inputPrice" -> 4
            "outputPrice" -> 5
            "revenue" -> 6
            else -> 2
        }

    private fun <T : Comparable<T>> sort(source: List<LLMRankingRow>, selector: (LLMRankingRow) -> T): List<LLMRankingRow> =
        if (sortAscending) {
            source.sortedWith(compareBy(selector).thenBy { it.rank }.thenBy { it.llmName })
        } else {
            source.sortedWith(compareByDescending(selector).thenBy { it.rank }.thenBy { it.llmName })
        }
}
