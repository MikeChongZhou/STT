package com.timbertrail.screentimeguardian

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

data class SyncSnapshot(
    val protocolVersion: Int = 1,
    val capabilities: List<String> = emptyList(),
    val device: SyncDeviceInfo,
    val cursor: SyncCursor? = null,
    val sessions: List<ScreenSession>,
    val deletedSessions: List<DeletedSession> = emptyList()
) {
    fun toJson(): JSONObject {
        val sessionArray = JSONArray()
        sessions.forEach { sessionArray.put(it.toJson()) }
        val deletedSessionArray = JSONArray()
        deletedSessions.forEach { tombstoneArray -> deletedSessionArray.put(tombstoneArray.toJson()) }
        return JSONObject()
            .put("protocol_version", protocolVersion)
            .put("capabilities", JSONArray(capabilities))
            .put("device", device.toJson())
            .put("cursor", cursor?.toJson())
            .put("sessions", sessionArray)
            .put("deleted_sessions", deletedSessionArray)
    }

    companion object {
        fun fromJson(json: JSONObject): SyncSnapshot {
            val deviceJson = json.getJSONObject("device")
            val cursorJson = json.optJSONObject("cursor")
            val sessionArray = json.optJSONArray("sessions") ?: JSONArray()
            val deletedSessionArray = json.optJSONArray("deleted_sessions") ?: JSONArray()
            return SyncSnapshot(
                protocolVersion = json.optInt("protocol_version", 1),
                capabilities = stringList(json.optJSONArray("capabilities")),
                device = SyncDeviceInfo(
                    deviceId = deviceJson.getString("device_id"),
                    deviceName = deviceJson.optString("device_name"),
                    platform = deviceJson.optString("platform", "android"),
                    appVersion = deviceJson.optString("app_version", "V1.0.9"),
                    capabilities = stringList(deviceJson.optJSONArray("capabilities")),
                    updatedAtUtc = DateTools.parseInstant(deviceJson.getString("updated_at_utc"))
                ),
                cursor = cursorJson?.let {
                    SyncCursor(it.optString("since_updated_at_utc").takeIf { value -> value.isNotBlank() && value != "null" }?.let(DateTools::parseInstant))
                },
                sessions = (0 until sessionArray.length()).map { index ->
                    ScreenSession.fromJson(sessionArray.getJSONObject(index))
                },
                deletedSessions = (0 until deletedSessionArray.length()).map { index ->
                    DeletedSession.fromJson(deletedSessionArray.getJSONObject(index))
                }
            )
        }

        private fun stringList(array: JSONArray?): List<String> {
            if (array == null) return emptyList()
            return (0 until array.length()).mapNotNull { index ->
                array.optString(index).trim().lowercase().takeIf { it.isNotBlank() }
            }.distinct()
        }
    }
}

data class DeletedSession(
    val id: String,
    val sessionId: String? = null,
    val deviceId: String? = null,
    val startAtUtc: Instant? = null,
    val endAtUtc: Instant? = null,
    val deletedByDeviceId: String,
    val deletedAtUtc: Instant,
    val updatedAtUtc: Instant
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("session_id", sessionId)
        .put("device_id", deviceId)
        .put("start_at_utc", startAtUtc?.toString())
        .put("end_at_utc", endAtUtc?.toString())
        .put("deleted_by_device_id", deletedByDeviceId)
        .put("deleted_at_utc", deletedAtUtc.toString())
        .put("updated_at_utc", updatedAtUtc.toString())

    companion object {
        fun fromJson(json: JSONObject): DeletedSession = DeletedSession(
            id = json.getString("id"),
            sessionId = json.optString("session_id").takeIf { it.isNotBlank() && it != "null" },
            deviceId = json.optString("device_id").takeIf { it.isNotBlank() && it != "null" },
            startAtUtc = json.optString("start_at_utc").takeIf { it.isNotBlank() && it != "null" }?.let(DateTools::parseInstant),
            endAtUtc = json.optString("end_at_utc").takeIf { it.isNotBlank() && it != "null" }?.let(DateTools::parseInstant),
            deletedByDeviceId = json.getString("deleted_by_device_id"),
            deletedAtUtc = DateTools.parseInstant(json.getString("deleted_at_utc")),
            updatedAtUtc = DateTools.parseInstant(json.getString("updated_at_utc"))
        )
    }
}

data class SyncDeviceInfo(
    val deviceId: String,
    val deviceName: String,
    val platform: String = "android",
    val appVersion: String = "V1.0.9",
    val capabilities: List<String> = emptyList(),
    val updatedAtUtc: Instant = Instant.now()
) {
    fun toJson(): JSONObject = JSONObject()
        .put("device_id", deviceId)
        .put("device_name", deviceName)
        .put("platform", platform)
        .put("app_version", appVersion)
        .put("capabilities", JSONArray(capabilities))
        .put("updated_at_utc", updatedAtUtc.toString())
}

data class SyncCursor(
    val sinceUpdatedAtUtc: Instant?
) {
    fun toJson(): JSONObject = JSONObject()
        .put("since_updated_at_utc", sinceUpdatedAtUtc?.toString())
}
