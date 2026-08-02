package com.timbertrail.screentimeguardian

import android.content.Context
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.nio.charset.StandardCharsets
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.UUID
import java.util.zip.GZIPOutputStream

class SessionStore(private val context: Context) {
    private val openSessionHeartbeatValiditySeconds = 120L
    private val sessionsFile = File(context.filesDir, "sessions.json")
    private val deletedSessionsFile = File(context.filesDir, "deleted_sessions.json")
    private val rankingDirectory = File(context.filesDir, "llm_rankings")
    private val historySessionsDirectory = File(context.filesDir, "history/screen_sessions")
    private val historySummariesDirectory = File(context.filesDir, "history/weekly_summaries")
    private val preferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    private val knownDevicesKey = "known_sync_devices_json"
    private val peerSyncStatesKey = "peer_sync_states_json"

    val deviceId: String = preferences.getString("device_id", null) ?: stableDeviceId().also {
        preferences.edit().putString("device_id", it).apply()
    }

    init {
        cleanupDuplicateScreenTimeSessions()
        refreshHistoricalArchives()
    }

    var language: String
        get() = preferences.getString("language", "zh") ?: "zh"
        set(value) {
            preferences.edit().putString("language", if (value == "en") "en" else "zh").apply()
        }

    var deviceName: String
        get() = preferences.getString("device_name", null)?.takeIf { it.isNotBlank() } ?: defaultDeviceName()
        set(value) {
            preferences.edit().putString("device_name", value.trim().ifBlank { defaultDeviceName() }).apply()
        }

    var postureIntervalMinutes: Int
        get() = preferences.getInt("posture_interval_minutes", 6).coerceIn(1, 1440)
        set(value) {
            preferences.edit().putInt("posture_interval_minutes", value.coerceIn(1, 1440)).apply()
        }

    var postureSwitchEnabled: Boolean
        get() = preferences.getBoolean("posture_switch_enabled", true)
        set(value) {
            preferences.edit().putBoolean("posture_switch_enabled", value).apply()
        }

    var eyeRestIntervalMinutes: Int
        get() = preferences.getInt("eye_rest_interval_minutes", 3).coerceIn(1, 1440)
        set(value) {
            preferences.edit().putInt("eye_rest_interval_minutes", value.coerceIn(1, 1440)).apply()
        }

    var postureRestIntervalMinutes: Int
        get() = derivedPostureRestIntervalMinutes(eyeRestIntervalMinutes)
        set(value) {
            preferences.edit().putInt("posture_rest_interval_minutes", derivedPostureRestIntervalMinutes(eyeRestIntervalMinutes)).apply()
        }

    var plannedDailyMinutes: Int
        get() = preferences.getInt("planned_daily_minutes", 480).coerceIn(1, 1440)
        set(value) {
            preferences.edit().putInt("planned_daily_minutes", value.coerceIn(1, 1440)).apply()
        }

    var meetingMode: Boolean
        get() = preferences.getBoolean("meeting_mode", false)
        set(value) {
            preferences.edit().putBoolean("meeting_mode", value).apply()
        }

    var autoStartEnabled: Boolean
        get() = preferences.getBoolean("auto_start_enabled", true)
        set(value) {
            preferences.edit().putBoolean("auto_start_enabled", value).apply()
        }

    var trackingObject: String
        get() = preferences.getString("tracking_object", "LLM Ranking") ?: "LLM Ranking"
        set(value) {
            preferences.edit().putString("tracking_object", value.ifBlank { "LLM Ranking" }).apply()
        }

    var p2pPairingCode: String
        get() = preferences.getString("p2p_pairing_code", null) ?: newPairingCode().also {
            preferences.edit().putString("p2p_pairing_code", it).apply()
        }
        set(value) {
            val normalized = value.filter { it.isDigit() }.take(6).padEnd(6, '0')
            preferences.edit().putString("p2p_pairing_code", normalized.ifBlank { newPairingCode() }).apply()
        }

    var p2pSyncEnabled: Boolean
        get() = preferences.getBoolean("p2p_sync_enabled", true)
        set(value) {
            preferences.edit().putBoolean("p2p_sync_enabled", value).apply()
        }

    var p2pSyncIntervalMinutes: Int
        get() = preferences.getInt("p2p_sync_interval_minutes", 5).coerceIn(1, 1440)
        set(value) {
            preferences.edit().putInt("p2p_sync_interval_minutes", value.coerceIn(1, 1440)).apply()
        }

    var lastTimeoutPromptAtMillis: Long
        get() = preferences.getLong("last_timeout_prompt_at_millis", 0)
        set(value) {
            preferences.edit().putLong("last_timeout_prompt_at_millis", value).apply()
        }

    var lastTimeoutPromptDate: String
        get() = preferences.getString("last_timeout_prompt_date", "") ?: ""
        set(value) {
            preferences.edit().putString("last_timeout_prompt_date", value).apply()
        }

    val dataDirectory: String
        get() = context.filesDir.absolutePath

    val trustedPeerIds: Set<String>
        get() = preferences.getStringSet("trusted_peer_ids", emptySet())
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            ?: emptySet()

    val rejectedPeerIds: Set<String>
        get() = preferences.getStringSet("rejected_peer_ids", emptySet())
            ?.map { it.trim() }
            ?.filter { it.isNotEmpty() }
            ?.toSet()
            ?: emptySet()

    fun trustStatus(deviceId: String): String {
        val cleaned = deviceId.trim()
        if (trustedPeerIds.any { it.equals(cleaned, ignoreCase = true) }) return "已同意"
        if (rejectedPeerIds.any { it.equals(cleaned, ignoreCase = true) }) return "已拒绝"
        return "待确认"
    }

    fun isTrusted(deviceId: String): Boolean = trustStatus(deviceId) == "已同意"

    fun isRejected(deviceId: String): Boolean = trustStatus(deviceId) == "已拒绝"

