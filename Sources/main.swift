import AppKit
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import ServiceManagement
import zlib

private let appName = "Screen Time Guardian"
private let appVersion = "V1.0.9"
private let developerName = "TimberTrail"
private let deviceIdKeychainService = "com.timbertrail.screentimeguardian"
private let deviceIdKeychainAccount = "stable_device_id"
private let syncProtocolCapabilities = [
    "delta_sync",
    "gzip",
    "history_compaction"
]
private let syncCursorOverlapSeconds: TimeInterval = 10
private let syncPlainPayloadEncoding = "plain"
private let syncGzipPayloadEncoding = "gzip"

private func normalizedSyncCapabilities(_ values: [String]?) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values ?? [] {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, !seen.contains(cleaned) else { continue }
        seen.insert(cleaned)
        result.append(cleaned)
    }
    return result
}

private func parseSyncCapabilities(_ value: String?) -> [String] {
    normalizedSyncCapabilities(value?.split(separator: ",").map(String.init))
}

private func supportsSyncCapability(_ capabilities: [String]?, _ capability: String) -> Bool {
    normalizedSyncCapabilities(capabilities).contains(capability)
}

private func syncCodecError(_ message: String) -> NSError {
    NSError(domain: "ScreenTimeGuardian.SyncCodec", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func gzipCompressed(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    var status = deflateInit2_(
        &stream,
        Z_DEFAULT_COMPRESSION,
        Z_DEFLATED,
        15 + 16,
        8,
        Z_DEFAULT_STRATEGY,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard status == Z_OK else { throw syncCodecError("gzip 压缩初始化失败") }
    defer { deflateEnd(&stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    try data.withUnsafeBytes { inputRaw in
        guard let input = inputRaw.bindMemory(to: Bytef.self).baseAddress else {
            throw syncCodecError("gzip 输入为空")
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
        stream.avail_in = uInt(data.count)
        repeat {
            status = buffer.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return deflate(&stream, Z_FINISH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 {
                output.append(contentsOf: buffer.prefix(produced))
            }
            if status == Z_STREAM_END {
                break
            }
            guard status == Z_OK else { throw syncCodecError("gzip 压缩失败") }
        } while stream.avail_out == 0
    }
    guard status == Z_STREAM_END else { throw syncCodecError("gzip 压缩未完成") }
    return output
}

private func gzipDecompressed(_ data: Data) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else { throw syncCodecError("gzip 解压初始化失败") }
    defer { inflateEnd(&stream) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    try data.withUnsafeBytes { inputRaw in
        guard let input = inputRaw.bindMemory(to: Bytef.self).baseAddress else {
            throw syncCodecError("gzip 输入为空")
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input)
        stream.avail_in = uInt(data.count)
        repeat {
            status = buffer.withUnsafeMutableBufferPointer { outBuffer in
                stream.next_out = outBuffer.baseAddress
                stream.avail_out = uInt(outBuffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = buffer.count - Int(stream.avail_out)
            if produced > 0 {
                output.append(contentsOf: buffer.prefix(produced))
            }
            if status == Z_STREAM_END {
                break
            }
            guard status == Z_OK else { throw syncCodecError("gzip 解压失败") }
        } while stream.avail_in > 0 || stream.avail_out == 0
    }
    guard status == Z_STREAM_END else { throw syncCodecError("gzip 解压未完成") }
    return output
}

private func localizedText(_ zh: String, _ en: String, language: String) -> String {
    language == "en" ? en : zh
}

private func localizedSyncStatus(_ value: String, language: String) -> String {
    guard language == "en" else { return value }
    var text = value
    let replacements: [(String, String)] = [
        ("P2P 已关闭", "P2P is off"),
        ("P2P Bonjour 状态更新", "P2P Bonjour status updated"),
        ("P2P Bonjour 等待", "P2P Bonjour waiting"),
        ("P2P Bonjour 失败", "P2P Bonjour failed"),
        ("本地网络权限被拒绝，请在系统设置中允许 Screen Time Guardian 访问本地网络", "Local network permission was denied. Allow Screen Time Guardian in System Settings."),
        ("配对码不一致，不能同步", "Pairing code mismatch; cannot sync"),
        ("配对码不一致", "Pairing code mismatch"),
        ("已同意，等待重新发现", "Approved; waiting to rediscover"),
        ("已同意，等待同步", "Approved; waiting to sync"),
        ("已拒绝，未同步", "Rejected; not synced"),
        ("待确认，未同步", "Pending approval; not synced"),
        ("已发现设备，但尚未同意任何同步设备", "Devices found, but no sync device has been approved"),
        ("已发起同步", "Sync started"),
        ("正在同步", "Syncing"),
        ("同步失败", "Sync failed"),
        ("同步完成", "Sync complete"),
        ("发现待确认设备", "Found pending device"),
        ("已拒绝设备尝试同步", "Rejected device attempted to sync"),
        ("P2P 已同步", "P2P synced"),
        ("P2P 已连接，无新记录", "P2P connected; no new records"),
        ("等待重新发现", "Waiting to rediscover"),
        ("暂无发现设备", "No devices found"),
        ("待确认", "Pending approval"),
        ("已同意", "Approved"),
        ("已拒绝", "Rejected")
    ]
    for (zh, en) in replacements {
        text = text.replacingOccurrences(of: zh, with: en)
    }
    text = text.replacingOccurrences(of: "条记录", with: " records")
    text = text.replacingOccurrences(of: "台设备", with: " devices")
    text = text.replacingOccurrences(of: "设备", with: " device")
    return text
}

private func stableAppleDeviceId() -> String {
    if let stored = keychainDeviceId() {
        return stored
    }
    var hostUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var timeout = timespec(tv_sec: 1, tv_nsec: 0)
    let generated: String
    if gethostuuid(&hostUUID, &timeout) == 0 {
        let bytes = withUnsafeBytes(of: hostUUID) { Array($0) }
        generated = bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return UUID().uuidString }
            return NSUUID(uuidBytes: baseAddress).uuidString
        }
    } else {
        generated = UUID().uuidString
    }
    saveKeychainDeviceId(generated)
    return generated
}

private func keychainDeviceId() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: deviceIdKeychainService,
        kSecAttrAccount as String: deviceIdKeychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}

private func saveKeychainDeviceId(_ value: String) {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, let data = cleaned.data(using: .utf8) else { return }
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: deviceIdKeychainService,
        kSecAttrAccount as String: deviceIdKeychainAccount
    ]
    let update: [String: Any] = [kSecValueData as String: data]
    if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess {
        return
    }
    var attributes = query
    attributes[kSecValueData as String] = data
    SecItemAdd(attributes as CFDictionary, nil)
}

private func uuidString(from bytes: [UInt8]) -> String {
    bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return UUID().uuidString }
        return NSUUID(uuidBytes: baseAddress).uuidString
    }
}

enum StopAction: String, Codable {
    case reportOpened = "report_opened"
    case eyeRestPrompt = "eye_rest_prompt"
    case postureRestPrompt = "posture_rest_prompt"
    case screenLocked = "screen_locked"
    case screensaverStarted = "screensaver_started"
    case standbyStarted = "standby_started"
    case shutdownStarted = "shutdown_started"
    case appExit = "app_exit"
    case appBackgrounded = "app_backgrounded"
    case dateRollover = "date_rollover"
    case screenTimeCheckpoint = "screen_time_checkpoint"
    case timeoutPrompt = "timeout_prompt"
    case crashRecovered = "crash_recovered"

    func title(language: String) -> String {
        if language == "en" {
            switch self {
            case .reportOpened: return "Report opened"
            case .eyeRestPrompt: return "Eye rest prompt"
            case .postureRestPrompt: return "Posture switch prompt"
            case .screenLocked: return "Screen locked"
            case .screensaverStarted: return "Screen saver"
            case .standbyStarted: return "Sleep or standby"
            case .shutdownStarted: return "Shutdown"
            case .appExit: return "App exit"
            case .appBackgrounded: return "App backgrounded"
            case .dateRollover: return "Date rollover"
            case .screenTimeCheckpoint: return "Screen Time checkpoint"
            case .timeoutPrompt: return "Plan timeout prompt"
            case .crashRecovered: return "Crash recovered"
            }
        }

        switch self {
        case .reportOpened: return "打开报告"
        case .eyeRestPrompt: return "用眼休息提示"
        case .postureRestPrompt: return "姿势切换提示"
        case .screenLocked: return "锁屏"
        case .screensaverStarted: return "屏保/屏幕关闭"
        case .standbyStarted: return "待机/休眠"
        case .shutdownStarted: return "关机"
        case .appExit: return "退出 App"
        case .appBackgrounded: return "App 后台"
        case .dateRollover: return "跨日切分"
        case .screenTimeCheckpoint: return "屏幕用时记录"
        case .timeoutPrompt: return "超过计划提醒"
        case .crashRecovered: return "异常恢复"
        }
    }
}

enum MeasurementScope: String, Codable {
    case globalExact = "global_exact"
    case androidUsageStats = "android_usage_stats"
    case iosScreenTimeSelected = "ios_screen_time_selected"
    case appForegroundOnly = "app_foreground_only"
    case manual = "manual"
}

struct ScreenSession: Codable, Equatable {
    var id: String
    var deviceId: String
    var deviceName: String
    var platform: String
    var measurementScope: MeasurementScope
    var startAtUtc: Date
    var startTimezone: String
    var endAtUtc: Date?
    var endTimezone: String?
    var durationSeconds: Int
    var stopAction: StopAction?
    var heartbeatAtUtc: Date?
    var createdAtUtc: Date
    var updatedAtUtc: Date
    var revision: Int
    var syncStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case measurementScope = "measurement_scope"
        case startAtUtc = "start_at_utc"
        case startTimezone = "start_timezone"
        case endAtUtc = "end_at_utc"
        case endTimezone = "end_timezone"
        case durationSeconds = "duration_seconds"
        case stopAction = "stop_action"
        case heartbeatAtUtc = "heartbeat_at_utc"
        case createdAtUtc = "created_at_utc"
        case updatedAtUtc = "updated_at_utc"
        case revision
        case syncStatus = "sync_status"
    }
}

struct DailyTotal: Codable {
    var date: String
    var reportTimezone: String
    var deviceId: String?
    var durationSeconds: Int
    var sourceSessionCount: Int
    var updatedAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case date
        case reportTimezone = "report_timezone"
        case deviceId = "device_id"
        case durationSeconds = "duration_seconds"
        case sourceSessionCount = "source_session_count"
        case updatedAtUtc = "updated_at_utc"
    }
}

struct PlatformUsageSummary: Codable {
    var platform: String
    var totalSeconds: Int
    var averageDailySeconds: Int
}

struct DeviceUsageSummary: Codable {
    var deviceId: String
    var deviceName: String
    var platform: String
    var totalSeconds: Int
    var averageDailySeconds: Int
}

struct SyncDeviceInfo: Codable {
    var deviceId: String
    var deviceName: String
    var platform: String
    var appVersion: String
    var capabilities: [String]?
    var updatedAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case appVersion = "app_version"
        case capabilities
        case updatedAtUtc = "updated_at_utc"
    }
}

struct PairedPeerRecord: Codable {
    var deviceId: String
    var deviceName: String
    var platform: String
    var appVersion: String
    var lastSeenAtUtc: Date
    var lastSyncAtUtc: Date?
    var capabilities: [String]?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case appVersion = "app_version"
        case lastSeenAtUtc = "last_seen_at_utc"
        case lastSyncAtUtc = "last_sync_at_utc"
        case capabilities
    }
}

struct PeerRememberResult {
    var removedPeerIds: [String]
    var isTrusted: Bool
}

struct SyncCursor: Codable {
    var sinceUpdatedAtUtc: Date?

    enum CodingKeys: String, CodingKey {
        case sinceUpdatedAtUtc = "since_updated_at_utc"
    }
}

struct DeletedSession: Codable, Equatable {
    var id: String
    var sessionId: String?
    var deviceId: String?
    var startAtUtc: Date?
    var endAtUtc: Date?
    var deletedByDeviceId: String
    var deletedAtUtc: Date
    var updatedAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case deviceId = "device_id"
        case startAtUtc = "start_at_utc"
        case endAtUtc = "end_at_utc"
        case deletedByDeviceId = "deleted_by_device_id"
        case deletedAtUtc = "deleted_at_utc"
        case updatedAtUtc = "updated_at_utc"
    }
}

struct SyncSnapshot: Codable {
    var protocolVersion: Int
    var capabilities: [String]?
    var device: SyncDeviceInfo
    var cursor: SyncCursor?
    var sessions: [ScreenSession]
    var deletedSessions: [DeletedSession]?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case capabilities
        case device
        case cursor
        case sessions
        case deletedSessions = "deleted_sessions"
    }
}

struct AppSettings: Codable {
    var language: String
    var postureIntervalMinutes: Int
    var postureSwitchEnabled: Bool?
    var eyeRestIntervalMinutes: Int?
    var postureRestIntervalMinutes: Int?
    var trackingObject: String
    var dataDirectoryPath: String?
    var p2pSyncEnabled: Bool?
    var p2pPairingCode: String?
    var p2pSyncIntervalMinutes: Int?
    var trustedPeerIds: [String]?
    var rejectedPeerIds: [String]?
    var pairedPeers: [PairedPeerRecord]?
    var deviceId: String
    var deviceName: String
    var meetingMode: Bool
    var autoStartEnabled: Bool
    var plannedDailyMinutes: Int?
    var lastWeeklyPlanMinutes: Int?
    var lastTimeoutPromptAtUtc: Date?
    var lastTimeoutPromptDate: String?

    enum CodingKeys: String, CodingKey {
        case language
        case postureIntervalMinutes = "posture_interval_minutes"
        case postureSwitchEnabled = "posture_switch_enabled"
        case eyeRestIntervalMinutes = "eye_rest_interval_minutes"
        case postureRestIntervalMinutes = "posture_rest_interval_minutes"
        case trackingObject = "tracking_object"
        case dataDirectoryPath = "data_directory"
        case p2pSyncEnabled = "p2p_sync_enabled"
        case p2pPairingCode = "p2p_pairing_code"
        case p2pSyncIntervalMinutes = "p2p_sync_interval_minutes"
        case trustedPeerIds = "trusted_peer_ids"
        case rejectedPeerIds = "rejected_peer_ids"
        case pairedPeers = "paired_peers"
        case deviceId = "device_id"
        case deviceName = "device_name"
        case meetingMode = "meeting_mode"
        case autoStartEnabled = "auto_start_enabled"
        case plannedDailyMinutes = "planned_daily_minutes"
        case lastWeeklyPlanMinutes = "last_weekly_plan_minutes"
        case lastTimeoutPromptAtUtc = "last_timeout_prompt_at_utc"
        case lastTimeoutPromptDate = "last_timeout_prompt_date"
    }

    static func defaults() -> AppSettings {
        let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return AppSettings(
            language: "zh",
            postureIntervalMinutes: 6,
            postureSwitchEnabled: true,
            eyeRestIntervalMinutes: 3,
            postureRestIntervalMinutes: 6,
            trackingObject: "LLM Ranking",
            dataDirectoryPath: nil,
            p2pSyncEnabled: true,
            p2pPairingCode: AppSettings.newPairingCode(),
            p2pSyncIntervalMinutes: 5,
            trustedPeerIds: [],
            rejectedPeerIds: [],
            pairedPeers: [],
            deviceId: stableAppleDeviceId(),
            deviceName: hostName,
            meetingMode: false,
            autoStartEnabled: true,
            plannedDailyMinutes: 480,
            lastWeeklyPlanMinutes: nil,
            lastTimeoutPromptAtUtc: nil,
            lastTimeoutPromptDate: nil
        )
    }

    static func newPairingCode() -> String {
        String(format: "%06d", Int.random(in: 100_000...999_999))
    }

    static func normalizePairingCode(_ value: String?) -> String {
        let digits = String((value ?? "").filter(\.isNumber).prefix(6))
        guard !digits.isEmpty else { return newPairingCode() }
        return digits.padding(toLength: 6, withPad: "0", startingAt: 0)
    }

    mutating func normalizeP2P() {
        if p2pSyncEnabled == nil {
            p2pSyncEnabled = true
        }
        p2pPairingCode = AppSettings.normalizePairingCode(p2pPairingCode)
        p2pSyncIntervalMinutes = min(1440, max(1, p2pSyncIntervalMinutes ?? 5))
        postureSwitchEnabled = postureSwitchEnabled ?? true
        eyeRestIntervalMinutes = min(1440, max(1, eyeRestIntervalMinutes ?? 3))
        postureRestIntervalMinutes = AppSettings.derivedPostureRestIntervalMinutes(from: eyeRestIntervalMinutes ?? 3)
        trustedPeerIds = normalizedPeerIds(trustedPeerIds)
        let trusted = Set((trustedPeerIds ?? []).map { $0.lowercased() })
        rejectedPeerIds = normalizedPeerIds(rejectedPeerIds).filter { !trusted.contains($0.lowercased()) }
        pairedPeers = normalizedPairedPeerRecords(pairedPeers)
    }

    static func derivedPostureRestIntervalMinutes(from eyeRestMinutes: Int) -> Int {
        min(1440, max(1, eyeRestMinutes) * 2)
    }

