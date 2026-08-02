package com.timbertrail.screentimeguardian

import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.util.UUID

data class ScreenSession(
    val id: String = UUID.randomUUID().toString(),
    val deviceId: String,
    val deviceName: String,
    val platform: String = "android",
    val measurementScope: String = "android_usage_stats",
    val startAtUtc: Instant,
    val startTimezone: String = ZoneId.systemDefault().id,
    val endAtUtc: Instant? = null,
    val endTimezone: String? = null,
    val durationSeconds: Int = 0,
    val stopAction: String? = null,
    val heartbeatAtUtc: Instant? = null,
    val createdAtUtc: Instant,
    val updatedAtUtc: Instant,
    val revision: Int = 1,
    val syncStatus: String = "local"
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("device_id", deviceId)
        .put("device_name", deviceName)
        .put("platform", platform)
        .put("measurement_scope", measurementScope)
        .put("start_at_utc", startAtUtc.toString())
        .put("start_timezone", startTimezone)
        .put("end_at_utc", endAtUtc?.toString())
        .put("end_timezone", endTimezone)
        .put("duration_seconds", durationSeconds)
        .put("stop_action", stopAction)
        .put("heartbeat_at_utc", heartbeatAtUtc?.toString())
        .put("created_at_utc", createdAtUtc.toString())
        .put("updated_at_utc", updatedAtUtc.toString())
        .put("revision", revision)
        .put("sync_status", syncStatus)

    companion object {
        fun fromJson(json: JSONObject): ScreenSession = ScreenSession(
            id = json.getString("id"),
            deviceId = json.getString("device_id"),
            deviceName = json.optString("device_name"),
            platform = json.optString("platform", "android"),
            measurementScope = json.optString("measurement_scope", "android_usage_stats"),
            startAtUtc = DateTools.parseInstant(json.getString("start_at_utc")),
            startTimezone = json.optString("start_timezone", ZoneId.systemDefault().id),
            endAtUtc = json.optString("end_at_utc").takeIf { it.isNotBlank() && it != "null" }?.let(DateTools::parseInstant),
            endTimezone = json.optString("end_timezone").takeIf { it.isNotBlank() && it != "null" },
            durationSeconds = json.optInt("duration_seconds", 0),
            stopAction = json.optString("stop_action").takeIf { it.isNotBlank() && it != "null" },
            heartbeatAtUtc = json.optString("heartbeat_at_utc").takeIf { it.isNotBlank() && it != "null" }?.let(DateTools::parseInstant),
            createdAtUtc = DateTools.parseInstant(json.getString("created_at_utc")),
            updatedAtUtc = DateTools.parseInstant(json.getString("updated_at_utc")),
            revision = json.optInt("revision", 1),
            syncStatus = json.optString("sync_status", "local")
        )
    }
}