    fun trustPeer(deviceId: String) {
        val cleaned = deviceId.trim()
        if (cleaned.isEmpty() || cleaned == this.deviceId) return
        val trusted = trustedPeerIds.toMutableSet().apply { add(cleaned) }
        val rejected = rejectedPeerIds.filterNot { it.equals(cleaned, ignoreCase = true) }.toSet()
        preferences.edit()
            .putStringSet("trusted_peer_ids", trusted)
            .putStringSet("rejected_peer_ids", rejected)
            .apply()
    }

    fun rejectPeer(deviceId: String) {
        val cleaned = deviceId.trim()
        if (cleaned.isEmpty() || cleaned == this.deviceId) return
        val trusted = trustedPeerIds.filterNot { it.equals(cleaned, ignoreCase = true) }.toSet()
        val rejected = rejectedPeerIds.toMutableSet().apply { add(cleaned) }
        preferences.edit()
            .putStringSet("trusted_peer_ids", trusted)
            .putStringSet("rejected_peer_ids", rejected)
            .apply()
    }

    @Synchronized
    fun rememberKnownDevice(
        deviceId: String,
        deviceName: String,
        platform: String,
        appVersion: String = "",
        lastSeenAt: Instant = Instant.now()
    ) {
        val record = KnownSyncDeviceRecord(
            deviceId = deviceId.trim(),
            deviceName = deviceName.trim(),
            platform = normalizedPlatform(platform),
            appVersion = appVersion.trim(),
            lastSeenAt = lastSeenAt
        )
        if (record.deviceId.isEmpty()) return
        val records = knownDeviceRecords().toMutableList()
        val index = records.indexOfFirst { it.deviceId.equals(record.deviceId, ignoreCase = true) }
        if (index >= 0) {
            records[index] = records[index].mergedWith(record)
        } else {
            records.add(record)
        }
        saveKnownDeviceRecords(records)
    }

    @Synchronized
    fun syncDeviceLedger(livePeers: List<P2PPeerInfo> = emptyList(), includeLocal: Boolean = true): List<SyncDeviceLedgerEntry> {
        val entries = linkedMapOf<String, SyncDeviceLedgerEntry>()
        fun key(id: String) = id.trim().lowercase()
        fun upsert(entry: SyncDeviceLedgerEntry) {
            val normalizedKey = key(entry.deviceId)
            if (normalizedKey.isEmpty()) return
            val existing = entries[normalizedKey]
            entries[normalizedKey] = existing?.mergedWith(entry) ?: entry
        }

        if (includeLocal) {
            upsert(
                SyncDeviceLedgerEntry(
                    deviceId = deviceId,
                    deviceName = deviceName,
                    platform = "android",
                    appVersion = APP_VERSION,
                    lastSeenAt = Instant.now(),
                    trustStatus = "本机",
                    lastStatus = "本机",
                    isLocal = true,
                    isLive = true,
                    hasSyncedData = true
                )
            )
        }

        knownDeviceRecords().forEach { record ->
            if (record.deviceId.equals(deviceId, ignoreCase = true) && !includeLocal) return@forEach
            val trust = if (record.deviceId.equals(deviceId, ignoreCase = true)) "本机" else trustStatus(record.deviceId)
            upsert(
                SyncDeviceLedgerEntry(
                    deviceId = record.deviceId,
                    deviceName = record.deviceName.ifBlank { record.deviceId },
                    platform = record.platform.ifBlank { "unknown" },
                    appVersion = record.appVersion,
                    lastSeenAt = record.lastSeenAt,
                    trustStatus = trust,
                    lastStatus = when (trust) {
                        "本机" -> "本机"
                        "已同意" -> "已同意，当前未发现"
                        "已拒绝" -> "已拒绝"
                        else -> "待确认"
                    },
                    isLocal = trust == "本机",
                    isLive = false,
                    hasSyncedData = false
                )
            )
        }

        loadSessions()
            .groupBy { it.deviceId.ifBlank { "${it.platform}:${it.deviceName}" } }
            .forEach { (id, sessions) ->
                val latest = sessions.maxByOrNull { it.updatedAtUtc } ?: return@forEach
                if (id.equals(deviceId, ignoreCase = true) && !includeLocal) return@forEach
                val trust = if (id.equals(deviceId, ignoreCase = true)) "本机" else trustStatus(id)
                upsert(
                    SyncDeviceLedgerEntry(
                        deviceId = id,
                        deviceName = latest.deviceName.ifBlank { id },
                        platform = normalizedPlatform(latest.platform),
                        appVersion = "",
                        lastSeenAt = latest.updatedAtUtc,
                        trustStatus = trust,
                        lastStatus = when (trust) {
                            "本机" -> "本机"
                            "已同意" -> "已同意，当前未发现"
                            "已拒绝" -> "已拒绝"
                            else -> "来自同步数据"
                        },
                        isLocal = trust == "本机",
                        isLive = false,
                        hasSyncedData = true
                    )
                )
            }

        trustedPeerIds.forEach { trustedId ->
            upsert(
                SyncDeviceLedgerEntry(
                    deviceId = trustedId,
                    deviceName = trustedId,
                    platform = "unknown",
                    appVersion = "",
                    lastSeenAt = Instant.EPOCH,
                    trustStatus = "已同意",
                    lastStatus = "已同意，当前未发现",
                    isLocal = false,
                    isLive = false,
                    hasSyncedData = false
                )
            )
        }

        livePeers.forEach { peer ->
            upsert(
                SyncDeviceLedgerEntry(
                    deviceId = peer.deviceId,
                    deviceName = peer.deviceName.ifBlank { peer.deviceId },
                    platform = normalizedPlatform(peer.platform),
                    appVersion = "",
                    lastSeenAt = peer.lastSeenAt,
                    trustStatus = peer.trustStatus,
                    lastStatus = peer.lastStatus,
                    isLocal = false,
                    isLive = true,
                    hasSyncedData = false
                )
            )
        }

        return entries.values
            .sortedWith(
                compareByDescending<SyncDeviceLedgerEntry> { it.isLocal }
                    .thenByDescending { it.isLive }
                    .thenByDescending { it.trustStatus == "已同意" }
                    .thenByDescending { it.hasSyncedData }
                    .thenByDescending { it.lastSeenAt }
                    .thenBy { it.deviceName.lowercase() }
            )
    }