    private func normalizedPeerIds(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for value in values ?? [] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            normalized.append(trimmed)
        }
        return normalized
    }

    private func normalizedPairedPeerRecords(_ values: [PairedPeerRecord]?) -> [PairedPeerRecord] {
        var byId: [String: PairedPeerRecord] = [:]
        for value in values ?? [] {
            let deviceId = value.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty else { continue }
            let key = deviceId.lowercased()
            let record = PairedPeerRecord(
                deviceId: deviceId,
                deviceName: value.deviceName.trimmingCharacters(in: .whitespacesAndNewlines),
                platform: value.platform.trimmingCharacters(in: .whitespacesAndNewlines),
                appVersion: value.appVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                lastSeenAtUtc: value.lastSeenAtUtc,
                lastSyncAtUtc: value.lastSyncAtUtc,
                capabilities: normalizedSyncCapabilities(value.capabilities)
            )
            if let existing = byId[key], existing.lastSeenAtUtc >= record.lastSeenAtUtc {
                continue
            }
            byId[key] = record
        }
        return byId.values.sorted { $0.lastSeenAtUtc > $1.lastSeenAtUtc }
    }
}

struct WeeklySummary: Codable {
    var weekId: String
    var plannedDailyMinutes: Int
    var previousWeekTotalSeconds: Int
    var previousWeekAverageDailySeconds: Int
    var createdByDeviceId: String
    var createdAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case plannedDailyMinutes = "planned_daily_minutes"
        case previousWeekTotalSeconds = "previous_week_total_seconds"
        case previousWeekAverageDailySeconds = "previous_week_average_daily_seconds"
        case createdByDeviceId = "created_by_device_id"
        case createdAtUtc = "created_at_utc"
    }
}

struct HistoricalWeeklyUsageSummary: Codable {
    var weekId: String
    var periodStart: String
    var periodEnd: String
    var totalSeconds: Int
    var sourceSessionCount: Int
    var platforms: [PlatformUsageSummary]
    var devices: [DeviceUsageSummary]
    var createdByDeviceId: String
    var createdAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalSeconds = "total_seconds"
        case sourceSessionCount = "source_session_count"
        case platforms
        case devices
        case createdByDeviceId = "created_by_device_id"
        case createdAtUtc = "created_at_utc"
    }
}

struct LLMRankingCache: Codable {
    var weekId: String
    var periodStart: String?
    var periodEnd: String?
    var source: String
    var fetchedAtUtc: Date
    var rows: [LLMRankingRow]

    enum CodingKeys: String, CodingKey {
        case weekId = "week_id"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case source
        case fetchedAtUtc = "fetched_at_utc"
        case rows
    }
}

struct LLMRankingRow: Codable {
    var rank: Int
    var llmName: String
    var promptTokens: Double
    var outputTokens: Double
    var weightedAverageInputPrice: Double
    var weightedAverageOutputPrice: Double
    var weeklyRevenue: Double

    enum CodingKeys: String, CodingKey {
        case rank
        case llmName = "llm_name"
        case promptTokens = "prompt_tokens"
        case outputTokens = "output_tokens"
        case weightedAverageInputPrice = "weighted_average_input_price"
        case weightedAverageOutputPrice = "weighted_average_output_price"
        case weeklyRevenue = "weekly_revenue"
    }
}

struct MessageError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct OpenRouterRankingEntry {
    var permaslug: String
    var variant: String
    var promptTokens: Double
    var outputTokens: Double
}

struct OpenRouterEffectivePricing {
    var weightedInputPricePerMillion: Double
    var weightedOutputPricePerMillion: Double
}

final class OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai")!

    func fetchWeeklyPromptTokenTop20() throws -> LLMRankingCache {
        let rankingEntries = try fetchRankingEntries()
            .filter { !$0.permaslug.isEmpty && $0.promptTokens > 0 }
            .sorted { $0.promptTokens > $1.promptTokens }
            .prefix(20)

        var rows: [LLMRankingRow] = []
        var rank = 1
        for entry in rankingEntries {
            let pricing = (try? fetchEffectivePricing(permaslug: entry.permaslug, variant: entry.variant))
                ?? OpenRouterEffectivePricing(weightedInputPricePerMillion: 0, weightedOutputPricePerMillion: 0)
            let weeklyRevenue =
                entry.promptTokens / 1_000_000 * pricing.weightedInputPricePerMillion
                + entry.outputTokens / 1_000_000 * pricing.weightedOutputPricePerMillion
            rows.append(
                LLMRankingRow(
                    rank: rank,
                    llmName: entry.permaslug,
                    promptTokens: entry.promptTokens,
                    outputTokens: entry.outputTokens,
                    weightedAverageInputPrice: pricing.weightedInputPricePerMillion,
                    weightedAverageOutputPrice: pricing.weightedOutputPricePerMillion,
                    weeklyRevenue: weeklyRevenue
                )
            )
            rank += 1
        }

        return LLMRankingCache(
            weekId: DateTools.weekId(Date()),
            periodStart: DateTools.dateString(DateTools.currentWeekStart()),
            periodEnd: DateTools.dateString(Calendar.current.date(byAdding: .day, value: 6, to: DateTools.currentWeekStart()) ?? Date()),
            source: "openrouter",
            fetchedAtUtc: Date(),
            rows: rows
        )
    }

    private func fetchRankingEntries() throws -> [OpenRouterRankingEntry] {
        let url = baseURL.appendingPathComponentPreservingQuery("/api/frontend/v1/rankings/models?view=week")
        let json = try fetchJSON(url: url)
        let entries = try parseRankingEntries(json: json)
        guard !entries.isEmpty else {
            throw MessageError(message: "OpenRouter rankings/models?view=week 没有返回可用数据")
        }
        return entries
    }

    private func fetchEffectivePricing(permaslug: String, variant: String) throws -> OpenRouterEffectivePricing {
        let endpoint = URL(string: "/api/frontend/v1/stats/effective-pricing", relativeTo: baseURL)!.absoluteURL
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "permaslug", value: permaslug),
            URLQueryItem(name: "variant", value: variant.isEmpty ? "standard" : variant)
        ]
        guard let url = components.url else {
            throw MessageError(message: "无法生成 OpenRouter pricing URL")
        }

        let json = try fetchJSON(url: url)
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            throw MessageError(message: "OpenRouter pricing 返回格式缺少 data")
        }

        return OpenRouterEffectivePricing(
            weightedInputPricePerMillion: number(data["weightedInputPrice"]),
            weightedOutputPricePerMillion: number(data["weightedOutputPrice"])
        )
    }

    private func fetchJSON(url: URL) throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenTimeGuardian/1.0.9", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var receivedData: Data?
        var receivedResponse: URLResponse?
        var receivedError: Error?

        URLSession.shared.dataTask(with: request) { data, response, error in
            receivedData = data
            receivedResponse = response
            receivedError = error
            semaphore.signal()
        }.resume()

        semaphore.wait()

        if let receivedError {
            throw receivedError
        }
        if let http = receivedResponse as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw MessageError(message: "OpenRouter 请求失败：HTTP \(http.statusCode)")
        }
        guard let data = receivedData else {
            throw MessageError(message: "OpenRouter 请求没有返回数据")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func parseRankingEntries(json: Any) throws -> [OpenRouterRankingEntry] {
        guard let root = json as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            throw MessageError(message: "OpenRouter rankings 返回格式缺少 data 数组")
        }

        return data.compactMap { row in
            let permaslug = string(row["model_permaslug"])
            if permaslug.isEmpty { return nil }
            return OpenRouterRankingEntry(
                permaslug: permaslug,
                variant: string(row["variant"]).isEmpty ? "standard" : string(row["variant"]),
                promptTokens: number(row["total_prompt_tokens"]),
                outputTokens: number(row["total_completion_tokens"])
            )
        }
    }
}

final class JsonCodec {
    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = parseDate(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(value)")
        }
        return decoder
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let date = plainFormatter.date(from: value) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

final class AppStore {
    private let openSessionHeartbeatValidity: TimeInterval = 120
    let configURL: URL
    let settingsURL: URL
    let identityURL: URL
    private(set) var supportURL: URL
    private(set) var sessionsURL: URL
    private(set) var deletedSessionsURL: URL
    private(set) var dailyTotalsURL: URL
    var settings: AppSettings
    private(set) var sessions: [ScreenSession]
    private(set) var deletedSessions: [DeletedSession]
    private(set) var dailyTotals: [DailyTotal]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let config = base.appendingPathComponent("ScreenTimeGuardian", isDirectory: true)
        let defaultData = Self.defaultDataDirectoryURL()
        configURL = config
        settingsURL = config.appendingPathComponent("settings.json")
        identityURL = config.appendingPathComponent("device_id")
        supportURL = defaultData
        sessionsURL = defaultData.appendingPathComponent("sessions.json")
        deletedSessionsURL = defaultData.appendingPathComponent("deleted_sessions.json")
        dailyTotalsURL = defaultData.appendingPathComponent("daily_totals.json")

        try? FileManager.default.createDirectory(at: configURL, withIntermediateDirectories: true)

        settings = AppSettings.defaults()
        sessions = []
        deletedSessions = []
        dailyTotals = []

        loadSettings()
        configureDataDirectory(normalizedDataDirectoryURL(settings.dataDirectoryPath), migrateFrom: configURL)
        settings.dataDirectoryPath = supportURL.path
        loadSessions()
        loadDeletedSessions()
        loadDailyTotals()
        cleanupDuplicateScreenTimeSessions()
        ensurePersistentDeviceId()
        ensureP2PSettings()
        refreshHistoricalArchives()
    }

