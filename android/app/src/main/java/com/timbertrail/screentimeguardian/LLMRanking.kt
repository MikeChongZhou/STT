package com.timbertrail.screentimeguardian

import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.time.Instant
import java.time.LocalDate
import java.util.Locale

data class LLMRankingCache(
    val weekId: String,
    val periodStart: String?,
    val periodEnd: String?,
    val source: String,
    val fetchedAtUtc: Instant,
    val rows: List<LLMRankingRow>
) {
    fun toJson(): JSONObject {
        val array = JSONArray()
        rows.forEach { array.put(it.toJson()) }
        return JSONObject()
            .put("week_id", weekId)
            .put("period_start", periodStart)
            .put("period_end", periodEnd)
            .put("source", source)
            .put("fetched_at_utc", fetchedAtUtc.toString())
            .put("rows", array)
    }

    companion object {
        fun fromJson(json: JSONObject): LLMRankingCache {
            val rowsArray = json.optJSONArray("rows") ?: JSONArray()
            return LLMRankingCache(
                weekId = json.optString("week_id", DateTools.weekId()),
                periodStart = json.optString("period_start").takeIf { it.isNotBlank() && it != "null" },
                periodEnd = json.optString("period_end").takeIf { it.isNotBlank() && it != "null" },
                source = json.optString("source", "openrouter.ai"),
                fetchedAtUtc = DateTools.parseInstant(json.optString("fetched_at_utc", Instant.now().toString())),
                rows = (0 until rowsArray.length()).map { LLMRankingRow.fromJson(rowsArray.getJSONObject(it)) }
            )
        }
    }
}

data class LLMRankingRow(
    val rank: Int,
    val llmName: String,
    val promptTokens: Double,
    val outputTokens: Double,
    val weightedAverageInputPrice: Double,
    val weightedAverageOutputPrice: Double,
    val weeklyRevenue: Double
) {
    fun toJson(): JSONObject = JSONObject()
        .put("rank", rank)
        .put("llm_name", llmName)
        .put("prompt_tokens", promptTokens)
        .put("output_tokens", outputTokens)
        .put("weighted_average_input_price", weightedAverageInputPrice)
        .put("weighted_average_output_price", weightedAverageOutputPrice)
        .put("weekly_revenue", weeklyRevenue)

    companion object {
        fun fromJson(json: JSONObject): LLMRankingRow = LLMRankingRow(
            rank = json.optInt("rank", 0),
            llmName = json.optString("llm_name"),
            promptTokens = json.optDouble("prompt_tokens", 0.0),
            outputTokens = json.optDouble("output_tokens", 0.0),
            weightedAverageInputPrice = json.optDouble("weighted_average_input_price", 0.0),
            weightedAverageOutputPrice = json.optDouble("weighted_average_output_price", 0.0),
            weeklyRevenue = json.optDouble("weekly_revenue", 0.0)
        )
    }
}

private data class OpenRouterRankingEntry(
    val permaslug: String,
    val variant: String,
    val promptTokens: Double,
    val outputTokens: Double
)

private data class OpenRouterEffectivePricing(
    val weightedInputPricePerMillion: Double,
    val weightedOutputPricePerMillion: Double
)

class OpenRouterClient {
    fun fetchWeeklyPromptTokenTop20(): LLMRankingCache {
        val entries = fetchRankingEntries()
            .filter { it.permaslug.isNotBlank() && it.promptTokens > 0 }
            .sortedByDescending { it.promptTokens }
            .take(20)

        val rows = entries.mapIndexed { index, entry ->
            val pricing = runCatching { fetchEffectivePricing(entry.permaslug, entry.variant) }
                .getOrDefault(OpenRouterEffectivePricing(0.0, 0.0))
            val revenue =
                entry.promptTokens / 1_000_000.0 * pricing.weightedInputPricePerMillion +
                    entry.outputTokens / 1_000_000.0 * pricing.weightedOutputPricePerMillion
            LLMRankingRow(
                rank = index + 1,
                llmName = entry.permaslug,
                promptTokens = entry.promptTokens,
                outputTokens = entry.outputTokens,
                weightedAverageInputPrice = pricing.weightedInputPricePerMillion,
                weightedAverageOutputPrice = pricing.weightedOutputPricePerMillion,
                weeklyRevenue = revenue
            )
        }

        val weekStart = DateTools.currentWeekStartDate()
        return LLMRankingCache(
            weekId = DateTools.weekId(weekStart),
            periodStart = DateTools.dateString(weekStart),
            periodEnd = DateTools.dateString(weekStart.plusDays(6)),
            source = "openrouter.ai/api/frontend/v1",
            fetchedAtUtc = Instant.now(),
            rows = rows
        )
    }

    private fun fetchRankingEntries(): List<OpenRouterRankingEntry> {
        val json = fetchJson("https://openrouter.ai/api/frontend/v1/rankings/models?view=week")
        val data = json.optJSONArray("data") ?: error("OpenRouter rankings 返回格式缺少 data 数组")
        return (0 until data.length()).mapNotNull { index ->
            val row = data.optJSONObject(index) ?: return@mapNotNull null
            val permaslug = row.optString("model_permaslug")
            if (permaslug.isBlank()) return@mapNotNull null
            OpenRouterRankingEntry(
                permaslug = permaslug,
                variant = row.optString("variant").ifBlank { "standard" },
                promptTokens = row.optFlexibleDouble("total_prompt_tokens"),
                outputTokens = row.optFlexibleDouble("total_completion_tokens")
            )
        }
    }

    private fun fetchEffectivePricing(permaslug: String, variant: String): OpenRouterEffectivePricing {
        val url =
            "https://openrouter.ai/api/frontend/v1/stats/effective-pricing?permaslug=${permaslug.urlEncoded()}&variant=${variant.ifBlank { "standard" }.urlEncoded()}"
        val data = fetchJson(url).optJSONObject("data") ?: return OpenRouterEffectivePricing(0.0, 0.0)
        return OpenRouterEffectivePricing(
            weightedInputPricePerMillion = data.optFlexibleDouble("weightedInputPrice"),
            weightedOutputPricePerMillion = data.optFlexibleDouble("weightedOutputPrice")
        )
    }

    private fun fetchJson(url: String): JSONObject {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 30_000
        connection.readTimeout = 30_000
        connection.requestMethod = "GET"
        connection.setRequestProperty("Accept", "application/json")
        connection.inputStream.bufferedReader().use { reader ->
            return JSONObject(reader.readText())
        }
    }
}

private fun JSONObject.optFlexibleDouble(name: String): Double {
    val value = opt(name) ?: return 0.0
    return when (value) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull() ?: 0.0
        else -> 0.0
    }
}

private fun String.urlEncoded(): String =
    URLEncoder.encode(this, Charsets.UTF_8.name())

fun formatNumber(value: Double): String = String.format(Locale.US, "%,.0f", value)

fun formatPrice(value: Double): String = String.format(Locale.US, "$%,.2f", value)

fun formatWholeCurrency(value: Double): String = String.format(Locale.US, "$%,.0f", value)