    @Synchronized
    fun loadSessions(): List<ScreenSession> {
        if (!sessionsFile.exists()) return emptyList()
        return try {
            val array = JSONArray(sessionsFile.readText())
            (0 until array.length()).map { ScreenSession.fromJson(array.getJSONObject(it)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    @Synchronized
    fun saveSessions(sessions: List<ScreenSession>) {
        val array = JSONArray()
        sessions.sortedBy { it.startAtUtc }.forEach { array.put(it.toJson()) }
        sessionsFile.writeText(array.toString(2))
    }

    fun loadDeletedSessions(): List<DeletedSession> {
        if (!deletedSessionsFile.exists()) return emptyList()
        return runCatching {
            val array = JSONArray(deletedSessionsFile.readText())
            (0 until array.length()).map { DeletedSession.fromJson(array.getJSONObject(it)) }
        }.getOrDefault(emptyList())
    }

    fun saveDeletedSessions(tombstones: List<DeletedSession>) {
        val array = JSONArray()
        tombstones.sortedByDescending { it.updatedAtUtc }.forEach { array.put(it.toJson()) }
        deletedSessionsFile.writeText(array.toString(2))
    }

    @Synchronized
    fun upsert(session: ScreenSession) {
        if (isDeleted(session)) return
        val sessions = loadSessions().toMutableList()
        val index = sessions.indexOfFirst { it.id == session.id }
        if (index >= 0) sessions[index] = session else sessions.add(session)
        saveSessions(sessions)
    }

    @Synchronized
    fun openSession(): ScreenSession? =
        loadSessions().lastOrNull { it.deviceId == deviceId && it.platform == "android" && it.endAtUtc == null }

    @Synchronized
    fun startSession(now: Instant = Instant.now()): ScreenSession {
        openSession()?.let {
            closeOpenSessionsExcept(it.id, "crash_recovered", now)
            return it
        }
        val session = ScreenSession(
            deviceId = deviceId,
            deviceName = deviceName,
            platform = "android",
            measurementScope = "android_usage_stats",
            startAtUtc = now,
            startTimezone = ZoneId.systemDefault().id,
            endAtUtc = null,
            endTimezone = null,
            durationSeconds = 0,
            stopAction = null,
            heartbeatAtUtc = now,
            createdAtUtc = now,
            updatedAtUtc = now,
            revision = 1,
            syncStatus = "local"
        )
        upsert(session)
        return session
    }

    @Synchronized
    fun closeOpenSessionsExcept(exceptSessionId: String?, stopAction: String, now: Instant = Instant.now()): Int {
        val sessions = loadSessions().toMutableList()
        var changed = 0
        for (index in sessions.indices) {
            val session = sessions[index]
            if (session.deviceId == deviceId &&
                session.platform == "android" &&
                session.endAtUtc == null &&
                !session.id.equals(exceptSessionId, ignoreCase = true)
            ) {
                val end = validatedOpenSessionEnd(session, now)
                sessions[index] = session.copy(
                    endAtUtc = end,
                    endTimezone = ZoneId.systemDefault().id,
                    durationSeconds = durationSeconds(session.startAtUtc, end),
                    stopAction = stopAction,
                    heartbeatAtUtc = end,
                    updatedAtUtc = now,
                    revision = session.revision + 1
                )
                changed++
            }
        }
        if (changed > 0) saveSessions(sessions)
        return changed
    }

    @Synchronized
    fun heartbeatOpenSession(now: Instant = Instant.now()) {
        val session = openSession() ?: return
        upsert(
            session.copy(
                durationSeconds = durationSeconds(session.startAtUtc, now),
                heartbeatAtUtc = now,
                updatedAtUtc = now,
                revision = session.revision + 1
            )
        )
    }

    @Synchronized
    fun endOpenSessions(stopAction: String, now: Instant = Instant.now()): Int {
        val sessions = loadSessions().toMutableList()
        var changed = 0
        for (index in sessions.indices) {
            val session = sessions[index]
            if (session.deviceId == deviceId && session.platform == "android" && session.endAtUtc == null) {
                val end = validatedOpenSessionEnd(session, now)
                sessions[index] = session.copy(
                    endAtUtc = end,
                    endTimezone = ZoneId.systemDefault().id,
                    durationSeconds = durationSeconds(session.startAtUtc, end),
                    stopAction = stopAction,
                    heartbeatAtUtc = end,
                    updatedAtUtc = now,
                    revision = session.revision + 1
                )
                changed++
            }
        }
        if (changed > 0) saveSessions(sessions)
        return changed
    }

    @Synchronized
    fun recoverOpenSessions(now: Instant = Instant.now()): Int {
        val sessions = loadSessions().toMutableList()
        var changed = 0
        for (index in sessions.indices) {
            val session = sessions[index]
            if (session.deviceId == deviceId && session.platform == "android" && session.endAtUtc == null) {
                val end = validatedOpenSessionEnd(session, now)
                sessions[index] = session.copy(
                    endAtUtc = end,
                    endTimezone = ZoneId.systemDefault().id,
                    durationSeconds = durationSeconds(session.startAtUtc, end),
                    stopAction = "crash_recovered",
                    updatedAtUtc = now,
                    revision = session.revision + 1
                )
                changed++
            }
        }
        if (changed > 0) saveSessions(sessions)
        return changed
    }

    @Synchronized
    fun closeExpiredOpenSessions(now: Instant = Instant.now()): Int {
        val sessions = loadSessions().toMutableList()
        var changed = 0
        for (index in sessions.indices) {
            val session = sessions[index]
            if (session.deviceId == deviceId &&
                session.platform == "android" &&
                session.endAtUtc == null &&
                openSessionIsExpired(session, now)
            ) {
                val end = validatedOpenSessionEnd(session, now)
                sessions[index] = session.copy(
                    endAtUtc = end,
                    endTimezone = ZoneId.systemDefault().id,
                    durationSeconds = durationSeconds(session.startAtUtc, end),
                    stopAction = "standby_started",
                    heartbeatAtUtc = end,
                    updatedAtUtc = now,
                    revision = session.revision + 1
                )
                changed++
            }
        }
        if (changed > 0) saveSessions(sessions)
        return changed
    }

    fun makeSyncSnapshot(since: Instant? = null): SyncSnapshot {
        closeExpiredOpenSessions()
        cleanupDuplicateScreenTimeSessions()
        return SyncSnapshot(
            protocolVersion = 1,
            capabilities = P2PTransport.SYNC_CAPABILITIES,
            device = SyncDeviceInfo(
                deviceId = deviceId,
                deviceName = deviceName,
                platform = "android",
                appVersion = APP_VERSION,
                capabilities = P2PTransport.SYNC_CAPABILITIES,
                updatedAtUtc = Instant.now()
            ),
            cursor = SyncCursor(since),
            sessions = loadSessions()
                .filter { since == null || it.updatedAtUtc.isAfter(since) }
                .filter { it.endAtUtc != null },
            deletedSessions = loadDeletedSessions()
                .filter { since == null || it.updatedAtUtc.isAfter(since) }
        )
    }

    @Synchronized
    fun syncSince(deviceId: String): Instant? {
        val cleaned = deviceId.trim()
        if (cleaned.isEmpty()) return null
        return peerSyncStates()
            .firstOrNull { it.deviceId.equals(cleaned, ignoreCase = true) }
            ?.lastSyncAt
            ?.minusSeconds(SYNC_CURSOR_OVERLAP_SECONDS)
    }

    @Synchronized
    fun recordPeerSync(deviceId: String, capabilities: Collection<String>, syncedAt: Instant = Instant.now()) {
        val cleaned = deviceId.trim()
        if (cleaned.isEmpty() || cleaned.equals(this.deviceId, ignoreCase = true)) return
        val records = peerSyncStates().toMutableList()
        val normalizedCapabilities = normalizeCapabilities(capabilities)
        val index = records.indexOfFirst { it.deviceId.equals(cleaned, ignoreCase = true) }
        val record = if (index >= 0) {
            records[index].copy(
                lastSyncAt = syncedAt,
                capabilities = normalizedCapabilities.ifEmpty { records[index].capabilities }
            )
        } else {
            PeerSyncState(
                deviceId = cleaned,
                lastSyncAt = syncedAt,
                capabilities = normalizedCapabilities
            )
        }
        if (index >= 0) {
            records[index] = record
        } else {
            records.add(record)
        }
        savePeerSyncStates(records)
    }

    @Synchronized
    fun mergeSyncSnapshot(snapshot: SyncSnapshot): Int {
        rememberKnownDevice(
            deviceId = snapshot.device.deviceId,
            deviceName = snapshot.device.deviceName,
            platform = snapshot.device.platform,
            appVersion = snapshot.device.appVersion,
            lastSeenAt = snapshot.device.updatedAtUtc
        )
        snapshot.sessions.forEach { session ->
            rememberKnownDevice(
                deviceId = session.deviceId,
                deviceName = session.deviceName,
                platform = session.platform,
                lastSeenAt = session.updatedAtUtc
            )
        }
        var changed = mergeDeletedSessions(snapshot.deletedSessions)
        val sessions = loadSessions().toMutableList()
        snapshot.sessions.forEach { incoming ->
            if (isDeleted(incoming)) return@forEach
            val index = sessions.indexOfFirst { it.id == incoming.id }
            if (index >= 0) {
                if (shouldReplace(sessions[index], incoming)) {
                    sessions[index] = incoming
                    changed++
                }
            } else {
                sessions.add(incoming)
                changed++
            }
        }
        val (cleaned, removedDuplicates) = removeDuplicateScreenTimeSessions(sessions)
        if (changed > 0 || removedDuplicates > 0) saveSessions(cleaned)
        val effectiveChanged = maxOf(0, changed - removedDuplicates)
        if (effectiveChanged > 0) refreshHistoricalArchives()
        return effectiveChanged
    }

    @Synchronized
    fun clearSessionsForDate(date: LocalDate, now: Instant = Instant.now()): Int {
        closeExpiredOpenSessions(now)
        val zone = ZoneId.systemDefault()
        val dayStart = date.atStartOfDay(zone).toInstant()
        val dayEnd = date.plusDays(1).atStartOfDay(zone).toInstant()
        val rangeEnd = if (date == LocalDate.now(zone) && now.isBefore(dayEnd)) now else dayEnd
        if (!rangeEnd.isAfter(dayStart)) return 0

        val tombstones = loadDeletedSessions().toMutableList()
        tombstones.add(
            DeletedSession(
                id = "range-${DateTools.dateString(date)}-$deviceId-${now.epochSecond}",
                startAtUtc = dayStart,
                endAtUtc = rangeEnd,
                deletedByDeviceId = deviceId,
                deletedAtUtc = now,
                updatedAtUtc = now
            )
        )
        saveDeletedSessions(tombstones.sortedByDescending { it.updatedAtUtc })
        val sessions = loadSessions()
        val cleaned = sessions.filterNot { isDeleted(it) }
        saveSessions(cleaned)
        return (sessions.size - cleaned.size).coerceAtLeast(0)
    }

    @Synchronized
    fun cleanupDuplicateScreenTimeSessions(): Int {
        val (cleaned, removed) = removeDuplicateScreenTimeSessions(loadSessions())
        if (removed > 0) saveSessions(cleaned)
        return removed
    }

    private data class ScreenTimeDuplicateKey(
        val deviceId: String,
        val measurementScope: String,
        val startAtUtc: Instant,
        val endAtUtc: Instant,
        val durationSeconds: Int
    )

    private fun removeDuplicateScreenTimeSessions(sessions: List<ScreenSession>): Pair<List<ScreenSession>, Int> {
        val cleaned = mutableListOf<ScreenSession>()
        val indexByKey = mutableMapOf<ScreenTimeDuplicateKey, Int>()
        sessions.forEach { session ->
            val end = session.endAtUtc
            if (!isIOSScreenTimeSession(session) || end == null) {
                cleaned.add(session)
                return@forEach
            }

            val key = ScreenTimeDuplicateKey(
                deviceId = session.deviceId.lowercase(),
                measurementScope = session.measurementScope,
                startAtUtc = session.startAtUtc,
                endAtUtc = end,
                durationSeconds = session.durationSeconds
            )
            val existingIndex = indexByKey[key]
            if (existingIndex != null) {
                cleaned[existingIndex] = preferredScreenTimeSession(cleaned[existingIndex], session)
            } else {
                indexByKey[key] = cleaned.size
                cleaned.add(session)
            }
        }
        return cleaned to (sessions.size - cleaned.size).coerceAtLeast(0)
    }

    private fun isIOSScreenTimeSession(session: ScreenSession): Boolean =
        session.measurementScope.equals("ios_screen_time_selected", ignoreCase = true) ||
            session.id.startsWith("ios-screen-time-", ignoreCase = true)

    private fun preferredScreenTimeSession(left: ScreenSession, right: ScreenSession): ScreenSession {
        val leftPriority = screenTimeActionPriority(left.stopAction)
        val rightPriority = screenTimeActionPriority(right.stopAction)
        if (leftPriority != rightPriority) return if (rightPriority > leftPriority) right else left
        if (left.updatedAtUtc != right.updatedAtUtc) return if (right.updatedAtUtc.isAfter(left.updatedAtUtc)) right else left
        if (left.createdAtUtc != right.createdAtUtc) return if (right.createdAtUtc.isAfter(left.createdAtUtc)) right else left
        return if (right.id < left.id) right else left
    }

    private fun screenTimeActionPriority(action: String?): Int = when (action) {
        "posture_rest_prompt" -> 4
        "eye_rest_prompt" -> 3
        "screen_time_checkpoint" -> 2
        else -> 1
    }

    private fun mergeDeletedSessions(incoming: List<DeletedSession>): Int {
        val tombstones = loadDeletedSessions().toMutableList()
        var changed = 0
        incoming.forEach { tombstone ->
            if (tombstone.id.isBlank()) return@forEach
            val index = tombstones.indexOfFirst { it.id.equals(tombstone.id, ignoreCase = true) }
            if (index >= 0) {
                if (tombstone.updatedAtUtc.isAfter(tombstones[index].updatedAtUtc)) {
                    tombstones[index] = tombstone
                    changed++
                }
            } else {
                tombstones.add(tombstone)
                changed++
            }
        }
        if (changed > 0) saveDeletedSessions(tombstones)

        val sessions = loadSessions()
        val cleaned = sessions.filterNot { isDeleted(it, tombstones) }
        val removed = (sessions.size - cleaned.size).coerceAtLeast(0)
        if (removed > 0) saveSessions(cleaned)
        return changed + removed
    }

    private fun isDeleted(session: ScreenSession): Boolean =
        isDeleted(session, loadDeletedSessions())

    private fun isDeleted(session: ScreenSession, tombstones: List<DeletedSession>): Boolean =
        tombstones.any { tombstoneMatches(it, session) }

    private fun tombstoneMatches(tombstone: DeletedSession, session: ScreenSession): Boolean {
        val sessionId = tombstone.sessionId
        if (!sessionId.isNullOrBlank() && session.id.equals(sessionId, ignoreCase = true)) {
            return true
        }
        val start = tombstone.startAtUtc ?: return false
        val end = tombstone.endAtUtc ?: return false
        if (!end.isAfter(start)) return false
        val sessionEnd = session.endAtUtc ?: validatedOpenSessionEnd(session, Instant.now())
        if (!(sessionEnd.isAfter(start) && session.startAtUtc.isBefore(end))) return false
        return sessionExistedBeforeDeletion(session, tombstone.deletedAtUtc)
    }

    private fun sessionExistedBeforeDeletion(session: ScreenSession, deletedAt: Instant): Boolean {
        if (!session.createdAtUtc.isAfter(deletedAt)) return true
        return session.endAtUtc?.let { !it.isAfter(deletedAt) } ?: false
    }

    private fun validatedOpenSessionEnd(session: ScreenSession, now: Instant): Instant {
        val candidate = session.heartbeatAtUtc ?: session.updatedAtUtc
        if (!candidate.isAfter(session.startAtUtc) || candidate.isAfter(now)) return now
        return if (openSessionIsExpired(session, now)) candidate else now
    }

    private fun openSessionIsExpired(session: ScreenSession, now: Instant): Boolean {
        val candidate = session.heartbeatAtUtc ?: session.updatedAtUtc
        if (!candidate.isAfter(session.startAtUtc) || candidate.isAfter(now)) return false
        return Duration.between(candidate, now).seconds > openSessionHeartbeatValiditySeconds
    }

    fun previousWeekSummary(): WeeklyUsageSummary {
        val thisWeekStartDate = DateTools.currentWeekStartDate()
        val previousWeekStart = thisWeekStartDate.minusDays(7).atStartOfDay(ZoneId.systemDefault()).toInstant()
        val thisWeekStart = thisWeekStartDate.atStartOfDay(ZoneId.systemDefault()).toInstant()
        val platforms = platformUsage(previousWeekStart, thisWeekStart, 7)
        val total = totalUsage(previousWeekStart, thisWeekStart)
        return WeeklyUsageSummary(total, total / 7, platforms)
    }

    fun previousWeekDeviceUsage(): List<DeviceUsageSummary> {
        val thisWeekStartDate = DateTools.currentWeekStartDate()
        val previousWeekStart = thisWeekStartDate.minusDays(7).atStartOfDay(ZoneId.systemDefault()).toInstant()
        val thisWeekStart = thisWeekStartDate.atStartOfDay(ZoneId.systemDefault()).toInstant()
        return deviceUsage(previousWeekStart, thisWeekStart, 7)
    }

    @Synchronized
    fun refreshHistoricalArchives(now: Instant = Instant.now()) {
        val zone = ZoneId.systemDefault()
        val cutoff = DateTools.currentWeekStartDate().minusDays(14).atStartOfDay(zone).toInstant()
        val eligible = loadSessions().filter { session ->
            session.endAtUtc?.isBefore(cutoff) == true
        }
        if (eligible.isEmpty()) return

        historySessionsDirectory.mkdirs()
        historySummariesDirectory.mkdirs()
        eligible
            .groupBy { DateTools.weekId(it.startAtUtc.atZone(zone).toLocalDate()) }
            .forEach { (weekId, weekSessions) ->
                val lines = weekSessions
                    .sortedBy { it.startAtUtc }
                    .joinToString("\n") { it.toJson().toString() } + "\n"
                GZIPOutputStream(FileOutputStream(File(historySessionsDirectory, "screen_sessions_$weekId.jsonl.gz"))).use {
                    it.write(lines.toByteArray(StandardCharsets.UTF_8))
                }

                val firstDate = weekSessions.minByOrNull { it.startAtUtc }?.startAtUtc?.atZone(zone)?.toLocalDate()
                    ?: LocalDate.now(zone)
                val weekStartDate = firstDate.with(java.time.temporal.TemporalAdjusters.previousOrSame(java.time.DayOfWeek.MONDAY))
                val weekStart = weekStartDate.atStartOfDay(zone).toInstant()
                val weekEnd = weekStartDate.plusDays(7).atStartOfDay(zone).toInstant()
                val platforms = platformUsage(weekStart, weekEnd, 7)
                val devices = deviceUsage(weekStart, weekEnd, 7)
                val summary = JSONObject()
                    .put("week_id", weekId)
                    .put("period_start", DateTools.dateString(weekStartDate))
                    .put("period_end", DateTools.dateString(weekStartDate.plusDays(6)))
                    .put("total_seconds", totalUsage(weekStart, weekEnd))
                    .put("source_session_count", weekSessions.size)
                    .put("platforms", JSONArray().apply {
                        platforms.forEach { row ->
                            put(JSONObject()
                                .put("platform", row.platform)
                                .put("total_seconds", row.totalSeconds)
                                .put("average_daily_seconds", row.averageDailySeconds))
                        }
                    })
                    .put("devices", JSONArray().apply {
                        devices.forEach { row ->
                            put(JSONObject()
                                .put("device_id", row.deviceId)
                                .put("device_name", row.deviceName)
                                .put("platform", row.platform)
                                .put("total_seconds", row.totalSeconds)
                                .put("average_daily_seconds", row.averageDailySeconds))
                        }
                    })
                    .put("created_by_device_id", deviceId)
                    .put("created_at_utc", now.toString())
                File(historySummariesDirectory, "weekly_usage_$weekId.json").writeText(summary.toString(2), StandardCharsets.UTF_8)
            }
    }

    fun platformUsage(start: Instant, end: Instant, dayCount: Int): List<PlatformUsageSummary> {
        closeExpiredOpenSessions()
        val divisor = maxOf(1, dayCount)
        return loadSessions()
            .groupBy { normalizedPlatform(it.platform) }
            .map { (platform, sessions) ->
                val seconds = unionSeconds(sessions, start, end)
                PlatformUsageSummary(platform, seconds, seconds / divisor)
            }
            .filter { it.totalSeconds > 0 }
            .sortedWith(compareByDescending<PlatformUsageSummary> { it.totalSeconds }.thenBy { it.platform })
    }

    fun deviceUsage(start: Instant, end: Instant, dayCount: Int): List<DeviceUsageSummary> {
        closeExpiredOpenSessions()
        val divisor = maxOf(1, dayCount)
        return loadSessions()
            .groupBy { session ->
                session.deviceId.ifBlank { "${session.platform.ifBlank { "unknown" }}:${session.deviceName.ifBlank { "unknown" }}" }
            }
            .map { (deviceId, sessions) ->
                val latest = sessions.maxByOrNull { it.updatedAtUtc } ?: sessions.first()
                val seconds = unionSeconds(sessions, start, end)
                DeviceUsageSummary(
                    deviceId = deviceId,
                    deviceName = latest.deviceName.ifBlank { deviceId },
                    platform = normalizedPlatform(latest.platform),
                    totalSeconds = seconds,
                    averageDailySeconds = seconds / divisor
                )
            }
            .filter { it.totalSeconds > 0 }
            .sortedWith(compareByDescending<DeviceUsageSummary> { it.totalSeconds }.thenBy { it.deviceName })
    }

    fun totalUsage(start: Instant, end: Instant): Int {
        closeExpiredOpenSessions()
        return unionSeconds(loadSessions(), start, end)
    }

    fun totalSecondsForDay(date: LocalDate, now: Instant = Instant.now()): Int {
        closeExpiredOpenSessions(now)
        val zone = ZoneId.systemDefault()
        val start = date.atStartOfDay(zone).toInstant()
        val end = date.plusDays(1).atStartOfDay(zone).toInstant()
        return unionSeconds(loadSessions(), start, end, now)
    }

    fun currentDayTotalSeconds(now: Instant = Instant.now()): Int =
        totalSecondsForDay(LocalDate.now(ZoneId.systemDefault()), now)

    fun sessionsForRange(start: Instant, end: Instant): List<ScreenSession> {
        closeExpiredOpenSessions()
        return loadSessions().filter {
            val sessionEnd = effectiveEnd(it, Instant.now())
            sessionEnd.isAfter(start) && it.startAtUtc.isBefore(end)
        }.sortedBy { it.startAtUtc }
    }

    fun sessionsForDay(date: LocalDate): List<ScreenSession> {
        val zone = ZoneId.systemDefault()
        val start = date.atStartOfDay(zone).toInstant()
        val end = date.plusDays(1).atStartOfDay(zone).toInstant()
        return sessionsForRange(start, end)
    }

    fun dailyUsage(startDate: LocalDate, endDate: LocalDate): List<DailyUsageSummary> {
        val days = generateSequence(startDate) { day ->
            if (day.isBefore(endDate)) day.plusDays(1) else null
        }
        return days.map { DailyUsageSummary(it, totalSecondsForDay(it)) }.toList()
    }

    fun saveLLMRankingCache(cache: LLMRankingCache) {
        rankingDirectory.mkdirs()
        File(rankingDirectory, "${cache.weekId}.json").writeText(cache.toJson().toString(2))
    }

    fun loadCurrentLLMRanking(): LLMRankingCache? {
        val file = File(rankingDirectory, "${DateTools.weekId()}.json")
        if (!file.exists()) return null
        return try {
            LLMRankingCache.fromJson(org.json.JSONObject(file.readText()))
        } catch (_: Exception) {
            null
        }
    }

    private fun unionSeconds(
        sessions: List<ScreenSession>,
        start: Instant,
        end: Instant,
        now: Instant = Instant.now()
    ): Int {
        val intervals = sessions.mapNotNull { session ->
            val sessionEnd = effectiveEnd(session, now)
            val overlapStart = maxOf(session.startAtUtc, start)
            val overlapEnd = minOf(sessionEnd, end)
            if (overlapEnd.isAfter(overlapStart)) overlapStart to overlapEnd else null
        }.sortedBy { it.first }
        if (intervals.isEmpty()) return 0

        var total = 0
        var currentStart = intervals.first().first
        var currentEnd = intervals.first().second
        intervals.drop(1).forEach { (intervalStart, intervalEnd) ->
            if (!intervalStart.isAfter(currentEnd)) {
                if (intervalEnd.isAfter(currentEnd)) currentEnd = intervalEnd
            } else {
                total += Duration.between(currentStart, currentEnd).seconds.toInt()
                currentStart = intervalStart
                currentEnd = intervalEnd
            }
        }
        total += Duration.between(currentStart, currentEnd).seconds.toInt()
        return total
    }

    fun effectiveEnd(session: ScreenSession, now: Instant = Instant.now()): Instant {
        session.endAtUtc?.let { return it }
        if (session.deviceId == deviceId && !openSessionIsExpired(session, now)) {
            return now
        }
        return validatedOpenSessionEnd(session, now)
    }

    fun isLocalOpenSession(session: ScreenSession): Boolean =
        session.endAtUtc == null && session.deviceId == deviceId

    private fun stableDeviceId(): String {
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
            ?.takeIf { it.isNotBlank() && it.lowercase() != "9774d56d682e549c" }
        return if (androidId != null) {
            UUID.nameUUIDFromBytes("STG-ANDROID:$androidId".toByteArray(StandardCharsets.UTF_8)).toString()
        } else {
            UUID.randomUUID().toString()
        }
    }

    private fun defaultDeviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?: android.os.Build.MODEL
            ?: "Android device"

    private fun newPairingCode(): String = (100000..999999).random().toString()

    private fun durationSeconds(start: Instant, end: Instant): Int =
        maxOf(0, Duration.between(start, end).seconds.toInt())

    companion object {
        const val APP_VERSION = "1.0.9"
        private const val SYNC_CURSOR_OVERLAP_SECONDS = 10L

        fun derivedPostureRestIntervalMinutes(eyeRestIntervalMinutes: Int): Int =
            (eyeRestIntervalMinutes.coerceAtLeast(1) * 2).coerceIn(1, 1440)
    }

    private fun peerSyncStates(): List<PeerSyncState> {
        val raw = preferences.getString(peerSyncStatesKey, "[]") ?: "[]"
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                PeerSyncState.fromJson(array.optJSONObject(index))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun savePeerSyncStates(records: List<PeerSyncState>) {
        val array = JSONArray()
        records
            .filter { it.deviceId.isNotBlank() }
            .filterNot { it.deviceId.equals(deviceId, ignoreCase = true) }
            .distinctBy { it.deviceId.lowercase() }
            .sortedByDescending { it.lastSyncAt }
            .forEach { array.put(it.toJson()) }
        preferences.edit().putString(peerSyncStatesKey, array.toString()).apply()
    }

    private fun normalizeCapabilities(capabilities: Collection<String>): List<String> =
        capabilities
            .map { it.trim().lowercase() }
            .filter { it.isNotBlank() }
            .distinct()

    private fun knownDeviceRecords(): List<KnownSyncDeviceRecord> {
        val raw = preferences.getString(knownDevicesKey, "[]") ?: "[]"
        return try {
            val array = JSONArray(raw)
            (0 until array.length()).mapNotNull { index ->
                KnownSyncDeviceRecord.fromJson(array.optJSONObject(index))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun saveKnownDeviceRecords(records: List<KnownSyncDeviceRecord>) {
        val array = JSONArray()
        records
            .filter { it.deviceId.isNotBlank() }
            .distinctBy { it.deviceId.lowercase() }
            .sortedByDescending { it.lastSeenAt }
            .forEach { array.put(it.toJson()) }
        preferences.edit().putString(knownDevicesKey, array.toString()).apply()
    }
}

data class KnownSyncDeviceRecord(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val appVersion: String,
    val lastSeenAt: Instant
) {
    fun mergedWith(incoming: KnownSyncDeviceRecord): KnownSyncDeviceRecord {
        val incomingIsNewer = !incoming.lastSeenAt.isBefore(lastSeenAt)
        return KnownSyncDeviceRecord(
            deviceId = deviceId.ifBlank { incoming.deviceId },
            deviceName = if (incoming.deviceName.isNotBlank() && incomingIsNewer) incoming.deviceName else deviceName.ifBlank { incoming.deviceName },
            platform = if (incoming.platform.isNotBlank() && incoming.platform != "unknown" && incomingIsNewer) incoming.platform else platform.ifBlank { incoming.platform },
            appVersion = if (incoming.appVersion.isNotBlank() && incomingIsNewer) incoming.appVersion else appVersion.ifBlank { incoming.appVersion },
            lastSeenAt = maxOf(lastSeenAt, incoming.lastSeenAt)
        )
    }

    fun toJson(): JSONObject = JSONObject()
        .put("device_id", deviceId)
        .put("device_name", deviceName)
        .put("platform", platform)
        .put("app_version", appVersion)
        .put("last_seen_at_utc", lastSeenAt.toString())

    companion object {
        fun fromJson(json: JSONObject?): KnownSyncDeviceRecord? {
            json ?: return null
            val id = json.optString("device_id").trim()
            if (id.isEmpty()) return null
            val seenAt = try {
                DateTools.parseInstant(json.optString("last_seen_at_utc"))
            } catch (_: Exception) {
                Instant.EPOCH
            }
            return KnownSyncDeviceRecord(
                deviceId = id,
                deviceName = json.optString("device_name").trim(),
                platform = normalizedPlatform(json.optString("platform")),
                appVersion = json.optString("app_version").trim(),
                lastSeenAt = seenAt
            )
        }
    }
}

data class PeerSyncState(
    val deviceId: String,
    val lastSyncAt: Instant,
    val capabilities: List<String>
) {
    fun toJson(): JSONObject = JSONObject()
        .put("device_id", deviceId)
        .put("last_sync_at_utc", lastSyncAt.toString())
        .put("capabilities", JSONArray(capabilities))

    companion object {
        fun fromJson(json: JSONObject?): PeerSyncState? {
            json ?: return null
            val id = json.optString("device_id").trim()
            if (id.isEmpty()) return null
            val lastSyncAt = try {
                DateTools.parseInstant(json.optString("last_sync_at_utc"))
            } catch (_: Exception) {
                return null
            }
            val capabilitiesArray = json.optJSONArray("capabilities") ?: JSONArray()
            val capabilities = (0 until capabilitiesArray.length()).mapNotNull { index ->
                capabilitiesArray.optString(index).trim().lowercase().takeIf { it.isNotBlank() }
            }.distinct()
            return PeerSyncState(
                deviceId = id,
                lastSyncAt = lastSyncAt,
                capabilities = capabilities
            )
        }
    }
}

data class SyncDeviceLedgerEntry(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val appVersion: String,
    val lastSeenAt: Instant,
    val trustStatus: String,
    val lastStatus: String,
    val isLocal: Boolean,
    val isLive: Boolean,
    val hasSyncedData: Boolean
) {
    fun mergedWith(incoming: SyncDeviceLedgerEntry): SyncDeviceLedgerEntry {
        val incomingIsNewer = !incoming.lastSeenAt.isBefore(lastSeenAt)
        val betterName = if (incoming.deviceName.isNotBlank() && incoming.deviceName != incoming.deviceId && incomingIsNewer) {
            incoming.deviceName
        } else {
            deviceName.ifBlank { incoming.deviceName }
        }
        val betterPlatform = if (incoming.platform.isNotBlank() && incoming.platform != "unknown" && incomingIsNewer) {
            incoming.platform
        } else {
            platform.ifBlank { incoming.platform }
        }
        return SyncDeviceLedgerEntry(
            deviceId = deviceId.ifBlank { incoming.deviceId },
            deviceName = betterName,
            platform = betterPlatform,
            appVersion = if (incoming.appVersion.isNotBlank() && incomingIsNewer) incoming.appVersion else appVersion.ifBlank { incoming.appVersion },
            lastSeenAt = maxOf(lastSeenAt, incoming.lastSeenAt),
            trustStatus = if (incoming.trustStatus != "待确认" || trustStatus == "待确认") incoming.trustStatus else trustStatus,
            lastStatus = if (incoming.isLive || incoming.lastStatus != "待确认") incoming.lastStatus else lastStatus,
            isLocal = isLocal || incoming.isLocal,
            isLive = isLive || incoming.isLive,
            hasSyncedData = hasSyncedData || incoming.hasSyncedData
        )
    }
}

private fun shouldReplace(existing: ScreenSession, incoming: ScreenSession): Boolean {
    if (incoming.revision != existing.revision) return incoming.revision > existing.revision
    if (incoming.updatedAtUtc != existing.updatedAtUtc) return incoming.updatedAtUtc.isAfter(existing.updatedAtUtc)
    return incoming.toJson().toString() > existing.toJson().toString()
}

fun normalizedPlatform(platform: String): String = when (platform.trim().lowercase()) {
    "macos" -> "macos"
    "ios" -> "ios"
    "ipados" -> "ipados"
    "windows", "win" -> "windows"
    "android" -> "android"
    else -> "unknown"
}

data class WeeklyUsageSummary(
    val totalSeconds: Int,
    val averageDailySeconds: Int,
    val platforms: List<PlatformUsageSummary>
)

data class PlatformUsageSummary(
    val platform: String,
    val totalSeconds: Int,
    val averageDailySeconds: Int
)

data class DeviceUsageSummary(
    val deviceId: String,
    val deviceName: String,
    val platform: String,
    val totalSeconds: Int,
    val averageDailySeconds: Int
)

data class DailyUsageSummary(
    val date: LocalDate,
    val totalSeconds: Int
)