    static func defaultDataDirectoryURL() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
    }

    private func normalizedDataDirectoryURL(_ path: String?) -> URL {
        let cleaned = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cleaned.isEmpty {
            return Self.defaultDataDirectoryURL()
        }
        return URL(fileURLWithPath: NSString(string: cleaned).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    private func configureDataDirectory(_ url: URL, migrateFrom oldURL: URL? = nil) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let oldURL, oldURL.standardizedFileURL != url.standardizedFileURL {
            migrateDataFiles(from: oldURL, to: url)
        }
        supportURL = url
        sessionsURL = url.appendingPathComponent("sessions.json")
        deletedSessionsURL = url.appendingPathComponent("deleted_sessions.json")
        dailyTotalsURL = url.appendingPathComponent("daily_totals.json")
    }

    private func migrateDataFiles(from source: URL, to destination: URL) {
        let manager = FileManager.default
        let names = ["sessions.json", "deleted_sessions.json", "daily_totals.json", "weekly_summaries", "tracking", "history"]
        for name in names {
            let sourceURL = source.appendingPathComponent(name)
            let destinationURL = destination.appendingPathComponent(name)
            guard manager.fileExists(atPath: sourceURL.path),
                  !manager.fileExists(atPath: destinationURL.path) else { continue }
            try? manager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    @discardableResult
    func updateDataDirectory(_ path: String) -> Bool {
        let target = normalizedDataDirectoryURL(path)
        let old = supportURL
        settings.dataDirectoryPath = target.path
        guard target.standardizedFileURL != old.standardizedFileURL else {
            saveSettings()
            return false
        }
        configureDataDirectory(target, migrateFrom: old)
        saveSettings()
        saveSessions()
        saveDeletedSessions()
        saveDailyTotals()
        return true
    }

    func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let loaded = try? JsonCodec.decoder().decode(AppSettings.self, from: data) else {
            saveSettings()
            return
        }
        settings = loaded
    }

    private func ensureP2PSettings() {
        settings.normalizeP2P()
        saveSettings()
    }

    private func ensurePersistentDeviceId() {
        if let persisted = try? String(contentsOf: identityURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !persisted.isEmpty {
            settings.deviceId = persisted
            saveKeychainDeviceId(persisted)
        } else {
            let current = settings.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            let deviceId = current.isEmpty ? (keychainDeviceId() ?? stableAppleDeviceId()) : current
            settings.deviceId = deviceId
            saveKeychainDeviceId(deviceId)
            try? deviceId.data(using: .utf8)?.write(to: identityURL, options: .atomic)
        }
    }

    func saveSettings() {
        settings.normalizeP2P()
        guard let data = try? JsonCodec.encoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
        saveKeychainDeviceId(settings.deviceId)
        try? settings.deviceId.data(using: .utf8)?.write(to: identityURL, options: .atomic)
    }

    func trustStatus(for deviceId: String) -> String {
        if settings.trustedPeerIds?.contains(where: { $0.caseInsensitiveCompare(deviceId) == .orderedSame }) == true {
            return "已同意"
        }
        if settings.rejectedPeerIds?.contains(where: { $0.caseInsensitiveCompare(deviceId) == .orderedSame }) == true {
            return "已拒绝"
        }
        return "待确认"
    }

    func trustPeer(_ deviceId: String) {
        let cleaned = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != settings.deviceId else { return }
        settings.rejectedPeerIds = (settings.rejectedPeerIds ?? []).filter { $0.caseInsensitiveCompare(cleaned) != .orderedSame }
        if settings.trustedPeerIds?.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) != true {
            settings.trustedPeerIds = (settings.trustedPeerIds ?? []) + [cleaned]
        }
        saveSettings()
    }

    func rejectPeer(_ deviceId: String) {
        let cleaned = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != settings.deviceId else { return }
        settings.trustedPeerIds = (settings.trustedPeerIds ?? []).filter { $0.caseInsensitiveCompare(cleaned) != .orderedSame }
        if settings.rejectedPeerIds?.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) != true {
            settings.rejectedPeerIds = (settings.rejectedPeerIds ?? []) + [cleaned]
        }
        saveSettings()
    }

    @discardableResult
    func rememberPeer(deviceId: String, deviceName: String, platform: String, appVersion: String, capabilities: [String] = []) -> PeerRememberResult {
        let cleanedId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedId.isEmpty, cleanedId.caseInsensitiveCompare(settings.deviceId) != .orderedSame else {
            return PeerRememberResult(removedPeerIds: [], isTrusted: false)
        }

        let cleanedName = cleanedPeerField(deviceName, fallback: "Unknown device")
        let cleanedPlatform = cleanedPeerField(platform, fallback: "unknown")
        let cleanedVersion = cleanedPeerField(appVersion, fallback: "unknown")
        let currentKey = cleanedId.lowercased()
        let currentCapabilities = normalizedSyncCapabilities(capabilities)
        let existingCurrentRecord = settings.pairedPeers?.first { $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == currentKey }
        var removedPeerIds: [String] = []
        var inheritedTrust = trustStatus(for: cleanedId) == "已同意"
        var inheritedLastSyncAtUtc = existingCurrentRecord?.lastSyncAtUtc
        var inheritedCapabilities = currentCapabilities.isEmpty ? normalizedSyncCapabilities(existingCurrentRecord?.capabilities) : currentCapabilities
        var records: [PairedPeerRecord] = []

        for record in settings.pairedPeers ?? [] {
            let recordId = record.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recordId.isEmpty else { continue }
            if recordId.lowercased() == currentKey {
                continue
            }
            if canAliasPeer(deviceName: cleanedName, platform: cleanedPlatform),
               samePeerIdentity(record, deviceName: cleanedName, platform: cleanedPlatform) {
                if trustStatus(for: recordId) == "已同意" {
                    inheritedTrust = true
                }
                if let lastSyncAtUtc = record.lastSyncAtUtc,
                   inheritedLastSyncAtUtc == nil || lastSyncAtUtc > inheritedLastSyncAtUtc! {
                    inheritedLastSyncAtUtc = lastSyncAtUtc
                }
                if inheritedCapabilities.isEmpty {
                    inheritedCapabilities = normalizedSyncCapabilities(record.capabilities)
                }
                removedPeerIds.append(recordId)
                continue
            }
            records.append(record)
        }

        records.insert(
            PairedPeerRecord(
                deviceId: cleanedId,
                deviceName: cleanedName,
                platform: cleanedPlatform,
                appVersion: cleanedVersion,
                lastSeenAtUtc: Date(),
                lastSyncAtUtc: inheritedLastSyncAtUtc,
                capabilities: inheritedCapabilities
            ),
            at: 0
        )
        settings.pairedPeers = records

        if !removedPeerIds.isEmpty {
            let removed = Set(removedPeerIds.map { $0.lowercased() })
            settings.trustedPeerIds = (settings.trustedPeerIds ?? []).filter { !removed.contains($0.lowercased()) }
            settings.rejectedPeerIds = (settings.rejectedPeerIds ?? []).filter { !removed.contains($0.lowercased()) }
        }
        settings.rejectedPeerIds = (settings.rejectedPeerIds ?? []).filter { $0.caseInsensitiveCompare(cleanedId) != .orderedSame }
        if inheritedTrust,
           settings.trustedPeerIds?.contains(where: { $0.caseInsensitiveCompare(cleanedId) == .orderedSame }) != true {
            settings.trustedPeerIds = (settings.trustedPeerIds ?? []) + [cleanedId]
        }
        saveSettings()
        return PeerRememberResult(removedPeerIds: removedPeerIds, isTrusted: inheritedTrust)
    }

    func syncSince(for deviceId: String) -> Date? {
        let cleaned = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        guard let lastSync = settings.pairedPeers?.first(where: {
            $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cleaned
        })?.lastSyncAtUtc else { return nil }
        return lastSync.addingTimeInterval(-syncCursorOverlapSeconds)
    }

    func recordPeerSync(deviceId: String, capabilities: [String], at syncedAtUtc: Date = Date()) {
        let cleaned = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.caseInsensitiveCompare(settings.deviceId) != .orderedSame else { return }
        var records = settings.pairedPeers ?? []
        let normalizedCapabilities = normalizedSyncCapabilities(capabilities)
        if let index = records.firstIndex(where: { $0.deviceId.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            records[index].lastSyncAtUtc = syncedAtUtc
            records[index].lastSeenAtUtc = max(records[index].lastSeenAtUtc, syncedAtUtc)
            if !normalizedCapabilities.isEmpty {
                records[index].capabilities = normalizedCapabilities
            }
        } else {
            records.insert(
                PairedPeerRecord(
                    deviceId: cleaned,
                    deviceName: "Unknown device",
                    platform: "unknown",
                    appVersion: "unknown",
                    lastSeenAtUtc: syncedAtUtc,
                    lastSyncAtUtc: syncedAtUtc,
                    capabilities: normalizedCapabilities
                ),
                at: 0
            )
        }
        settings.pairedPeers = records
        saveSettings()
    }

    private func cleanedPeerField(_ value: String, fallback: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func canAliasPeer(deviceName: String, platform: String) -> Bool {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let platform = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !name.isEmpty &&
            name != "unknown device" &&
            !platform.isEmpty &&
            platform != "unknown"
    }

    private func samePeerIdentity(_ record: PairedPeerRecord, deviceName: String, platform: String) -> Bool {
        canAliasPeer(deviceName: record.deviceName, platform: record.platform) &&
            record.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(deviceName) == .orderedSame &&
            record.platform.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(platform) == .orderedSame
    }

    func loadSessions() {
        guard let data = try? Data(contentsOf: sessionsURL),
              let loaded = try? JsonCodec.decoder().decode([ScreenSession].self, from: data) else {
            sessions = []
            return
        }
        sessions = loaded
    }

    func saveSessions() {
        guard let data = try? JsonCodec.encoder().encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    func loadDeletedSessions() {
        guard let data = try? Data(contentsOf: deletedSessionsURL),
              let loaded = try? JsonCodec.decoder().decode([DeletedSession].self, from: data) else {
            deletedSessions = []
            return
        }
        deletedSessions = loaded
    }

    func saveDeletedSessions() {
        guard let data = try? JsonCodec.encoder().encode(deletedSessions) else { return }
        try? data.write(to: deletedSessionsURL, options: .atomic)
    }

    func loadDailyTotals() {
        guard let data = try? Data(contentsOf: dailyTotalsURL),
              let loaded = try? JsonCodec.decoder().decode([DailyTotal].self, from: data) else {
            dailyTotals = []
            return
        }
        dailyTotals = loaded
    }

    func saveDailyTotals() {
        guard let data = try? JsonCodec.encoder().encode(dailyTotals) else { return }
        try? data.write(to: dailyTotalsURL, options: .atomic)
    }

    func upsertSession(_ session: ScreenSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startAtUtc < $1.startAtUtc }
        saveSessions()
    }

    func makeSyncSnapshot(since: Date? = nil) -> SyncSnapshot {
        closeExpiredOpenSessions(now: Date())
        cleanupDuplicateScreenTimeSessions()
        let rows = sessions.filter { session in
            guard let since else { return true }
            return session.updatedAtUtc > since
        }.filter { $0.endAtUtc != nil }
        let tombstones = deletedSessions.filter { tombstone in
            guard let since else { return true }
            return tombstone.updatedAtUtc > since
        }
        return SyncSnapshot(
            protocolVersion: 1,
            capabilities: syncProtocolCapabilities,
            device: SyncDeviceInfo(
                deviceId: settings.deviceId,
                deviceName: settings.deviceName,
                platform: "macos",
                appVersion: appVersion,
                capabilities: syncProtocolCapabilities,
                updatedAtUtc: Date()
            ),
            cursor: SyncCursor(sinceUpdatedAtUtc: since),
            sessions: rows,
            deletedSessions: tombstones
        )
    }

    @discardableResult
    func mergeSyncSnapshot(_ snapshot: SyncSnapshot) -> Int {
        let deleted = mergeDeletedSessions(snapshot.deletedSessions ?? [])
        let merged = mergeSessions(snapshot.sessions)
        let changed = deleted + merged
        if changed > 0 {
            refreshHistoricalArchives()
        }
        return changed
    }

    @discardableResult
    func mergeSessions(_ incoming: [ScreenSession]) -> Int {
        var changed = 0
        for session in incoming {
            guard !isDeleted(session) else { continue }
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                if shouldReplace(existing: sessions[index], with: session) {
                    sessions[index] = session
                    changed += 1
                }
            } else {
                sessions.append(session)
                changed += 1
            }
        }

        guard changed > 0 else { return 0 }
        let removedDuplicates = removeDuplicateScreenTimeSessionsInMemory()
        sessions.sort { $0.startAtUtc < $1.startAtUtc }
        saveSessions()
        recomputeDailyTotals()
        return max(0, changed - removedDuplicates)
    }

    @discardableResult
    func mergeDeletedSessions(_ incoming: [DeletedSession]) -> Int {
        var changed = 0
        for tombstone in incoming {
            guard !tombstone.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let index = deletedSessions.firstIndex(where: { $0.id.caseInsensitiveCompare(tombstone.id) == .orderedSame }) {
                if tombstone.updatedAtUtc > deletedSessions[index].updatedAtUtc {
                    deletedSessions[index] = tombstone
                    changed += 1
                }
            } else {
                deletedSessions.append(tombstone)
                changed += 1
            }
        }

        let removed = removeDeletedSessionsInMemory()
        guard changed > 0 || removed > 0 else { return 0 }
        deletedSessions.sort { $0.updatedAtUtc > $1.updatedAtUtc }
        saveDeletedSessions()
        if removed > 0 {
            saveSessions()
            recomputeDailyTotals()
        }
        return changed + removed
    }

    @discardableResult
    func clearSessions(for date: Date, now: Date = Date()) -> Int {
        closeExpiredOpenSessions(now: now)
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let isToday = calendar.isDate(dayStart, inSameDayAs: now)
        let rangeEnd = isToday ? min(now, dayEnd) : dayEnd
        guard rangeEnd > dayStart else { return 0 }

        let tombstone = DeletedSession(
            id: "range-\(DateTools.dateString(dayStart))-\(settings.deviceId)-\(Int(now.timeIntervalSince1970))",
            sessionId: nil,
            deviceId: nil,
            startAtUtc: dayStart,
            endAtUtc: rangeEnd,
            deletedByDeviceId: settings.deviceId,
            deletedAtUtc: now,
            updatedAtUtc: now
        )
        deletedSessions.append(tombstone)
        deletedSessions.sort { $0.updatedAtUtc > $1.updatedAtUtc }
        let removed = removeDeletedSessionsInMemory()
        saveDeletedSessions()
        saveSessions()
        recomputeDailyTotals()
        return removed
    }

    @discardableResult
    func closeExpiredOpenSessions(now: Date = Date()) -> Int {
        var changed = 0
        for index in sessions.indices {
            guard sessions[index].endAtUtc == nil,
                  sessions[index].deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame,
                  openSessionIsExpired(sessions[index], now: now) else { continue }
            let end = effectiveOpenSessionEnd(sessions[index], now: now)
            sessions[index].endAtUtc = end
            sessions[index].endTimezone = TimeZone.current.identifier
            sessions[index].durationSeconds = max(0, Int(end.timeIntervalSince(sessions[index].startAtUtc)))
            sessions[index].stopAction = .standbyStarted
            sessions[index].heartbeatAtUtc = end
            sessions[index].updatedAtUtc = now
            sessions[index].revision += 1
            changed += 1
        }
        guard changed > 0 else { return 0 }
        sessions.sort { $0.startAtUtc < $1.startAtUtc }
        saveSessions()
        recomputeDailyTotals()
        return changed
    }

    @discardableResult
    func cleanupDuplicateScreenTimeSessions() -> Int {
        let removed = removeDuplicateScreenTimeSessionsInMemory()
        guard removed > 0 else { return 0 }
        sessions.sort { $0.startAtUtc < $1.startAtUtc }
        saveSessions()
        recomputeDailyTotals()
        return removed
    }

    private struct ScreenTimeDuplicateKey: Hashable {
        var deviceId: String
        var measurementScope: String
        var startAtUtc: Date
        var endAtUtc: Date
        var durationSeconds: Int
    }

    private func removeDuplicateScreenTimeSessionsInMemory() -> Int {
        let originalCount = sessions.count
        var cleaned: [ScreenSession] = []
        var indexByKey: [ScreenTimeDuplicateKey: Int] = [:]

        for session in sessions {
            guard isIOSScreenTimeSession(session), let end = session.endAtUtc else {
                cleaned.append(session)
                continue
            }

            let key = ScreenTimeDuplicateKey(
                deviceId: session.deviceId.lowercased(),
                measurementScope: session.measurementScope.rawValue,
                startAtUtc: session.startAtUtc,
                endAtUtc: end,
                durationSeconds: session.durationSeconds
            )

            if let existingIndex = indexByKey[key] {
                cleaned[existingIndex] = preferredScreenTimeSession(cleaned[existingIndex], session)
            } else {
                indexByKey[key] = cleaned.count
                cleaned.append(session)
            }
        }

        sessions = cleaned
        return max(0, originalCount - cleaned.count)
    }

    private func isIOSScreenTimeSession(_ session: ScreenSession) -> Bool {
        session.measurementScope == .iosScreenTimeSelected || session.id.hasPrefix("ios-screen-time-")
    }

    private func preferredScreenTimeSession(_ lhs: ScreenSession, _ rhs: ScreenSession) -> ScreenSession {
        let leftPriority = screenTimeActionPriority(lhs.stopAction)
        let rightPriority = screenTimeActionPriority(rhs.stopAction)
        if leftPriority != rightPriority {
            return rightPriority > leftPriority ? rhs : lhs
        }
        if lhs.updatedAtUtc != rhs.updatedAtUtc {
            return rhs.updatedAtUtc > lhs.updatedAtUtc ? rhs : lhs
        }
        if lhs.createdAtUtc != rhs.createdAtUtc {
            return rhs.createdAtUtc > lhs.createdAtUtc ? rhs : lhs
        }
        return rhs.id < lhs.id ? rhs : lhs
    }

    private func screenTimeActionPriority(_ action: StopAction?) -> Int {
        switch action {
        case .postureRestPrompt: return 4
        case .eyeRestPrompt: return 3
        case .screenTimeCheckpoint: return 2
        default: return 1
        }
    }

    func recoverOpenSessions(now: Date = Date()) {
        var changed = false
        for index in sessions.indices {
            guard sessions[index].endAtUtc == nil,
                  sessions[index].deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame else { continue }
            let end = effectiveOpenSessionEnd(sessions[index], now: now)
            sessions[index].endAtUtc = end
            sessions[index].endTimezone = TimeZone.current.identifier
            sessions[index].durationSeconds = max(0, Int(end.timeIntervalSince(sessions[index].startAtUtc)))
            sessions[index].stopAction = .crashRecovered
            sessions[index].updatedAtUtc = now
            sessions[index].revision += 1
            changed = true
        }
        if changed {
            saveSessions()
            recomputeDailyTotals()
        }
    }

    func closeOpenSessionsForCurrentDevice(except exceptSessionId: String? = nil, action: StopAction, now: Date = Date()) {
        var changed = false
        for index in sessions.indices {
            guard sessions[index].endAtUtc == nil,
                  sessions[index].deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame,
                  sessions[index].id.caseInsensitiveCompare(exceptSessionId ?? "") != .orderedSame else { continue }
            let end = effectiveOpenSessionEnd(sessions[index], now: now)
            sessions[index].endAtUtc = end
            sessions[index].endTimezone = TimeZone.current.identifier
            sessions[index].durationSeconds = max(0, Int(end.timeIntervalSince(sessions[index].startAtUtc)))
            sessions[index].stopAction = action
            sessions[index].heartbeatAtUtc = end
            sessions[index].updatedAtUtc = now
            sessions[index].revision += 1
            changed = true
        }
        if changed {
            sessions.sort { $0.startAtUtc < $1.startAtUtc }
            saveSessions()
            recomputeDailyTotals()
        }
    }

    func latestOpenSessionForCurrentDevice() -> ScreenSession? {
        sessions
            .filter { $0.endAtUtc == nil && $0.deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame }
            .sorted { $0.startAtUtc > $1.startAtUtc }
            .first
    }

    func effectiveEnd(for session: ScreenSession, now: Date = Date()) -> Date {
        if let end = session.endAtUtc {
            return end
        }
        if session.deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame,
           !openSessionIsExpired(session, now: now) {
            return now
        }
        return effectiveOpenSessionEnd(session, now: now)
    }

    func isLocalOpenSession(_ session: ScreenSession) -> Bool {
        session.endAtUtc == nil && session.deviceId.caseInsensitiveCompare(settings.deviceId) == .orderedSame
    }

    private func effectiveOpenSessionEnd(_ session: ScreenSession, now: Date) -> Date {
        let candidate = session.heartbeatAtUtc ?? session.updatedAtUtc
        if candidate <= session.startAtUtc || candidate > now {
            return now
        }
        return candidate
    }

    private func openSessionIsExpired(_ session: ScreenSession, now: Date) -> Bool {
        let candidate = session.heartbeatAtUtc ?? session.updatedAtUtc
        guard candidate > session.startAtUtc, candidate <= now else { return false }
        return now.timeIntervalSince(candidate) > openSessionHeartbeatValidity
    }

    private func isDeleted(_ session: ScreenSession) -> Bool {
        deletedSessions.contains { tombstone in
            tombstoneMatches(tombstone, session: session)
        }
    }

    @discardableResult
    private func removeDeletedSessionsInMemory() -> Int {
        let originalCount = sessions.count
        sessions.removeAll { session in
            isDeleted(session)
        }
        return max(0, originalCount - sessions.count)
    }

    private func tombstoneMatches(_ tombstone: DeletedSession, session: ScreenSession) -> Bool {
        if let sessionId = tombstone.sessionId,
           session.id.caseInsensitiveCompare(sessionId) == .orderedSame {
            return true
        }
        guard let start = tombstone.startAtUtc,
              let end = tombstone.endAtUtc,
              end > start else { return false }
        let sessionEnd = session.endAtUtc ?? effectiveOpenSessionEnd(session, now: Date())
        guard sessionEnd > start && session.startAtUtc < end else { return false }
        return sessionExistedBeforeDeletion(session, deletedAt: tombstone.deletedAtUtc)
    }

    private func sessionExistedBeforeDeletion(_ session: ScreenSession, deletedAt: Date) -> Bool {
        if session.createdAtUtc <= deletedAt {
            return true
        }
        if let end = session.endAtUtc, end <= deletedAt {
            return true
        }
        return false
    }

    func recomputeDailyTotals() {
        let calendar = Calendar.current
        var totals: [String: (seconds: Int, count: Int, deviceId: String?)] = [:]

        for session in sessions {
            guard let end = session.endAtUtc, end > session.startAtUtc else { continue }
            let segments = splitSecondsByLocalDate(start: session.startAtUtc, end: end, calendar: calendar)
            for segment in segments {
                let allKey = "\(segment.date)|all"
                let deviceKey = "\(segment.date)|\(session.deviceId)"
                totals[allKey, default: (0, 0, nil)].seconds += segment.seconds
                totals[allKey, default: (0, 0, nil)].count += 1
                totals[deviceKey, default: (0, 0, session.deviceId)].seconds += segment.seconds
                totals[deviceKey, default: (0, 0, session.deviceId)].count += 1
            }
        }

        dailyTotals = totals.map { key, value in
            let date = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            return DailyTotal(
                date: date,
                reportTimezone: TimeZone.current.identifier,
                deviceId: value.deviceId,
                durationSeconds: value.seconds,
                sourceSessionCount: value.count,
                updatedAtUtc: Date()
            )
        }.sorted {
            if $0.date == $1.date {
                return ($0.deviceId ?? "") < ($1.deviceId ?? "")
            }
            return $0.date < $1.date
        }
        saveDailyTotals()
    }

    func totalSeconds(on dateString: String, includeDeviceId: String? = nil) -> Int {
        dailyTotals.first {
            $0.date == dateString && $0.deviceId == includeDeviceId
        }?.durationSeconds ?? 0
    }

    func sessionsForDate(_ date: Date) -> [ScreenSession] {
        closeExpiredOpenSessions(now: Date())
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        return sessions.filter { session in
            let end = effectiveEnd(for: session)
            return session.startAtUtc < dayEnd && end > dayStart
        }.sorted { $0.startAtUtc < $1.startAtUtc }
    }

    func totalSeconds(from start: Date, to end: Date) -> Int {
        closeExpiredOpenSessions(now: Date())
        return unionSeconds(for: sessions, from: start, to: end, now: Date())
    }

    func platformUsageSummaries(from start: Date, to end: Date, dayCount: Int, now: Date = Date()) -> [PlatformUsageSummary] {
        closeExpiredOpenSessions(now: now)
        let divisor = max(1, dayCount)
        let grouped = Dictionary(grouping: sessions) { normalizedPlatform($0.platform) }
        return grouped.map { platform, sessions in
            let seconds = unionSeconds(for: sessions, from: start, to: end, now: now)
            return PlatformUsageSummary(platform: platform, totalSeconds: seconds, averageDailySeconds: seconds / divisor)
        }
        .filter { $0.totalSeconds > 0 }
        .sorted {
            if $0.totalSeconds == $1.totalSeconds {
                return platformTitle($0.platform) < platformTitle($1.platform)
            }
            return $0.totalSeconds > $1.totalSeconds
        }
    }

    func deviceUsageSummaries(from start: Date, to end: Date, dayCount: Int, now: Date = Date()) -> [DeviceUsageSummary] {
        closeExpiredOpenSessions(now: now)
        let divisor = max(1, dayCount)
        let grouped = Dictionary(grouping: sessions) { session in
            session.deviceId.isEmpty ? "\(session.platform):\(session.deviceName)" : session.deviceId
        }
        return grouped.map { deviceId, sessions in
            let first = sessions.first
            let seconds = unionSeconds(for: sessions, from: start, to: end, now: now)
            return DeviceUsageSummary(
                deviceId: deviceId,
                deviceName: first?.deviceName.isEmpty == false ? first!.deviceName : "Unknown device",
                platform: normalizedPlatform(first?.platform ?? "unknown"),
                totalSeconds: seconds,
                averageDailySeconds: seconds / divisor
            )
        }
        .filter { $0.totalSeconds > 0 }
        .sorted {
            if $0.totalSeconds == $1.totalSeconds {
                return $0.deviceName < $1.deviceName
            }
            return $0.totalSeconds > $1.totalSeconds
        }
    }

    func previousWeekUsageSummary(now: Date = Date()) -> (start: Date, end: Date, totalSeconds: Int, averageDailySeconds: Int, platforms: [PlatformUsageSummary]) {
        let calendar = Calendar.current
        let thisWeekStart = DateTools.currentWeekStart(now)
        let previousWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        let platforms = platformUsageSummaries(from: previousWeekStart, to: thisWeekStart, dayCount: 7, now: now)
        let total = totalSecondsIncludingOpen(from: previousWeekStart, to: thisWeekStart, now: now)
        return (previousWeekStart, thisWeekStart, total, total / 7, platforms)
    }

    func totalSecondsForDayIncludingOpen(_ date: Date, now: Date = Date()) -> Int {
        closeExpiredOpenSessions(now: now)
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        return totalSecondsIncludingOpen(from: dayStart, to: dayEnd, now: now)
    }

    func totalSecondsIncludingOpen(from start: Date, to end: Date, now: Date = Date()) -> Int {
        closeExpiredOpenSessions(now: now)
        return unionSeconds(for: sessions, from: start, to: end, now: now)
    }

    private func unionSeconds(for sessions: [ScreenSession], from start: Date, to end: Date, now: Date) -> Int {
        let intervals = sessions.compactMap { session -> (Date, Date)? in
            let sessionEnd = effectiveEnd(for: session, now: now)
            let overlapStart = max(session.startAtUtc, start)
            let overlapEnd = min(sessionEnd, end)
            return overlapEnd > overlapStart ? (overlapStart, overlapEnd) : nil
        }.sorted { $0.0 < $1.0 }

        guard var current = intervals.first else { return 0 }
        var total = 0
        for interval in intervals.dropFirst() {
            if interval.0 <= current.1 {
                if interval.1 > current.1 {
                    current.1 = interval.1
                }
            } else {
                total += Int(current.1.timeIntervalSince(current.0))
                current = interval
            }
        }
        total += Int(current.1.timeIntervalSince(current.0))
        return total
    }

    func trackingCacheURL(for weekId: String) -> URL {
        return supportURL
            .appendingPathComponent("tracking", isDirectory: true)
            .appendingPathComponent("llm-ranking", isDirectory: true)
            .appendingPathComponent("\(weekId).json")
    }

    func loadCurrentLLMRanking() -> Result<LLMRankingCache, MessageError> {
        let weekId = DateTools.weekId(Date())
        let url = trackingCacheURL(for: weekId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(MessageError(message: "本周 OpenRouter LLM Ranking 缓存不存在：\(url.path)"))
        }
        do {
            let data = try Data(contentsOf: url)
            let cache = try JsonCodec.decoder().decode(LLMRankingCache.self, from: data)
            return .success(cache)
        } catch {
            return .failure(MessageError(message: "无法读取 LLM Ranking 缓存：\(error.localizedDescription)"))
        }
    }

    func saveLLMRankingCache(_ cache: LLMRankingCache) throws {
        let url = trackingCacheURL(for: cache.weekId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JsonCodec.encoder().encode(cache)
        try data.write(to: url, options: .atomic)
    }

    func weeklySummaryURL(for weekId: String) -> URL {
        return supportURL
            .appendingPathComponent("weekly_summaries", isDirectory: true)
            .appendingPathComponent("\(weekId).json")
    }

    func saveWeeklySummary(_ summary: WeeklySummary) {
        let url = weeklySummaryURL(for: summary.weekId)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JsonCodec.encoder().encode(summary) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func refreshHistoricalArchives(now: Date = Date()) {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -14, to: DateTools.currentWeekStart(now)) ?? now
        let eligible = sessions.filter { session in
            guard let endAtUtc = session.endAtUtc else { return false }
            return endAtUtc < cutoff
        }
        let groups = Dictionary(grouping: eligible) { DateTools.weekId($0.startAtUtc) }
        guard !groups.isEmpty else { return }

        let historyURL = supportURL.appendingPathComponent("history", isDirectory: true)
        let archiveURL = historyURL.appendingPathComponent("screen_sessions", isDirectory: true)
        let summaryURL = historyURL.appendingPathComponent("weekly_summaries", isDirectory: true)
        try? FileManager.default.createDirectory(at: archiveURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: summaryURL, withIntermediateDirectories: true)

        for (weekId, weekSessions) in groups {
            let lines = weekSessions
                .sorted { $0.startAtUtc < $1.startAtUtc }
                .compactMap { session -> String? in
                    guard let data = try? JsonCodec.encoder(pretty: false).encode(session) else { return nil }
                    return String(data: data, encoding: .utf8)
                }
                .joined(separator: "\n")
            if let data = (lines + "\n").data(using: .utf8),
               let compressed = try? gzipCompressed(data) {
                try? compressed.write(to: archiveURL.appendingPathComponent("screen_sessions_\(weekId).jsonl.gz"), options: .atomic)
            }

            let weekStart = DateTools.currentWeekStart(weekSessions.map(\.startAtUtc).min() ?? now)
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            let summary = HistoricalWeeklyUsageSummary(
                weekId: weekId,
                periodStart: DateTools.dateString(weekStart),
                periodEnd: DateTools.dateString(calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart),
                totalSeconds: totalSecondsIncludingOpen(from: weekStart, to: weekEnd, now: now),
                sourceSessionCount: weekSessions.count,
                platforms: platformUsageSummaries(from: weekStart, to: weekEnd, dayCount: 7, now: now),
                devices: deviceUsageSummaries(from: weekStart, to: weekEnd, dayCount: 7, now: now),
                createdByDeviceId: settings.deviceId,
                createdAtUtc: now
            )
            if let data = try? JsonCodec.encoder().encode(summary) {
                try? data.write(to: summaryURL.appendingPathComponent("weekly_usage_\(weekId).json"), options: .atomic)
            }
        }
    }

    private func shouldReplace(existing: ScreenSession, with incoming: ScreenSession) -> Bool {
        if incoming.revision != existing.revision {
            return incoming.revision > existing.revision
        }
        if incoming.updatedAtUtc != existing.updatedAtUtc {
            return incoming.updatedAtUtc > existing.updatedAtUtc
        }
        return canonicalJSON(incoming) > canonicalJSON(existing)
    }

    private func canonicalJSON(_ session: ScreenSession) -> String {
        guard let data = try? JsonCodec.encoder(pretty: false).encode(session) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct P2PEncryptedEnvelope: Codable {
    var protocolVersion: Int
    var type: String
    var senderDeviceId: String
    var senderDeviceName: String
    var platform: String
    var senderTcpPort: Int?
    var capabilities: [String]?
    var payloadEncoding: String?
    var pairingVerifier: String
    var payload: String
    var sentAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
        case senderDeviceId = "sender_device_id"
        case senderDeviceName = "sender_device_name"
        case platform
        case senderTcpPort = "sender_tcp_port"
        case capabilities
        case payloadEncoding = "payload_encoding"
        case pairingVerifier = "pairing_verifier"
        case payload
        case sentAtUtc = "sent_at_utc"
    }
}

struct P2PDiscoveryBeacon: Codable {
    var protocolVersion: Int
    var deviceId: String
    var deviceName: String
    var platform: String
    var appVersion: String
    var tcpPort: Int
    var pairingVerifier: String
    var capabilities: [String]?
    var seenAtUtc: Date

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case deviceId = "device_id"
        case deviceName = "device_name"
        case platform
        case appVersion = "app_version"
        case tcpPort = "tcp_port"
        case pairingVerifier = "pairing_verifier"
        case capabilities
        case seenAtUtc = "seen_at_utc"
    }
}

struct P2PDiscoveredPeer {
    var deviceId: String
    var deviceName: String
    var platform: String
    var appVersion: String
    var address: String
    var tcpPort: Int
    var lastSeenAt: Date
    var lastSyncAt: Date?
    var status: String
    var trustStatus: String
    var pairingMatched: Bool
    var capabilities: [String]
}

private struct P2PReceiveResult {
    var accepted: Bool
    var senderDeviceId: String?
    var capabilities: [String]
}

final class P2PSyncService {
    private static let serviceType = "_stg-sync._tcp"
    private static let maxFrameBytes = 16 * 1024 * 1024

    private let store: AppStore
    private let queue = DispatchQueue(label: "com.timbertrail.screentimeguardian.p2p")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discoveredEndpoints: [String: NWEndpoint] = [:]
    private var discoveredPeers: [String: P2PDiscoveredPeer] = [:]
    private var lastSyncAttemptByEndpoint: [String: Date] = [:]
    private var syncTimer: DispatchSourceTimer?
    private var tcpPort: Int = 0
    private var retainedConnections: [NWConnection] = []
    private let uiStateLock = NSLock()
    private var statusValue: String = "P2P 未启动"
    private var latestPeersSnapshot: [P2PDiscoveredPeer] = []
    private var pendingUIRefresh = false
    var status: String {
        uiStateLock.lock()
        defer { uiStateLock.unlock() }
        return statusValue
    }
    var onStateChanged: (() -> Void)?

    init(store: AppStore) {
        self.store = store
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.store.settings.p2pSyncEnabled ?? true {
                self.stopLocked()
                self.startLocked()
            } else {
                self.stopLocked()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func startLocked() {
        startListenerLocked()
        startBrowserLocked()
        startTimerLocked()
        setStatus("P2P Bonjour 已开启，等待局域网设备")
    }

    private func stopLocked() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        syncTimer?.cancel()
        syncTimer = nil
        retainedConnections.forEach { $0.cancel() }
        retainedConnections.removeAll()
        discoveredEndpoints.removeAll()
        markDiscoveredPeersWaitingForRediscovery()
        tcpPort = 0
        setStatus("P2P 已关闭")
    }

    private func markDiscoveredPeersWaitingForRediscovery() {
        for (deviceId, var peer) in discoveredPeers {
            guard peer.pairingMatched else { continue }
            let trust = trustStatus(for: deviceId)
            peer.trustStatus = trust
            peer.status = trust == "已同意" ? "已同意，等待重新发现" : trust
            discoveredPeers[deviceId] = peer
        }
    }

    private func startListenerLocked() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: tcpParameters())
            let txt = NWTXTRecord([
                "device_id": store.settings.deviceId,
                "device_name": store.settings.deviceName,
                "platform": "macos",
                "app_version": appVersion,
                "pairing_verifier": pairingVerifier,
                "capabilities": syncProtocolCapabilities.joined(separator: ",")
            ])
            listener.service = NWListener.Service(
                name: serviceName,
                type: Self.serviceType,
                txtRecord: txt
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.retain(connection)
                self?.receiveEncryptedSnapshot(on: connection, shouldReply: true)
                connection.start(queue: self?.queue ?? .global())
            }
            listener.stateUpdateHandler = { [weak self] state in
                if let port = listener.port {
                    self?.tcpPort = Int(port.rawValue)
                }
                self?.setStatus("P2P 监听：\(state)")
            }
            listener.start(queue: queue)
            if let port = listener.port {
                tcpPort = Int(port.rawValue)
            }
            self.listener = listener
        } catch {
            setStatus("P2P 监听启动失败：\(error.localizedDescription)")
        }
    }

    private func startBrowserLocked() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: "local."), using: tcpParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                self.registerBonjour(result: result)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            self?.setStatus(self?.bonjourStateText(state) ?? "P2P Bonjour 状态更新")
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func registerBonjour(result: NWBrowser.Result) {
        guard case let .bonjour(txtRecord) = result.metadata else {
            setStatus("发现 STG Bonjour 服务，正在通过加密握手获取设备信息")
            connectToPeerIfNeeded(result.endpoint, minimumInterval: 30)
            return
        }
        let txt = txtRecord.dictionary
        guard let deviceId = txt["device_id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            setStatus("发现 STG Bonjour 服务，正在通过加密握手获取设备 ID")
            connectToPeerIfNeeded(result.endpoint, minimumInterval: 30)
            return
        }
        guard deviceId != store.settings.deviceId else { return }
        guard !isRejected(deviceId) else { return }
        let pairingMatched = txt["pairing_verifier"] == pairingVerifier
        let deviceName = txt["device_name"] ?? "Unknown device"
        let platform = txt["platform"] ?? "unknown"
        let appVersion = txt["app_version"] ?? "unknown"
        let capabilities = parseSyncCapabilities(txt["capabilities"])
        let rememberResult = pairingMatched
            ? rememberMatchedPeer(deviceId: deviceId, deviceName: deviceName, platform: platform, appVersion: appVersion, capabilities: capabilities)
            : PeerRememberResult(removedPeerIds: [], isTrusted: false)
        removeAliasedPeerIds(rememberResult.removedPeerIds, keeping: deviceId)
        let trust = pairingMatched ? (rememberResult.isTrusted ? "已同意" : trustStatus(for: deviceId)) : "配对码不一致"
        let peer = P2PDiscoveredPeer(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion,
            address: endpointKey(result.endpoint),
            tcpPort: Int(txt["tcp_port"] ?? "") ?? 0,
            lastSeenAt: Date(),
            lastSyncAt: discoveredPeers[deviceId]?.lastSyncAt,
            status: pairingMatched ? trust : "配对码不一致，不能同步",
            trustStatus: trust,
            pairingMatched: pairingMatched,
            capabilities: capabilities
        )
        discoveredEndpoints[deviceId] = result.endpoint
        discoveredPeers[deviceId] = peer
        if !pairingMatched {
            setStatus("发现 STG 设备但配对码不一致：\(peer.deviceName)")
        } else {
            setStatus(trust == "已同意" ? "发现已同意设备：\(peer.deviceName)" : "发现待确认设备：\(peer.deviceName)")
        }
        if pairingMatched && trust == "已同意" {
            connectToPeerIfNeeded(peer)
        }
    }

    private func tcpParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    private func bonjourStateText(_ state: NWBrowser.State) -> String {
        switch state {
        case .ready:
            return "P2P Bonjour 已就绪，等待局域网设备"
        case .setup:
            return "P2P Bonjour 正在启动"
        case .waiting(let error):
            return "P2P Bonjour 等待：\(networkErrorText(error))"
        case .failed(let error):
            return "P2P Bonjour 失败：\(networkErrorText(error))"
        case .cancelled:
            return "P2P Bonjour 已停止"
        @unknown default:
            return "P2P Bonjour 状态未知"
        }
    }

    private func networkErrorText(_ error: NWError) -> String {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("permission") ||
            message.localizedCaseInsensitiveContains("Operation not permitted") {
            return "本地网络权限被拒绝，请在系统设置中允许 Screen Time Guardian 访问本地网络"
        }
        return message
    }

    private func startTimerLocked() {
        guard syncTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let seconds = max(60, (store.settings.p2pSyncIntervalMinutes ?? 5) * 60)
        timer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(seconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for peer in self.discoveredPeers.values where peer.pairingMatched && self.isTrusted(peer.deviceId) {
                self.connectToPeerIfNeeded(peer, minimumInterval: TimeInterval(max(30, seconds - 10)))
            }
        }
        timer.resume()
        syncTimer = timer
    }

    func peersSnapshot() -> [P2PDiscoveredPeer] {
        uiStateLock.lock()
        defer { uiStateLock.unlock() }
        return latestPeersSnapshot
    }

    func approvePeer(_ deviceId: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let peer = self.discoveredPeers[deviceId], !peer.pairingMatched {
                self.setStatus("配对码不一致，不能同意该设备：\(peer.deviceName)")
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.store.trustPeer(deviceId)
                self.queue.async {
                    if var peer = self.discoveredPeers[deviceId] {
                        peer.trustStatus = "已同意"
                        peer.status = "已同意，等待同步"
                        self.discoveredPeers[deviceId] = peer
                        self.connectToPeerIfNeeded(peer, minimumInterval: 0)
                    } else {
                        self.setStatus("已同意设备，等待重新发现")
                    }
                    self.notifyChanged()
                }
            }
        }
    }

    func rejectPeer(_ deviceId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.store.rejectPeer(deviceId)
            self.queue.async {
                if var peer = self.discoveredPeers[deviceId] {
                    peer.trustStatus = "已拒绝"
                    peer.status = "已拒绝"
                    self.discoveredPeers[deviceId] = peer
                }
                self.notifyChanged()
            }
        }
    }

    func syncNow() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.store.settings.p2pSyncEnabled ?? true else {
                self.setStatus("P2P 已关闭")
                return
            }

            let discoveredPeers = Array(self.discoveredPeers.values)
            guard !discoveredPeers.isEmpty else {
                self.setStatus("尚未发现设备，请确认两端配对码一致并在同一局域网")
                return
            }

            let peers = discoveredPeers.filter { $0.pairingMatched && self.isTrusted($0.deviceId) }
            guard !peers.isEmpty else {
                if discoveredPeers.contains(where: { !$0.pairingMatched }) {
                    self.setStatus("已发现 STG 设备，但配对码不一致")
                } else {
                    self.setStatus("已发现设备，但尚未同意任何同步设备")
                }
                return
            }
            for peer in peers {
                self.connectToPeerIfNeeded(peer, minimumInterval: 0)
            }
            self.setStatus("已发起同步：\(peers.count) 台设备")
        }
    }

    private func connectToPeerIfNeeded(_ endpoint: NWEndpoint, peer: P2PDiscoveredPeer? = nil, minimumInterval: TimeInterval = 20) {
        let key = endpointKey(endpoint)
        if let last = lastSyncAttemptByEndpoint[key], Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastSyncAttemptByEndpoint[key] = Date()
        let connection = NWConnection(to: endpoint, using: .tcp)
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.sendEncryptedSnapshot(on: connection, peerDeviceId: peer?.deviceId, peerCapabilities: peer?.capabilities ?? []) {
                    self.receiveEncryptedSnapshot(on: connection, shouldReply: false)
                }
            }
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func connectToPeerIfNeeded(_ peer: P2PDiscoveredPeer, minimumInterval: TimeInterval = 20) {
        if let endpoint = discoveredEndpoints[peer.deviceId] {
            let key = peer.deviceId
            if let last = lastSyncAttemptByEndpoint[key], Date().timeIntervalSince(last) < minimumInterval {
                return
            }
            lastSyncAttemptByEndpoint[key] = Date()
            setPeerStatus(peer.deviceId, "正在同步")
            connectToPeerIfNeeded(endpoint, peer: peer, minimumInterval: 0)
            return
        }

        guard let port = NWEndpoint.Port(rawValue: UInt16(peer.tcpPort)) else { return }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(peer.address), port: port)
        let key = peer.deviceId
        if let last = lastSyncAttemptByEndpoint[key], Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastSyncAttemptByEndpoint[key] = Date()
        setPeerStatus(peer.deviceId, "正在同步")
        let connection = NWConnection(to: endpoint, using: .tcp)
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.sendEncryptedSnapshot(on: connection, peerDeviceId: peer.deviceId, peerCapabilities: peer.capabilities) {
                    self.receiveEncryptedSnapshot(on: connection, shouldReply: false)
                }
            }
            if case .failed(let error) = state {
                self.setPeerStatus(peer.deviceId, "同步失败：\(error.localizedDescription)")
                connection.cancel()
            }
        }
        connection.start(queue: queue)
    }

    private func sendEncryptedSnapshot(
        on connection: NWConnection,
        peerDeviceId: String? = nil,
        peerCapabilities: [String] = [],
        completion: (() -> Void)? = nil
    ) {
        do {
            let since = syncSince(for: peerDeviceId, capabilities: peerCapabilities)
            let snapshot = currentSnapshot(since: since)
            let body = try encryptedEnvelopeData(for: snapshot, peerCapabilities: peerCapabilities)
            let frame = frame(body)
            connection.send(content: frame, completion: .contentProcessed { _ in completion?() })
        } catch {
            setStatus("P2P 加密发送失败：\(error.localizedDescription)")
            connection.cancel()
        }
    }

    private func receiveEncryptedSnapshot(on connection: NWConnection, shouldReply: Bool) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] header, _, _, error in
            guard let self, let connection, error == nil, let header, header.count == 4 else {
                connection?.cancel()
                return
            }
            let length = self.frameLength(header)
            guard length > 0, length <= Self.maxFrameBytes else {
                connection.cancel()
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self, weak connection] body, _, _, error in
                guard let self, let connection, error == nil, let body else {
                    connection?.cancel()
                    return
                }
                let result = self.handleEncryptedEnvelope(body, remoteEndpoint: connection.endpoint)
                if result.accepted && shouldReply {
                    self.sendEncryptedSnapshot(on: connection, peerDeviceId: result.senderDeviceId, peerCapabilities: result.capabilities) {
                        if let senderDeviceId = result.senderDeviceId {
                            self.markSynced(senderDeviceId, capabilities: result.capabilities)
                        }
                        connection.cancel()
                    }
                } else {
                    if result.accepted, let senderDeviceId = result.senderDeviceId {
                        self.markSynced(senderDeviceId, capabilities: result.capabilities)
                    }
                    connection.cancel()
                }
            }
        }
    }

    private func handleEncryptedEnvelope(_ data: Data, remoteEndpoint: NWEndpoint?) -> P2PReceiveResult {
        do {
            let envelope = try JsonCodec.decoder().decode(P2PEncryptedEnvelope.self, from: data)
            let envelopeCapabilities = normalizedSyncCapabilities(envelope.capabilities)
            guard envelope.protocolVersion == 1, envelope.type == "sync_snapshot" else { return P2PReceiveResult(accepted: false, senderDeviceId: nil, capabilities: []) }
            guard envelope.senderDeviceId != store.settings.deviceId else { return P2PReceiveResult(accepted: false, senderDeviceId: nil, capabilities: []) }
            guard !envelope.senderDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return P2PReceiveResult(accepted: false, senderDeviceId: nil, capabilities: []) }
            guard envelope.pairingVerifier == pairingVerifier else {
                registerInboundPeer(from: envelope, remoteEndpoint: remoteEndpoint, pairingMatched: false)
                setStatus("发现 STG 设备但配对码不一致：\(envelope.senderDeviceName)")
                return P2PReceiveResult(accepted: false, senderDeviceId: envelope.senderDeviceId, capabilities: envelopeCapabilities)
            }
            registerInboundPeer(from: envelope, remoteEndpoint: remoteEndpoint)
            guard isTrusted(envelope.senderDeviceId) else {
                let rejected = isRejected(envelope.senderDeviceId)
                setPeerStatus(envelope.senderDeviceId, rejected ? "已拒绝，未同步" : "待确认，未同步")
                setStatus(rejected ? "已拒绝设备尝试同步：\(envelope.senderDeviceName)" : "发现待确认设备：\(envelope.senderDeviceName)")
                return P2PReceiveResult(accepted: false, senderDeviceId: envelope.senderDeviceId, capabilities: envelopeCapabilities)
            }
            let payload = try decryptPayload(envelope.payload, payloadEncoding: envelope.payloadEncoding)
            let snapshot = try JsonCodec.decoder().decode(SyncSnapshot.self, from: payload)
            let changed = merge(snapshot)
            setStatus(changed > 0 ? "P2P 已同步 \(changed) 条记录" : "P2P 已连接，无新记录")
            return P2PReceiveResult(accepted: true, senderDeviceId: envelope.senderDeviceId, capabilities: envelopeCapabilities)
        } catch {
            setStatus("P2P 解密或合并失败：\(error.localizedDescription)")
            return P2PReceiveResult(accepted: false, senderDeviceId: nil, capabilities: [])
        }
    }

    private func encryptedEnvelopeData(for snapshot: SyncSnapshot, peerCapabilities: [String]) throws -> Data {
        let snapshotData = try JsonCodec.encoder(pretty: false).encode(snapshot)
        let useGzip = supportsSyncCapability(peerCapabilities, "gzip")
        let plaintext = useGzip ? try gzipCompressed(snapshotData) : snapshotData
        let sealed = try AES.GCM.seal(plaintext, using: pairingKey)
        guard let combined = sealed.combined else {
            throw MessageError(message: "无法生成加密载荷")
        }
        let envelope = P2PEncryptedEnvelope(
            protocolVersion: 1,
            type: "sync_snapshot",
            senderDeviceId: store.settings.deviceId,
            senderDeviceName: store.settings.deviceName,
            platform: "macos",
            senderTcpPort: tcpPort > 0 ? tcpPort : nil,
            capabilities: syncProtocolCapabilities,
            payloadEncoding: useGzip ? syncGzipPayloadEncoding : syncPlainPayloadEncoding,
            pairingVerifier: pairingVerifier,
            payload: combined.base64EncodedString(),
            sentAtUtc: Date()
        )
        return try JsonCodec.encoder(pretty: false).encode(envelope)
    }

    private func decryptPayload(_ base64Payload: String, payloadEncoding: String?) throws -> Data {
        guard let combined = Data(base64Encoded: base64Payload) else {
            throw MessageError(message: "P2P 载荷不是有效 Base64")
        }
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: pairingKey)
        let encoding = (payloadEncoding ?? syncPlainPayloadEncoding).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch encoding {
        case "", syncPlainPayloadEncoding:
            return plaintext
        case syncGzipPayloadEncoding:
            return try gzipDecompressed(plaintext)
        default:
            throw MessageError(message: "不支持的 P2P 载荷编码：\(encoding)")
        }
    }

    private var serviceName: String {
        let safeName = store.settings.deviceName
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "\(safeName)-\(store.settings.deviceId.prefix(6))"
    }

    private var pairingCode: String {
        AppSettings.normalizePairingCode(store.settings.p2pPairingCode)
    }

    private var pairingKey: SymmetricKey {
        let material = Data("STG-P2P-v1:\(pairingCode)".utf8)
        return SymmetricKey(data: Data(SHA256.hash(data: material)))
    }

    private var pairingVerifier: String {
        let material = Data("STG-P2P-verify:\(pairingCode)".utf8)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func isValid(_ beacon: P2PDiscoveryBeacon) -> Bool {
        beacon.protocolVersion == 1 &&
        beacon.deviceId != store.settings.deviceId &&
        beacon.tcpPort > 0 &&
        beacon.pairingVerifier == pairingVerifier &&
        !isRejected(beacon.deviceId)
    }

    private func trustStatus(for deviceId: String) -> String {
        if Thread.isMainThread {
            return store.trustStatus(for: deviceId)
        }
        return DispatchQueue.main.sync {
            store.trustStatus(for: deviceId)
        }
    }

    private func rememberMatchedPeer(deviceId: String, deviceName: String, platform: String, appVersion: String, capabilities: [String] = []) -> PeerRememberResult {
        if Thread.isMainThread {
            return store.rememberPeer(deviceId: deviceId, deviceName: deviceName, platform: platform, appVersion: appVersion, capabilities: capabilities)
        }
        return DispatchQueue.main.sync {
            store.rememberPeer(deviceId: deviceId, deviceName: deviceName, platform: platform, appVersion: appVersion, capabilities: capabilities)
        }
    }

    private func syncSince(for deviceId: String?, capabilities: [String]) -> Date? {
        guard supportsSyncCapability(capabilities, "delta_sync"),
              let deviceId,
              !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if Thread.isMainThread {
            return store.syncSince(for: deviceId)
        }
        return DispatchQueue.main.sync {
            store.syncSince(for: deviceId)
        }
    }

    private func recordPeerSync(deviceId: String, capabilities: [String]) {
        if Thread.isMainThread {
            store.recordPeerSync(deviceId: deviceId, capabilities: capabilities)
        } else {
            DispatchQueue.main.sync {
                store.recordPeerSync(deviceId: deviceId, capabilities: capabilities)
            }
        }
    }

    private func removeAliasedPeerIds(_ deviceIds: [String], keeping currentDeviceId: String) {
        for deviceId in deviceIds where deviceId.caseInsensitiveCompare(currentDeviceId) != .orderedSame {
            discoveredPeers.removeValue(forKey: deviceId)
            discoveredEndpoints.removeValue(forKey: deviceId)
            lastSyncAttemptByEndpoint.removeValue(forKey: deviceId)
        }
    }

    private func isTrusted(_ deviceId: String) -> Bool {
        trustStatus(for: deviceId) == "已同意"
    }

    private func isRejected(_ deviceId: String) -> Bool {
        trustStatus(for: deviceId) == "已拒绝"
    }

    private func setPeerStatus(_ deviceId: String, _ value: String) {
        if var peer = discoveredPeers[deviceId] {
            peer.status = value
            discoveredPeers[deviceId] = peer
            notifyChanged()
        }
    }

    private func registerInboundPeer(from envelope: P2PEncryptedEnvelope, remoteEndpoint: NWEndpoint?, pairingMatched: Bool = true) {
        let deviceId = envelope.senderDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty else { return }
        let existing = discoveredPeers[deviceId]
        let deviceName = envelope.senderDeviceName.isEmpty ? (existing?.deviceName ?? "Unknown device") : envelope.senderDeviceName
        let platform = envelope.platform.isEmpty ? (existing?.platform ?? "unknown") : envelope.platform
        let appVersion = existing?.appVersion ?? "unknown"
        let capabilities = normalizedSyncCapabilities(envelope.capabilities)
        let rememberResult = pairingMatched
            ? rememberMatchedPeer(deviceId: deviceId, deviceName: deviceName, platform: platform, appVersion: appVersion, capabilities: capabilities)
            : PeerRememberResult(removedPeerIds: [], isTrusted: false)
        removeAliasedPeerIds(rememberResult.removedPeerIds, keeping: deviceId)
        let trust = pairingMatched ? (rememberResult.isTrusted ? "已同意" : trustStatus(for: deviceId)) : "配对码不一致"
        let host = host(from: remoteEndpoint)
        let port = envelope.senderTcpPort ?? existing?.tcpPort ?? 0
        if discoveredEndpoints[deviceId] == nil,
           let host,
           (1...65_535).contains(port),
           let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) {
            discoveredEndpoints[deviceId] = .hostPort(host: host, port: endpointPort)
        }
        let peer = P2PDiscoveredPeer(
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform,
            appVersion: appVersion,
            address: host.map { "\($0)" } ?? existing?.address ?? "入站连接",
            tcpPort: port,
            lastSeenAt: Date(),
            lastSyncAt: existing?.lastSyncAt,
            status: pairingMatched ? (trust == "已同意" ? (existing?.status ?? "已同意，等待同步") : trust) : "配对码不一致，不能同步",
            trustStatus: trust,
            pairingMatched: pairingMatched,
            capabilities: capabilities.isEmpty ? (existing?.capabilities ?? []) : capabilities
        )
        discoveredPeers[deviceId] = peer
        notifyChanged()
    }

    private func markSynced(_ deviceId: String, capabilities: [String]) {
        recordPeerSync(deviceId: deviceId, capabilities: capabilities)
        if var peer = discoveredPeers[deviceId] {
            peer.lastSyncAt = Date()
            peer.status = "同步完成"
            if !capabilities.isEmpty {
                peer.capabilities = normalizedSyncCapabilities(capabilities)
            }
            discoveredPeers[deviceId] = peer
            notifyChanged()
        }
    }

    private func setStatus(_ value: String) {
        cacheUIState(status: value)
        notifyChanged()
    }

    private func notifyChanged() {
        cacheUIState()
        guard !pendingUIRefresh else { return }
        pendingUIRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChanged?()
            self.queue.async { [weak self] in
                self?.pendingUIRefresh = false
            }
        }
    }

    private func cacheUIState(status: String? = nil) {
        let peers = sortedPeers()
        uiStateLock.lock()
        if let status {
            statusValue = status
        }
        latestPeersSnapshot = peers
        uiStateLock.unlock()
    }

    private func sortedPeers() -> [P2PDiscoveredPeer] {
        discoveredPeers.values.sorted {
            if $0.lastSeenAt == $1.lastSeenAt {
                return $0.deviceName < $1.deviceName
            }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }

    private func currentSnapshot(since: Date? = nil) -> SyncSnapshot {
        if Thread.isMainThread {
            return store.makeSyncSnapshot(since: since)
        }
        return DispatchQueue.main.sync {
            store.makeSyncSnapshot(since: since)
        }
    }

    private func merge(_ snapshot: SyncSnapshot) -> Int {
        if Thread.isMainThread {
            return store.mergeSyncSnapshot(snapshot)
        }
        return DispatchQueue.main.sync {
            store.mergeSyncSnapshot(snapshot)
        }
    }

    private func frame(_ body: Data) -> Data {
        var length = UInt32(body.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        return data
    }

    private func frameLength(_ header: Data) -> Int {
        header.reduce(0) { ($0 << 8) | Int($1) }
    }

    private func endpointKey(_ endpoint: NWEndpoint) -> String {
        "\(endpoint)"
    }

    private func host(from endpoint: NWEndpoint?) -> NWEndpoint.Host? {
        guard let endpoint else { return nil }
        if case let .hostPort(host, _) = endpoint {
            return host
        }
        return nil
    }

    private func retain(_ connection: NWConnection) {
        retainedConnections.append(connection)
        if retainedConnections.count > 32 {
            retainedConnections.removeFirst(retainedConnections.count - 32)
        }
    }
}

final class SessionManager {
    private let store: AppStore
    private(set) var currentSessionId: String?

    init(store: AppStore) {
        self.store = store
    }

    var currentSession: ScreenSession? {
        guard let id = currentSessionId else { return nil }
        return store.sessions.first { $0.id == id }
    }

    func recoverOpenSessions() {
        store.recoverOpenSessions()
        currentSessionId = nil
    }

    func startNewSession(now: Date = Date()) {
        if let currentSession {
            store.closeOpenSessionsForCurrentDevice(except: currentSession.id, action: .crashRecovered, now: now)
            return
        }
        store.closeOpenSessionsForCurrentDevice(action: .crashRecovered, now: now)
        let session = ScreenSession(
            id: UUID().uuidString,
            deviceId: store.settings.deviceId,
            deviceName: store.settings.deviceName,
            platform: "macos",
            measurementScope: .globalExact,
            startAtUtc: now,
            startTimezone: TimeZone.current.identifier,
            endAtUtc: nil,
            endTimezone: nil,
            durationSeconds: 0,
            stopAction: nil,
            heartbeatAtUtc: now,
            createdAtUtc: now,
            updatedAtUtc: now,
            revision: 1,
            syncStatus: "local"
        )
        currentSessionId = session.id
        store.upsertSession(session)
    }

    func endCurrentSession(action: StopAction, now: Date = Date()) {
        let id = currentSessionId ?? store.latestOpenSessionForCurrentDevice()?.id
        guard let id, var session = store.sessions.first(where: { $0.id == id }) else { return }
        guard session.endAtUtc == nil else {
            currentSessionId = nil
            return
        }

        let effectiveEnd = store.effectiveEnd(for: session, now: now)
        session.endAtUtc = effectiveEnd
        session.endTimezone = TimeZone.current.identifier
        session.durationSeconds = max(0, Int(effectiveEnd.timeIntervalSince(session.startAtUtc)))
        session.stopAction = action
        session.heartbeatAtUtc = effectiveEnd
        session.updatedAtUtc = now
        session.revision += 1
        currentSessionId = nil
        store.upsertSession(session)
        store.recomputeDailyTotals()
    }

    func heartbeat(now: Date = Date()) {
        guard let id = currentSessionId, var session = store.sessions.first(where: { $0.id == id }) else { return }
        session.heartbeatAtUtc = now
        session.updatedAtUtc = now
        store.upsertSession(session)
    }

    func elapsedSeconds(now: Date = Date()) -> Int {
        guard let currentSession else { return 0 }
        return max(0, Int(now.timeIntervalSince(currentSession.startAtUtc)))
    }

    func todaySecondsIncludingCurrent() -> Int {
        store.totalSecondsForDayIncludingOpen(Date())
    }
}

enum DateTools {
    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func dateTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func weekId(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.yearForWeekOfYear, from: date)
        let week = calendar.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    static func currentWeekStart(_ date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay) ?? startOfDay
    }

    static func formatDuration(_ seconds: Int, language: String = "zh") -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if language == "en" {
            if hours > 0 { return "\(hours)h \(minutes)m" }
            if minutes > 0 { return "\(minutes)m \(secs)s" }
            return "\(secs)s"
        }
        if hours > 0 { return "\(hours)小时\(minutes)分钟" }
        if minutes > 0 { return "\(minutes)分钟\(secs)秒" }
        return "\(secs)秒"
    }
}

func splitSecondsByLocalDate(start: Date, end: Date, calendar: Calendar) -> [(date: String, seconds: Int)] {
    guard end > start else { return [] }
    var cursor = start
    var results: [(String, Int)] = []

    while cursor < end {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? end
        let segmentEnd = min(nextDay, end)
        let seconds = max(0, Int(segmentEnd.timeIntervalSince(cursor)))
        if seconds > 0 {
            results.append((DateTools.dateString(cursor), seconds))
        }
        cursor = segmentEnd
    }
    return results
}

func normalizedPlatform(_ platform: String) -> String {
    let value = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return value.isEmpty ? "unknown" : value
}

func platformTitle(_ platform: String) -> String {
    switch normalizedPlatform(platform) {
    case "macos": return "macOS"
    case "ios": return "iOS"
    case "ipados": return "iPadOS"
    case "windows": return "Windows"
    case "android": return "Android"
    default: return platform.isEmpty ? "未知平台" : platform
    }
}

extension URL {
    func appendingPathComponentPreservingQuery(_ path: String) -> URL {
        URL(string: path, relativeTo: self)?.absoluteURL ?? appendingPathComponent(path)
    }
}

func string(_ value: Any?) -> String {
    if let value = value as? String {
        return value
    }
    if let value = value as? NSNumber {
        return value.stringValue
    }
    return ""
}

func number(_ value: Any?) -> Double {
    if let value = value as? Double {
        return value
    }
    if let value = value as? Int {
        return Double(value)
    }
    if let value = value as? NSNumber {
        return value.doubleValue
    }
    if let value = value as? String {
        return Double(value) ?? 0
    }
    return 0
}

final class ReportWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AppStore
    private let onClear: (() -> Void)?
    private let modeControl = NSSegmentedControl(labels: ["日报", "多日报"], trackingMode: .selectOne, target: nil, action: nil)
    private let datePicker = NSDatePicker()
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let clearDayButton = NSButton()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let deviceTable = NSTableView()
    private let platformTable = NSTableView()
    private let detailTable = NSTableView()
    private var deviceRows: [[String]] = []
    private var platformRows: [[String]] = []
    private var detailRows: [[String]] = []

    init(store: AppStore, onClear: (() -> Void)? = nil) {
        self.store = store
        self.onClear = onClear
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedText("报告", "Report", language: store.settings.language)
        window.minSize = NSSize(width: 980, height: 560)
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let language = store.settings.language
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        modeControl.selectedSegment = 0
        modeControl.setLabel(localizedText("日报", "Daily", language: language), forSegment: 0)
        modeControl.setLabel(localizedText("多日报", "Multi-Day", language: language), forSegment: 1)
        modeControl.target = self
        modeControl.action = #selector(refresh)
        content.addSubview(modeControl)

        configureDatePicker(datePicker)
        configureDatePicker(startPicker)
        configureDatePicker(endPicker)
        startPicker.isHidden = true
        endPicker.isHidden = true
        content.addSubview(datePicker)
        content.addSubview(startPicker)
        content.addSubview(endPicker)

        let refreshButton = NSButton(title: localizedText("刷新", "Refresh", language: language), target: self, action: #selector(refresh))
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(refreshButton)

        clearDayButton.title = localizedText("清除当日记录", "Clear Day", language: language)
        clearDayButton.target = self
        clearDayButton.action = #selector(clearDailyRecords)
        clearDayButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(clearDayButton)

        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = NSFont.boldSystemFont(ofSize: 14)
        summaryLabel.lineBreakMode = .byTruncatingTail
        content.addSubview(summaryLabel)

        configureTable(deviceTable)
        configureTable(platformTable)
        configureTable(detailTable)

        let topTables = NSStackView(views: [
            buildTablePanel(title: localizedText("本报告范围各设备用时", "Device Usage in This Report", language: language), table: deviceTable),
            buildTablePanel(title: localizedText("上周各平台统计", "Previous Week by Platform", language: language), table: platformTable)
        ])
        topTables.translatesAutoresizingMaskIntoConstraints = false
        topTables.orientation = .horizontal
        topTables.spacing = 14
        topTables.distribution = .fillEqually
        content.addSubview(topTables)

        let detailPanel = buildTablePanel(title: localizedText("明细", "Details", language: language), table: detailTable)
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(detailPanel)

        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            modeControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            modeControl.widthAnchor.constraint(equalToConstant: 160),
            modeControl.heightAnchor.constraint(equalToConstant: 28),

            datePicker.leadingAnchor.constraint(equalTo: modeControl.trailingAnchor, constant: 20),
            datePicker.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            datePicker.widthAnchor.constraint(equalToConstant: 150),

            startPicker.leadingAnchor.constraint(equalTo: datePicker.trailingAnchor, constant: 20),
            startPicker.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            startPicker.widthAnchor.constraint(equalToConstant: 150),

            endPicker.leadingAnchor.constraint(equalTo: startPicker.trailingAnchor, constant: 20),
            endPicker.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            endPicker.widthAnchor.constraint(equalToConstant: 150),

            refreshButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            refreshButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            refreshButton.widthAnchor.constraint(equalToConstant: 80),

            clearDayButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -10),
            clearDayButton.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            clearDayButton.widthAnchor.constraint(equalToConstant: 120),

            summaryLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            summaryLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            summaryLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 14),

            topTables.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            topTables.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            topTables.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            topTables.heightAnchor.constraint(equalToConstant: 210),

            detailPanel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            detailPanel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            detailPanel.topAnchor.constraint(equalTo: topTables.bottomAnchor, constant: 14),
            detailPanel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        refresh()
    }

    private func buildTablePanel(title: String, table: NSTableView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.documentView = table

        let stack = NSStackView(views: [label, scrollView])
        stack.orientation = .vertical
        stack.spacing = 6
        return stack
    }

    private func configureTable(_ table: NSTableView) {
        table.delegate = self
        table.dataSource = self
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowHeight = 26
        table.allowsColumnReordering = false
        table.allowsMultipleSelection = false
    }

    private func configureDatePicker(_ picker: NSDatePicker) {
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = .yearMonthDay
        picker.dateValue = Date()
        picker.target = self
        picker.action = #selector(refresh)
    }

    @objc private func refresh() {
        store.closeExpiredOpenSessions(now: Date())
        let isDaily = modeControl.selectedSegment == 0
        datePicker.isHidden = !isDaily
        startPicker.isHidden = isDaily
        endPicker.isHidden = isDaily
        clearDayButton.isHidden = !isDaily
        isDaily ? fillDailyReport() : fillMultiDayReport()
    }

    @objc private func clearDailyRecords() {
        let language = store.settings.language
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = localizedText("清除当日记录？", "Clear this day's records?", language: language)
        alert.informativeText = localizedText(
            "将清除所选日期已记录的屏幕用时，并通过 P2P 同步删除到已同意设备。清除后新产生的记录会继续保存。",
            "This clears recorded screen time for the selected date and syncs the deletion to approved devices. New records after clearing will continue to be saved.",
            language: language
        )
        alert.addButton(withTitle: localizedText("清除", "Clear", language: language))
        alert.addButton(withTitle: localizedText("取消", "Cancel", language: language))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = store.clearSessions(for: datePicker.dateValue)
        onClear?()
        summaryLabel.stringValue = "\(localizedText("已清除记录", "Cleared records", language: language))：\(removed)"
        refresh()
    }

    private func fillDailyReport() {
        store.recomputeDailyTotals()
        let language = store.settings.language
        let date = datePicker.dateValue
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let now = Date()
        let total = store.totalSecondsForDayIncludingOpen(date, now: now)
        summaryLabel.stringValue = "\(localizedText("日报", "Daily", language: language)) \(DateTools.dateString(date))    \(localizedText("去重总用时", "Deduplicated Total", language: language))：\(DateTools.formatDuration(total, language: language))"
        fillDeviceUsage(from: dayStart, to: dayEnd, dayCount: 1, language: language)
        fillWeeklyPlatformUsage(language: language)
        let rows = store.sessionsForDate(date).map { session -> [String] in
            let effectiveStart = max(session.startAtUtc, dayStart)
            let effectiveEnd = min(store.effectiveEnd(for: session, now: now), dayEnd)
            let durationSeconds = max(0, Int(effectiveEnd.timeIntervalSince(effectiveStart)))
            return [
                DateTools.dateTimeString(effectiveStart),
                store.isLocalOpenSession(session) ? localizedText("进行中", "In progress", language: language) : DateTools.dateTimeString(effectiveEnd),
                DateTools.formatDuration(durationSeconds, language: language),
                session.stopAction?.title(language: language) ?? localizedText("进行中", "In progress", language: language),
                platformTitle(session.platform),
                session.deviceName,
                session.measurementScope.rawValue
            ]
        }
        setRows(
            rows,
            columns: [
                ("start", localizedText("开始", "Start", language: language), 150),
                ("end", localizedText("结束", "End", language: language), 150),
                ("duration", localizedText("时长", "Duration", language: language), 100),
                ("action", localizedText("停止动作", "Stop Action", language: language), 120),
                ("platform", localizedText("平台", "Platform", language: language), 80),
                ("device", localizedText("设备", "Device", language: language), 170),
                ("scope", localizedText("数据范围", "Scope", language: language), 150)
            ],
            for: detailTable
        )
    }

    private func fillMultiDayReport() {
        store.recomputeDailyTotals()
        let language = store.settings.language
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: min(startPicker.dateValue, endPicker.dateValue))
        let endDate = calendar.startOfDay(for: max(startPicker.dateValue, endPicker.dateValue))
        var date = startDate
        var summaries: [(String, Int)] = []

        while date <= endDate {
            let dateString = DateTools.dateString(date)
            summaries.append((dateString, store.totalSecondsForDayIncludingOpen(date)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }

        let total = summaries.reduce(0) { $0 + $1.1 }
        let average = summaries.isEmpty ? 0 : total / summaries.count
        summaryLabel.stringValue = "\(localizedText("多日报", "Multi-Day", language: language)) \(DateTools.dateString(startDate)) \(localizedText("至", "to", language: language)) \(DateTools.dateString(endDate))    \(localizedText("去重总用时", "Deduplicated Total", language: language))：\(DateTools.formatDuration(total, language: language))    \(localizedText("每天平均", "Daily Average", language: language))：\(DateTools.formatDuration(average, language: language))"
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        fillDeviceUsage(from: startDate, to: rangeEnd, dayCount: max(1, summaries.count), language: language)
        fillWeeklyPlatformUsage(language: language)
        setRows(
            summaries.map { [$0.0, DateTools.formatDuration($0.1, language: language)] },
            columns: [
                ("date", localizedText("日期", "Date", language: language), 180),
                ("duration", localizedText("去重总用时", "Deduplicated Total", language: language), 180)
            ],
            for: detailTable
        )
    }

    private func fillDeviceUsage(from start: Date, to end: Date, dayCount: Int, language: String) {
        let devices = store.deviceUsageSummaries(from: start, to: end, dayCount: dayCount)
        setRows(
            devices.map {
                [
                    $0.deviceName,
                    platformTitle($0.platform),
                    DateTools.formatDuration($0.totalSeconds, language: language),
                    DateTools.formatDuration($0.averageDailySeconds, language: language)
                ]
            },
            columns: [
                ("device", localizedText("设备", "Device", language: language), 180),
                ("platform", localizedText("平台", "Platform", language: language), 80),
                ("total", localizedText("总用时", "Total", language: language), 120),
                ("average", localizedText("平均每天", "Daily Average", language: language), 120)
            ],
            for: deviceTable
        )
    }

    private func fillWeeklyPlatformUsage(language: String) {
        let weekly = store.previousWeekUsageSummary()
        let rows = [[localizedText("全部平台去重", "All Platforms Deduplicated", language: language), DateTools.formatDuration(weekly.totalSeconds, language: language), DateTools.formatDuration(weekly.averageDailySeconds, language: language)]] + weekly.platforms.map {
            [
                platformTitle($0.platform),
                DateTools.formatDuration($0.totalSeconds, language: language),
                DateTools.formatDuration($0.averageDailySeconds, language: language)
            ]
        }
        setRows(
            rows,
            columns: [
                ("platform", localizedText("平台", "Platform", language: language), 140),
                ("total", localizedText("上周总计", "Weekly Total", language: language), 140),
                ("average", localizedText("平均每天", "Daily Average", language: language), 140)
            ],
            for: platformTable
        )
    }

    private func setRows(_ rows: [[String]], columns: [(id: String, title: String, width: CGFloat)], for table: NSTableView) {
        table.tableColumns.forEach { table.removeTableColumn($0) }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.id))
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = 60
            table.addTableColumn(tableColumn)
        }

        let normalizedRows: [[String]]
        if rows.isEmpty {
            var emptyRow = Array(repeating: "-", count: columns.count)
            if !emptyRow.isEmpty { emptyRow[0] = localizedText("暂无记录", "No records", language: store.settings.language) }
            normalizedRows = [emptyRow]
        } else {
            normalizedRows = rows.map { row in
                if row.count == columns.count { return row }
                if row.count > columns.count { return Array(row.prefix(columns.count)) }
                return row + Array(repeating: "", count: columns.count - row.count)
            }
        }

        if table === deviceTable {
            deviceRows = normalizedRows
        } else if table === platformTable {
            platformRows = normalizedRows
        } else {
            detailRows = normalizedRows
        }
        table.reloadData()
    }

    private func rows(for tableView: NSTableView) -> [[String]] {
        if tableView === deviceTable { return deviceRows }
        if tableView === platformTable { return platformRows }
        return detailRows
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows(for: tableView).count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowData = rows(for: tableView)
        guard row < rowData.count else { return nil }
        let columnIndex = tableColumn.flatMap { column in
            tableView.tableColumns.firstIndex { $0 === column }
        } ?? 0
        let identifier = NSUserInterfaceItemIdentifier("ReportTableCell")
        let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.isBordered = false
        field.isEditable = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 2
        field.stringValue = columnIndex < rowData[row].count ? rowData[row][columnIndex] : ""
        return field
    }
}

final class SettingsWindowController: NSWindowController {
    private let store: AppStore
    private let p2pService: P2PSyncService?
    private let onSave: () -> Void
    private let languagePopup = NSPopUpButton()
    private let postureSwitchCheckbox = NSButton(checkboxWithTitle: "姿势切换", target: nil, action: nil)
    private let eyeRestIntervalField = NSTextField()
    private let postureRestIntervalField = NSTextField()
    private let plannedDailyHoursField = NSTextField()
    private let plannedDailyMinutesField = NSTextField()
    private let trackingPopup = NSPopUpButton()
    private let deviceNameField = NSTextField()
    private let p2pSyncCheckbox = NSButton(checkboxWithTitle: "P2P 同步（局域网）", target: nil, action: nil)
    private let pairingCodeField = NSTextField()
    private let syncIntervalField = NSTextField()
    private let syncStatusLabel = NSTextField(labelWithString: "")
    private let peerPopup = NSPopUpButton()
    private let dataDirectoryField = NSTextField()
    private let meetingCheckbox = NSButton(checkboxWithTitle: "会议模式", target: nil, action: nil)
    private let autoStartCheckbox = NSButton(checkboxWithTitle: "系统启动时自动启动", target: nil, action: nil)

    init(store: AppStore, p2pService: P2PSyncService? = nil, onSave: @escaping () -> Void = {}) {
        self.store = store
        self.p2pService = p2pService
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 725),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedText("设置", "Settings", language: store.settings.language)
        super.init(window: window)
        setup()
        p2pService?.onStateChanged = { [weak self] in
            self?.refreshP2PControls()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let language = store.settings.language
        var y = 665
        addLabel(localizedText("APP 语言", "App Language", language: language), x: 24, y: y, to: content)
        languagePopup.frame = NSRect(x: 190, y: y - 4, width: 180, height: 28)
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: ["中文", "English"])
        languagePopup.selectItem(at: store.settings.language == "en" ? 1 : 0)
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)
        content.addSubview(languagePopup)

        y -= 44
        addLabel(localizedText("姿势切换", "Posture Switch", language: language), x: 24, y: y, to: content)
        postureSwitchCheckbox.title = localizedText("启用姿势切换", "Enable posture switch", language: language)
        postureSwitchCheckbox.frame = NSRect(x: 188, y: y - 2, width: 240, height: 24)
        postureSwitchCheckbox.state = (store.settings.postureSwitchEnabled ?? true) ? .on : .off
        content.addSubview(postureSwitchCheckbox)

        y -= 44
        addLabel(localizedText("护眼间隔（分钟）", "Eye Rest Interval (min)", language: language), x: 24, y: y, to: content)
        eyeRestIntervalField.frame = NSRect(x: 190, y: y - 2, width: 80, height: 24)
        eyeRestIntervalField.integerValue = store.settings.eyeRestIntervalMinutes ?? 3
        content.addSubview(eyeRestIntervalField)
        addLabel(localizedText("默认 3", "Default 3", language: language), x: 285, y: y, to: content)

        y -= 44
        addLabel(localizedText("姿势提醒间隔", "Posture Interval", language: language), x: 24, y: y, to: content)
        postureRestIntervalField.frame = NSRect(x: 190, y: y - 2, width: 80, height: 24)
        postureRestIntervalField.integerValue = AppSettings.derivedPostureRestIntervalMinutes(from: store.settings.eyeRestIntervalMinutes ?? 3)
        postureRestIntervalField.isEditable = false
        content.addSubview(postureRestIntervalField)
        addLabel(localizedText("护眼间隔的 2 倍", "2x eye rest", language: language), x: 285, y: y, to: content)

        y -= 44
        let plannedDailyMinutes = store.settings.plannedDailyMinutes ?? 480
        addLabel(localizedText("每日计划用时", "Daily Plan", language: language), x: 24, y: y, to: content)
        plannedDailyHoursField.frame = NSRect(x: 190, y: y - 2, width: 56, height: 24)
        plannedDailyHoursField.integerValue = plannedDailyMinutes / 60
        content.addSubview(plannedDailyHoursField)
        addLabel(localizedText("小时", "h", language: language), x: 252, y: y, to: content)
        plannedDailyMinutesField.frame = NSRect(x: 305, y: y - 2, width: 56, height: 24)
        plannedDailyMinutesField.integerValue = plannedDailyMinutes % 60
        content.addSubview(plannedDailyMinutesField)
        addLabel(localizedText("分钟，默认 8小时0分钟", "min, default 8h 0m", language: language), x: 367, y: y, to: content)

        y -= 44
        addLabel(localizedText("跟踪对象", "Tracking Target", language: language), x: 24, y: y, to: content)
        trackingPopup.frame = NSRect(x: 190, y: y - 4, width: 180, height: 28)
        trackingPopup.addItems(withTitles: ["LLM Ranking"])
        content.addSubview(trackingPopup)

        y -= 44
        addLabel(localizedText("设备名称", "Device Name", language: language), x: 24, y: y, to: content)
        deviceNameField.frame = NSRect(x: 190, y: y - 2, width: 300, height: 24)
        deviceNameField.stringValue = store.settings.deviceName
        content.addSubview(deviceNameField)

        y -= 44
        addLabel(localizedText("同步方式", "Sync Method", language: language), x: 24, y: y, to: content)
        p2pSyncCheckbox.title = localizedText("P2P 同步（局域网）", "P2P Sync (Local Network)", language: language)
        p2pSyncCheckbox.frame = NSRect(x: 188, y: y - 2, width: 240, height: 24)
        p2pSyncCheckbox.state = (store.settings.p2pSyncEnabled ?? true) ? .on : .off
        content.addSubview(p2pSyncCheckbox)

        y -= 44
        addLabel(localizedText("P2P 配对码", "P2P Pairing Code", language: language), x: 24, y: y, to: content)
        pairingCodeField.frame = NSRect(x: 190, y: y - 2, width: 120, height: 24)
        pairingCodeField.stringValue = store.settings.p2pPairingCode ?? ""
        content.addSubview(pairingCodeField)
        addLabel(localizedText("多台设备填同一码", "Use the same code", language: language), x: 325, y: y, to: content)

        y -= 44
        addLabel(localizedText("同步间隔（分钟）", "Sync Interval (minutes)", language: language), x: 24, y: y, to: content)
        syncIntervalField.frame = NSRect(x: 190, y: y - 2, width: 80, height: 24)
        syncIntervalField.integerValue = store.settings.p2pSyncIntervalMinutes ?? 5
        content.addSubview(syncIntervalField)

        let syncNowButton = NSButton(title: localizedText("立即同步", "Sync Now", language: language), target: self, action: #selector(syncNow))
        syncNowButton.frame = NSRect(x: 285, y: y - 5, width: 90, height: 30)
        content.addSubview(syncNowButton)
        let rediscoverButton = NSButton(title: localizedText("重新发现", "Rediscover", language: language), target: self, action: #selector(rediscoverPeers))
        rediscoverButton.frame = NSRect(x: 380, y: y - 5, width: 90, height: 30)
        content.addSubview(rediscoverButton)

        y -= 44
        addLabel(localizedText("配对设备", "Paired Devices", language: language), x: 24, y: y, to: content)
        peerPopup.frame = NSRect(x: 190, y: y - 4, width: 250, height: 28)
        content.addSubview(peerPopup)
        let approveButton = NSButton(title: localizedText("同意", "Approve", language: language), target: self, action: #selector(approvePeer))
        approveButton.frame = NSRect(x: 450, y: y - 5, width: 70, height: 30)
        content.addSubview(approveButton)
        let rejectButton = NSButton(title: localizedText("拒绝", "Reject", language: language), target: self, action: #selector(rejectPeer))
        rejectButton.frame = NSRect(x: 525, y: y - 5, width: 70, height: 30)
        content.addSubview(rejectButton)

        y -= 34
        syncStatusLabel.frame = NSRect(x: 190, y: y, width: 390, height: 22)
        content.addSubview(syncStatusLabel)
        refreshP2PControls()

        y -= 38
        meetingCheckbox.title = localizedText("会议模式", "Meeting Mode", language: language)
        meetingCheckbox.frame = NSRect(x: 188, y: y - 2, width: 200, height: 24)
        meetingCheckbox.state = store.settings.meetingMode ? .on : .off
        content.addSubview(meetingCheckbox)

        y -= 38
        autoStartCheckbox.title = localizedText("系统启动时自动启动", "Launch at system startup", language: language)
        autoStartCheckbox.frame = NSRect(x: 188, y: y - 2, width: 240, height: 24)
        autoStartCheckbox.state = store.settings.autoStartEnabled ? .on : .off
        content.addSubview(autoStartCheckbox)

        y -= 38
        addLabel(localizedText("数据目录", "Data Directory", language: language), x: 24, y: y, to: content)
        dataDirectoryField.frame = NSRect(x: 190, y: y - 2, width: 285, height: 24)
        dataDirectoryField.stringValue = store.supportURL.path
        content.addSubview(dataDirectoryField)
        let chooseDirectoryButton = NSButton(title: localizedText("选择", "Choose", language: language), target: self, action: #selector(chooseDataDirectory))
        chooseDirectoryButton.frame = NSRect(x: 485, y: y - 5, width: 85, height: 30)
        content.addSubview(chooseDirectoryButton)

        let saveButton = NSButton(title: localizedText("保存", "Save", language: language), target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 365, y: 24, width: 80, height: 32)
        content.addSubview(saveButton)

        let cancelButton = NSButton(title: localizedText("取消", "Cancel", language: language), target: self, action: #selector(cancel))
        cancelButton.frame = NSRect(x: 455, y: 24, width: 80, height: 32)
        content.addSubview(cancelButton)
    }

    private func addLabel(_ title: String, x: Int, y: Int, to view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: x, y: y, width: 150, height: 22)
        view.addSubview(label)
    }

    @objc private func save() {
        _ = applySettingsFromControls()
        onSave()
        window?.close()
    }

    @objc private func languageChanged() {
        _ = applySettingsFromControls()
        onSave()
        window?.title = localizedText("设置", "Settings", language: store.settings.language)
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        setup()
    }

    @discardableResult
    private func applySettingsFromControls() -> Bool {
        let oldP2PEnabled = store.settings.p2pSyncEnabled ?? true
        let oldPairingCode = store.settings.p2pPairingCode ?? ""
        let oldSyncInterval = store.settings.p2pSyncIntervalMinutes ?? 5
        let oldDeviceName = store.settings.deviceName

        store.settings.language = languagePopup.indexOfSelectedItem == 1 ? "en" : "zh"
        store.settings.postureSwitchEnabled = postureSwitchCheckbox.state == .on
        store.settings.eyeRestIntervalMinutes = min(1440, max(1, eyeRestIntervalField.integerValue))
        store.settings.postureRestIntervalMinutes = AppSettings.derivedPostureRestIntervalMinutes(from: store.settings.eyeRestIntervalMinutes ?? 3)
        let plannedHours = min(24, max(0, plannedDailyHoursField.integerValue))
        let plannedMinutes = min(59, max(0, plannedDailyMinutesField.integerValue))
        let plannedTotal = plannedHours * 60 + plannedMinutes
        store.settings.plannedDailyMinutes = min(1440, max(1, plannedTotal == 0 ? 480 : plannedTotal))
        store.settings.trackingObject = "LLM Ranking"
        store.settings.p2pSyncEnabled = p2pSyncCheckbox.state == .on
        let pairingCode = pairingCodeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pairingCode.isEmpty {
            store.settings.p2pPairingCode = pairingCode
        }
        store.settings.p2pSyncIntervalMinutes = min(1440, max(1, syncIntervalField.integerValue))
        let deviceName = deviceNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceName.isEmpty {
            store.settings.deviceName = deviceName
        }
        store.settings.meetingMode = meetingCheckbox.state == .on
        store.settings.autoStartEnabled = autoStartCheckbox.state == .on
        store.updateDataDirectory(dataDirectoryField.stringValue)
        store.saveSettings()

        return oldP2PEnabled != (store.settings.p2pSyncEnabled ?? true)
            || oldPairingCode != (store.settings.p2pPairingCode ?? "")
            || oldSyncInterval != (store.settings.p2pSyncIntervalMinutes ?? 5)
            || oldDeviceName != store.settings.deviceName
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func chooseDataDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: dataDirectoryField.stringValue, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            dataDirectoryField.stringValue = url.path
        }
    }

    @objc private func syncNow() {
        _ = applySettingsFromControls()
        syncStatusLabel.stringValue = localizedText("同步设置已保存，正在重新发现设备", "Sync settings saved; rediscovering devices", language: store.settings.language)
        onSave()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.p2pService?.syncNow()
            self?.refreshP2PControls()
        }
    }

    @objc private func rediscoverPeers() {
        _ = applySettingsFromControls()
        syncStatusLabel.stringValue = localizedText("同步设置已保存，正在重新发现设备", "Sync settings saved; rediscovering devices", language: store.settings.language)
        onSave()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshP2PControls()
        }
    }

    @objc private func approvePeer() {
        guard let deviceId = peerPopup.selectedItem?.representedObject as? String else { return }
        syncStatusLabel.stringValue = store.trustStatus(for: deviceId) == "已同意"
            ? localizedText("该设备已同意，正在尝试同步", "This device is approved; trying to sync", language: store.settings.language)
            : localizedText("正在同意设备", "Approving device", language: store.settings.language)
        p2pService?.approvePeer(deviceId)
        refreshP2PControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshP2PControls()
        }
    }

    @objc private func rejectPeer() {
        guard let deviceId = peerPopup.selectedItem?.representedObject as? String else { return }
        syncStatusLabel.stringValue = localizedText("正在拒绝设备", "Rejecting device", language: store.settings.language)
        p2pService?.rejectPeer(deviceId)
        refreshP2PControls()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshP2PControls()
        }
    }

    private func refreshP2PControls() {
        let language = store.settings.language
        syncStatusLabel.stringValue = localizedSyncStatus(p2pService?.status ?? localizedText("P2P 未启动", "P2P not started", language: language), language: language)
        let selectedId = peerPopup.selectedItem?.representedObject as? String
        peerPopup.removeAllItems()
        let livePeers = p2pService?.peersSnapshot() ?? []
        let livePeerIds = Set(livePeers.map { $0.deviceId.lowercased() })
        let savedPeers = (store.settings.pairedPeers ?? [])
            .filter {
                !livePeerIds.contains($0.deviceId.lowercased()) &&
                    store.trustStatus(for: $0.deviceId) == "已同意"
            }
            .map { record in
                return P2PDiscoveredPeer(
                    deviceId: record.deviceId,
                    deviceName: record.deviceName.isEmpty ? "\(localizedText("已同意设备", "Approved Device", language: language)) \(record.deviceId.prefix(8))" : record.deviceName,
                    platform: record.platform.isEmpty ? "unknown" : record.platform,
                    appVersion: record.appVersion.isEmpty ? "unknown" : record.appVersion,
                    address: localizedText("等待重新发现", "Waiting to rediscover", language: language),
                    tcpPort: 0,
                    lastSeenAt: record.lastSeenAtUtc,
                    lastSyncAt: nil,
                    status: "已同意，等待重新发现",
                    trustStatus: "已同意",
                    pairingMatched: true,
                    capabilities: normalizedSyncCapabilities(record.capabilities)
                )
            }
        let peers = livePeers + savedPeers
        if peers.isEmpty {
            peerPopup.addItem(withTitle: localizedText("暂无发现设备", "No devices found", language: language))
            peerPopup.lastItem?.representedObject = nil
            return
        }
        for peer in peers {
            peerPopup.addItem(withTitle: "\(peer.deviceName) · \(platformTitle(peer.platform)) · \(localizedSyncStatus(peer.trustStatus, language: language)) · \(localizedSyncStatus(peer.status, language: language))")
            peerPopup.lastItem?.representedObject = peer.deviceId
        }
        if let selectedId,
           let index = peerPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedId }) {
            peerPopup.selectItem(at: index)
        }
    }
}

final class TrackingWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: AppStore
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private var sourceRows: [LLMRankingRow] = []
    private var rows: [LLMRankingRow] = []
    private var isFetching = false
    private var isApplyingSortDescriptor = false
    private var sortKey = "promptTokens"
    private var sortAscending = false

    init(store: AppStore) {
        self.store = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(localizedText("跟踪", "Tracking", language: store.settings.language)) - LLM Ranking"
        window.minSize = NSSize(width: 1120, height: 520)
        super.init(window: window)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        guard let content = window?.contentView else { return }
        let language = store.settings.language
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusLabel)

        let reloadButton = NSButton(title: localizedText("刷新数据", "Refresh", language: language), target: self, action: #selector(fetchLatestRanking))
        reloadButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(reloadButton)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.autoresizingMask = [.width, .height]
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = NSTableHeaderView()
        addColumn("rank", localizedText("排名", "Rank", language: language), 60)
        addColumn("llmName", localizedText("LLM 名字", "LLM Name", language: language), 315)
        addColumn("promptTokens", "Prompt Tokens", 160)
        addColumn("outputTokens", "Output Tokens", 160)
        addColumn("inputPrice", "Input Price / 1M", 150)
        addColumn("outputPrice", "Output Price / 1M", 155)
        addColumn("revenue", "Weekly Revenue", 155)
        tableView.frame = NSRect(x: 0, y: 0, width: 1155, height: 520)
        scroll.documentView = tableView
        content.addSubview(scroll)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            statusLabel.trailingAnchor.constraint(equalTo: reloadButton.leadingAnchor, constant: -16),

            reloadButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reloadButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: 110),

            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])

        loadCacheOrFetch()
    }

    private func addColumn(_ identifier: String, _ title: String, _ width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func loadCacheOrFetch() {
        switch store.loadCurrentLLMRanking() {
        case .success(let cache):
            apply(cache: cache)
        case .failure(let message):
            rows = []
            statusLabel.stringValue = localizedText(message.message, message.message, language: store.settings.language)
            tableView.reloadData()
            fetchLatestRanking()
        }
    }

    private func apply(cache: LLMRankingCache) {
        sourceRows = cache.rows
        sortRows()
        let language = store.settings.language
        statusLabel.stringValue = "\(localizedText("来源", "Source", language: language))：\(cache.source)  \(localizedText("周", "Week", language: language))：\(cache.weekId)  \(localizedText("抓取", "Fetched", language: language))：\(DateTools.dateTimeString(cache.fetchedAtUtc))"
    }

    @objc private func fetchLatestRanking() {
        guard !isFetching else { return }
        isFetching = true
        statusLabel.stringValue = localizedText("正在从 OpenRouter 获取本周 prompt token Top 20...", "Fetching this week's prompt token Top 20 from OpenRouter...", language: store.settings.language)
        sourceRows = []
        rows = []
        tableView.reloadData()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let cache = try OpenRouterClient().fetchWeeklyPromptTokenTop20()
                try self.store.saveLLMRankingCache(cache)
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.apply(cache: cache)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isFetching = false
                    self.statusLabel.stringValue = "\(localizedText("OpenRouter 获取失败", "OpenRouter fetch failed", language: self.store.settings.language))：\(error.localizedDescription)"
                    self.tableView.reloadData()
                }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let identifier = tableColumn?.identifier.rawValue else { return nil }
        let textField = NSTextField(labelWithString: value(for: identifier, row: rows[row]))
        textField.lineBreakMode = .byTruncatingTail
        return textField
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingSortDescriptor else { return }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let key = tableColumn.identifier.rawValue
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        updateSortIndicator()
        sortRows()
    }

    private func updateSortIndicator() {
        isApplyingSortDescriptor = true
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: sortAscending)]
        isApplyingSortDescriptor = false
    }

    private func sortRows() {
        rows = sourceRows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortKey {
            case "rank": order = compare(lhs.rank, rhs.rank)
            case "llmName": order = lhs.llmName.localizedCaseInsensitiveCompare(rhs.llmName)
            case "promptTokens": order = compare(lhs.promptTokens, rhs.promptTokens)
            case "outputTokens": order = compare(lhs.outputTokens, rhs.outputTokens)
            case "inputPrice": order = compare(lhs.weightedAverageInputPrice, rhs.weightedAverageInputPrice)
            case "outputPrice": order = compare(lhs.weightedAverageOutputPrice, rhs.weightedAverageOutputPrice)
            case "revenue": order = compare(lhs.weeklyRevenue, rhs.weeklyRevenue)
            default: order = compare(lhs.promptTokens, rhs.promptTokens)
            }
            if order == .orderedSame {
                return lhs.rank == rhs.rank ? lhs.llmName < rhs.llmName : lhs.rank < rhs.rank
            }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
        tableView.reloadData()
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func value(for identifier: String, row: LLMRankingRow) -> String {
        switch identifier {
        case "rank": return "\(row.rank)"
        case "llmName": return row.llmName
        case "promptTokens": return formatNumber(row.promptTokens)
        case "outputTokens": return formatNumber(row.outputTokens)
        case "inputPrice": return formatPrice(row.weightedAverageInputPrice)
        case "outputPrice": return formatPrice(row.weightedAverageOutputPrice)
        case "revenue": return formatWholeCurrency(row.weeklyRevenue)
        default: return ""
        }
    }
}

final class RestPromptWindowController: NSWindowController {
    private let countdownSeconds: Int
    private let immediateClose: Bool
    private let language: String
    private let onDismiss: () -> Void
    private let countdownLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private var timer: Timer?
    private let canCloseAt: Date

    init(title: String, message: String, countdownSeconds: Int, immediateClose: Bool, language: String = "zh", onDismiss: @escaping () -> Void) {
        self.countdownSeconds = countdownSeconds
        self.immediateClose = immediateClose
        self.language = language
        self.onDismiss = onDismiss
        self.canCloseAt = Date().addingTimeInterval(TimeInterval(countdownSeconds))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = title
        super.init(window: window)
        setup(message: message)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(message: String) {
        guard let content = window?.contentView else { return }
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.alignment = .center
        messageLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        messageLabel.frame = NSRect(x: 40, y: 142, width: 480, height: 112)
        content.addSubview(messageLabel)

        countdownLabel.alignment = .center
        countdownLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        countdownLabel.frame = NSRect(x: 40, y: 92, width: 480, height: 32)
        content.addSubview(countdownLabel)

        closeButton.title = localizedText("关闭", "Close", language: language)
        closeButton.target = self
        closeButton.action = #selector(closePrompt)
        closeButton.frame = NSRect(x: 230, y: 38, width: 100, height: 34)
        closeButton.isHidden = !immediateClose
        content.addSubview(closeButton)

        updateCountdownLabel()
        if !immediateClose {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    private var remaining: Int {
        max(0, Int(ceil(canCloseAt.timeIntervalSinceNow)))
    }

    private func tick() {
        updateCountdownLabel()
        if remaining <= 0 {
            timer?.invalidate()
            timer = nil
            closeButton.isHidden = false
        }
    }

    private func updateCountdownLabel() {
        if immediateClose {
            countdownLabel.stringValue = localizedText("会议模式：可以立即关闭", "Meeting mode: can close immediately", language: language)
        } else if remaining > 0 {
            countdownLabel.stringValue = language == "en" ? "\(remaining) seconds remaining" : "剩余 \(remaining) 秒"
        } else {
            countdownLabel.stringValue = localizedText("可以关闭", "Ready to close", language: language)
        }
    }

    @objc private func closePrompt() {
        timer?.invalidate()
        timer = nil
        window?.close()
        onDismiss()
    }

    func show() {
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var store: AppStore!
    private var sessionManager: SessionManager!
    private var p2pService: P2PSyncService!
    private var heartbeatTimer: Timer?
    private var reminderTimer: Timer?
    private var reportWindow: ReportWindowController?
    private var settingsWindow: SettingsWindowController?
    private var trackingWindow: TrackingWindowController?
    private var activePrompt: RestPromptWindowController?
    private var lastReminderSampleAt: Date?
    private var lastActivityTimerTickAt: Date?
    private var eyeActiveSeconds = 0
    private var postureActiveSeconds = 0
    private let sleepGapThreshold: TimeInterval = 90

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = AppStore()
        sessionManager = SessionManager(store: store)
        p2pService = P2PSyncService(store: store)
        sessionManager.recoverOpenSessions()
        sessionManager.startNewSession()
        resetReminderCounters(now: Date())
        p2pService.refresh()
        setupStatusItem()
        setupWorkspaceObservers()
        setupTimers()
        registerLoginItemIfNeeded()
        checkWeeklySummaryIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        p2pService.stop()
        sessionManager.endCurrentSession(action: .appExit)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "STG"
        item.button?.toolTip = appName
        statusItem = item
        refreshStatusMenu()
    }

    private func refreshStatusMenu() {
        let language = store.settings.language
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: localizedText("报告", "Report", language: language), action: #selector(openReport), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: localizedText("设置", "Settings", language: language), action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: localizedText("跟踪", "Tracking", language: language), action: #selector(openTracking), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: localizedText("关于", "About", language: language), action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: localizedText("退出", "Quit", language: language), action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items {
            menuItem.target = self
        }
        statusItem?.menu = menu
    }

    private func setupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidResignActive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionDidBecomeActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenSaverDidStart),
            name: Notification.Name("com.apple.screensaver.didstart"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenSaverDidStop),
            name: Notification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
    }

    private func setupTimers() {
        guard heartbeatTimer == nil, reminderTimer == nil else { return }
        lastActivityTimerTickAt = Date()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            let now = Date()
            guard self?.handleActivityTimerTick(now: now) == false else { return }
            self?.sessionManager.heartbeat()
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            let now = Date()
            guard self?.handleActivityTimerTick(now: now) == false else { return }
            self?.checkReminders()
        }
    }

    private func stopTimers() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        reminderTimer?.invalidate()
        reminderTimer = nil
        lastActivityTimerTickAt = nil
    }

    private func handleActivityTimerTick(now: Date) -> Bool {
        defer { lastActivityTimerTickAt = now }
        guard let last = lastActivityTimerTickAt else { return false }
        guard now.timeIntervalSince(last) > sleepGapThreshold else { return false }

        activePrompt?.close()
        activePrompt = nil
        sessionManager.endCurrentSession(action: .standbyStarted, now: last)
        resetReminderCounters(now: now)
        sessionManager.startNewSession(now: now)
        p2pService.refresh()
        return true
    }

    private func pauseForInactiveScreen(action: StopAction) {
        activePrompt?.close()
        activePrompt = nil
        sessionManager.endCurrentSession(action: action)
        stopTimers()
    }

    private func resumeFromInactiveScreen() {
        sessionManager.startNewSession()
        resetReminderCounters(now: Date())
        setupTimers()
        p2pService.refresh()
    }

    private func resetReminderCounters(now: Date) {
        eyeActiveSeconds = 0
        postureActiveSeconds = 0
        lastReminderSampleAt = now
    }

    private func resetReminderSampling(now: Date) {
        lastReminderSampleAt = now
    }

    private func accumulateReminderSeconds(now: Date) {
        guard let last = lastReminderSampleAt, now >= last else {
            lastReminderSampleAt = now
            return
        }

        let delta = Int(now.timeIntervalSince(last))
        guard delta > 0 else { return }
        eyeActiveSeconds += delta
        postureActiveSeconds += delta
        lastReminderSampleAt = now
    }

    private func registerLoginItemIfNeeded() {
        guard store.settings.autoStartEnabled else { return }
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func openReport() {
        if let reportWindow, reportWindow.window?.isVisible == true {
            showWindow(reportWindow)
            return
        }
        sessionManager.endCurrentSession(action: .reportOpened)
        store.recomputeDailyTotals()
        let controller = ReportWindowController(store: store) { [weak self] in
            self?.p2pService.syncNow()
        }
        controller.window?.delegate = self
        reportWindow = controller
        showWindow(controller)
    }

    @objc private func openSettings() {
        settingsWindow = SettingsWindowController(store: store, p2pService: p2pService) { [weak self] in
            self?.p2pService.refresh()
            self?.refreshStatusMenu()
        }
        showWindow(settingsWindow)
    }

    @objc private func openTracking() {
        trackingWindow = TrackingWindowController(store: store)
        showWindow(trackingWindow)
    }

    @objc private func openAbout() {
        let language = store.settings.language
        let alert = NSAlert()
        alert.messageText = appName
        let usageGuide = localizedText(
            "使用说明：\n1. 本 App 利用 P2P 同步你的不同设备，以统计你总的屏幕使用时间。请在各平台 App 中设置统一的同步码，建议不要使用本 App 默认的同步码。\n2. 本 App 不使用云端数据，所有数据都保存在你的本地设备，请放心使用。\n3. 只有你同意的设备才会同步。",
            "Usage:\n1. This app uses P2P to sync your devices and calculate your total screen time. Set the same sync code in every app, and avoid using the default code.\n2. This app does not use cloud data. All data stays on your local devices.\n3. Only devices you approve can sync.",
            language: language
        )
        alert.informativeText = "\(localizedText("开发者", "Developer", language: language))：\(developerName)\n\(localizedText("版本", "Version", language: language))：\(appVersion)\n\(localizedText("免费使用", "Free to use", language: language))\n\n\(usageGuide)"
        alert.addButton(withTitle: localizedText("确定", "OK", language: language))
        alert.runModal()
    }

    @objc private func quit() {
        sessionManager.endCurrentSession(action: .appExit)
        NSApp.terminate(nil)
    }

    private func showWindow(_ controller: NSWindowController?) {
        NSApp.activate(ignoringOtherApps: true)
        controller?.window?.center()
        controller?.showWindow(nil)
    }

    @objc private func willSleep() {
        pauseForInactiveScreen(action: .standbyStarted)
    }

    @objc private func didWake() {
        resumeFromInactiveScreen()
    }

    @objc private func screensDidSleep() {
        pauseForInactiveScreen(action: .screensaverStarted)
    }

    @objc private func screensDidWake() {
        resumeFromInactiveScreen()
    }

    @objc private func screenSaverDidStart() {
        pauseForInactiveScreen(action: .screensaverStarted)
    }

    @objc private func screenSaverDidStop() {
        resumeFromInactiveScreen()
    }

    @objc private func sessionDidResignActive() {
        pauseForInactiveScreen(action: .screenLocked)
    }

    @objc private func sessionDidBecomeActive() {
        resumeFromInactiveScreen()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == reportWindow?.window else { return }
        reportWindow = nil
        sessionManager.startNewSession()
        resetReminderCounters(now: Date())
        setupTimers()
    }

    private func checkReminders() {
        guard activePrompt == nil else { return }
        guard sessionManager.currentSession != nil else {
            sessionManager.startNewSession()
            resetReminderSampling(now: Date())
            return
        }

        checkTimeoutPlan()
        guard activePrompt == nil else { return }

        let now = Date()
        accumulateReminderSeconds(now: now)
        let eyeRestMinutes = max(1, store.settings.eyeRestIntervalMinutes ?? 3)
        let eyeRestSeconds = eyeRestMinutes * 60
        let postureRestSeconds = AppSettings.derivedPostureRestIntervalMinutes(from: eyeRestMinutes) * 60
        let postureDue = (store.settings.postureSwitchEnabled ?? true) && postureActiveSeconds >= postureRestSeconds
        if eyeActiveSeconds >= eyeRestSeconds || postureDue {
            eyeActiveSeconds = 0
            if postureDue || !(store.settings.postureSwitchEnabled ?? true) {
                postureActiveSeconds = 0
            }
            let language = store.settings.language
            let includePosture = postureDue
            showRestPrompt(
                action: includePosture ? .postureRestPrompt : .eyeRestPrompt,
                title: includePosture
                    ? localizedText("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder", language: language)
                    : localizedText("用眼休息提醒", "Eye Rest Reminder", language: language),
                message: includePosture
                    ? localizedText("请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。", "Switch between sitting and standing, then look 20 feet away to rest your eyes.", language: language)
                    : localizedText("请看 20 英尺外 20 秒。", "Look at something 20 feet away for 20 seconds.", language: language),
                seconds: includePosture ? 60 : 20
            )
        }
    }

    private func showRestPrompt(action: StopAction, title: String, message: String, seconds: Int) {
        sessionManager.endCurrentSession(action: action)
        let prompt = RestPromptWindowController(
            title: title,
            message: message,
            countdownSeconds: seconds,
            immediateClose: store.settings.meetingMode,
            language: store.settings.language
        ) { [weak self] in
            self?.activePrompt = nil
            self?.sessionManager.startNewSession()
            self?.resetReminderSampling(now: Date())
        }
        activePrompt = prompt
        prompt.show()
    }

    private func checkTimeoutPlan() {
        guard let plannedMinutes = store.settings.plannedDailyMinutes, plannedMinutes > 0 else { return }
        let today = DateTools.dateString(Date())
        let total = sessionManager.todaySecondsIncludingCurrent()
        guard total > plannedMinutes * 60 else { return }

        if store.settings.lastTimeoutPromptDate == today,
           let last = store.settings.lastTimeoutPromptAtUtc,
           Date().timeIntervalSince(last) < 25 * 60 {
            return
        }

        sessionManager.endCurrentSession(action: .timeoutPrompt)
        let language = store.settings.language
        let planText = DateTools.formatDuration(plannedMinutes * 60, language: language)
        let message = "\(localizedText("今日累计用时", "Today's total screen time", language: language))：\(DateTools.formatDuration(total, language: language))\n\(localizedText("本周每天计划", "Daily plan this week", language: language))：\(planText)\n\(localizedText("如果继续用屏，25 分钟后会再次提醒。", "If you keep using the screen, this reminder will appear again in 25 minutes.", language: language))"
        activePrompt = RestPromptWindowController(
            title: localizedText("超过计划提醒", "Daily Plan Reached", language: language),
            message: message,
            countdownSeconds: 120,
            immediateClose: store.settings.meetingMode,
            language: language
        ) { [weak self] in
            self?.activePrompt = nil
            self?.store.settings.lastTimeoutPromptAtUtc = Date()
            self?.store.settings.lastTimeoutPromptDate = today
            self?.store.saveSettings()
            self?.sessionManager.startNewSession()
            self?.resetReminderSampling(now: Date())
        }
        activePrompt?.show()
    }

    private func checkWeeklySummaryIfNeeded() {
        let calendar = Calendar.current
        guard calendar.component(.weekday, from: Date()) == 2 else { return }
        let weekId = DateTools.weekId(Date())
        let url = store.weeklySummaryURL(for: weekId)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }

        let thisWeekStart = DateTools.currentWeekStart()
        let previousWeekStart = calendar.date(byAdding: .day, value: -7, to: thisWeekStart) ?? thisWeekStart
        let previousWeekTotal = store.totalSeconds(from: previousWeekStart, to: thisWeekStart)
        let previousWeekAverage = previousWeekTotal / 7
        let defaultMinutes = store.settings.lastWeeklyPlanMinutes ?? max(1, previousWeekAverage / 60)

        let language = store.settings.language
        let alert = NSAlert()
        alert.messageText = localizedText("上周用时总结", "Previous Week Summary", language: language)
        alert.informativeText = "\(localizedText("上周总用时", "Previous week total", language: language))：\(DateTools.formatDuration(previousWeekTotal, language: language))\n\(localizedText("每天平均用时", "Daily average", language: language))：\(DateTools.formatDuration(previousWeekAverage, language: language))\n\(localizedText("请输入本周每天计划用时（分钟）。", "Enter this week's daily screen time plan in minutes.", language: language))"
        alert.addButton(withTitle: localizedText("保存", "Save", language: language))
        alert.addButton(withTitle: localizedText("稍后", "Later", language: language))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        input.integerValue = defaultMinutes
        alert.accessoryView = input

        if alert.runModal() == .alertFirstButtonReturn {
            let minutes = max(1, input.integerValue)
            store.settings.plannedDailyMinutes = minutes
            store.settings.lastWeeklyPlanMinutes = minutes
            store.saveSettings()
            let summary = WeeklySummary(
                weekId: weekId,
                plannedDailyMinutes: minutes,
                previousWeekTotalSeconds: previousWeekTotal,
                previousWeekAverageDailySeconds: previousWeekAverage,
                createdByDeviceId: store.settings.deviceId,
                createdAtUtc: Date()
            )
            store.saveWeeklySummary(summary)
        }
    }
}

func pad(_ value: String, _ width: Int) -> String {
    if value.count >= width { return String(value.prefix(width)) }
    return value + String(repeating: " ", count: width - value.count)
}

func formatNumber(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func formatPrice(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 6
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func formatWholeCurrency(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 0
    formatter.minimumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
