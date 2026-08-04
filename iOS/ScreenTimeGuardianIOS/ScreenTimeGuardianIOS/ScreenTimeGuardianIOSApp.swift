import Foundation
import CryptoKit
import Darwin
import Network
import Security
import SwiftUI
import UIKit
import zlib

#if canImport(FamilyControls)
import FamilyControls
#endif

#if canImport(DeviceActivity)
import DeviceActivity
#endif

#if canImport(_DeviceActivity_SwiftUI)
import _DeviceActivity_SwiftUI
#endif

#if canImport(UserNotifications)
import UserNotifications
#endif

#if canImport(ManagedSettings)
import ManagedSettings
#endif

private let appName = "Screen Time Guardian"
private let appVersion = "V1.0.9"
private let developerName = "TimberTrail"
private let deviceIdKeychainService = "com.timbertrail.screentimeguardian"
private let deviceIdKeychainAccount = "stable_device_id"
private let defaultPlannedDailyMinutes = 8 * 60
private let timeoutPromptRepeatIntervalSeconds: TimeInterval = 25 * 60
private let timeoutPromptCloseDelaySeconds = 2 * 60
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

#if canImport(UserNotifications)
final class ScreenTimeGuardianAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner, .list]
        let meetingMode = (ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey) as? Bool)
            ?? (UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey) as? Bool)
            ?? false
        if !meetingMode {
            options.insert(.sound)
        }
        completionHandler(options)
    }
}

@MainActor
final class NotificationPermissionModel: ObservableObject {
    @Published private var authorizationStatusRaw = -1
    @Published private var alertSettingRaw = -1
    @Published private var soundSettingRaw = -1
    @Published private var alertStyleRaw = -1
    @Published private var timeSensitiveSettingRaw = -1
    @Published var lastError: String?

    func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationStatusRaw = settings.authorizationStatus.rawValue
                self?.alertSettingRaw = settings.alertSetting.rawValue
                self?.soundSettingRaw = settings.soundSetting.rawValue
                self?.alertStyleRaw = settings.alertStyle.rawValue
                self?.timeSensitiveSettingRaw = settings.timeSensitiveSetting.rawValue
            }
        }
    }

    func request() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings])
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func authorizationText(language: String) -> String {
        switch UNAuthorizationStatus(rawValue: authorizationStatusRaw) {
        case .authorized: return localizedText("已允许", "Allowed", language: language)
        case .denied: return localizedText("已关闭", "Off", language: language)
        case .notDetermined: return localizedText("尚未请求", "Not requested", language: language)
        case .provisional: return localizedText("临时允许", "Provisional", language: language)
        case .ephemeral: return localizedText("临时会话允许", "Ephemeral", language: language)
        default: return localizedText("未知", "Unknown", language: language)
        }
    }

    func alertText(language: String) -> String {
        notificationSettingText(alertSettingRaw, language: language)
    }

    func soundText(language: String) -> String {
        notificationSettingText(soundSettingRaw, language: language)
    }

    func timeSensitiveText(language: String) -> String {
        notificationSettingText(timeSensitiveSettingRaw, language: language)
    }

    var needsInitialRequest: Bool {
        authorizationStatusRaw == UNAuthorizationStatus.notDetermined.rawValue
    }

    func alertStyleText(language: String) -> String {
        switch UNAlertStyle(rawValue: alertStyleRaw) {
        case .some(.none): return localizedText("无横幅/提醒", "No banner or alert", language: language)
        case .some(.banner): return localizedText("横幅；持续样式需在系统设置中选择", "Banner; persistent style is chosen in iOS Settings", language: language)
        case .some(.alert): return localizedText("提醒；需要用户处理", "Alert; requires user action", language: language)
        default: return localizedText("未知", "Unknown", language: language)
        }
    }

    private func notificationSettingText(_ raw: Int, language: String) -> String {
        switch UNNotificationSetting(rawValue: raw) {
        case .enabled: return localizedText("已开启", "On", language: language)
        case .disabled: return localizedText("已关闭", "Off", language: language)
        case .notSupported: return localizedText("不支持", "Not supported", language: language)
        default: return localizedText("未知", "Unknown", language: language)
        }
    }
}

private func requestInitialNotificationAuthorizationIfNeeded() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        guard settings.authorizationStatus == .notDetermined else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings]) { _, _ in }
    }
}
#endif

#if canImport(FamilyControls)
@available(iOS 16.0, *)
@MainActor
private func requestInitialScreenTimeAuthorizationIfNeeded() {
    guard AuthorizationCenter.shared.authorizationStatus == .notDetermined else { return }
    Task {
        try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
    }
}
#endif

private func localizedSyncStatus(_ value: String, language: String) -> String {
    guard language == "en" else { return value }
    var text = value
    let replacements: [(String, String)] = [
        ("P2P 未启动", "P2P has not started"),
        ("P2P 已开启，使用 Bonjour 发现局域网设备", "P2P is on, using Bonjour to discover local devices"),
        ("P2P 已关闭", "P2P is off"),
        ("P2P 监听启动失败", "P2P listener failed to start"),
        ("P2P 监听", "P2P listener"),
        ("P2P Bonjour 已就绪，等待局域网设备", "P2P Bonjour is ready, waiting for local devices"),
        ("P2P Bonjour 正在启动", "P2P Bonjour is starting"),
        ("P2P Bonjour 等待", "P2P Bonjour waiting"),
        ("P2P Bonjour 失败", "P2P Bonjour failed"),
        ("P2P Bonjour 已停止", "P2P Bonjour stopped"),
        ("P2P Bonjour 状态未知", "P2P Bonjour state unknown"),
        ("发现 STG Bonjour 服务，正在通过加密握手获取设备信息", "Found STG Bonjour service, getting device info through encrypted handshake"),
        ("发现 STG Bonjour 服务，正在通过加密握手获取设备 ID", "Found STG Bonjour service, getting device ID through encrypted handshake"),
        ("发现 STG 设备但配对码不一致", "Found STG device but pairing code does not match"),
        ("已发现 STG 设备，但配对码不一致", "Found STG device, but pairing code does not match"),
        ("尚未发现设备，请确认两端配对码一致并在同一局域网", "No devices found yet. Make sure both sides use the same pairing code and local network"),
        ("P2P 加密发送失败", "P2P encrypted send failed"),
        ("P2P 解密或合并失败", "P2P decrypt or merge failed"),
        ("P2P 载荷不是有效 Base64", "P2P payload is not valid Base64"),
        ("P2P 已同步", "P2P synced"),
        ("P2P 已连接，无新记录", "P2P connected; no new records"),
        ("本地网络权限被拒绝，请在系统设置中允许 Screen Time Guardian 访问本地网络", "Local network permission was denied. Allow Screen Time Guardian in System Settings."),
        ("配对码不一致，不能同意该设备", "Pairing code mismatch; cannot approve this device"),
        ("配对码不一致，不能同步", "Pairing code mismatch; cannot sync"),
        ("配对码不一致，不能同步", "Pairing code mismatch; cannot sync"),
        ("配对码不一致", "Pairing code mismatch"),
        ("发现已同意设备", "Found approved device"),
        ("发现待确认设备", "Found pending device"),
        ("已发现设备，但尚未同意任何同步设备", "Devices found, but no sync device has been approved"),
        ("已拒绝设备尝试同步", "Rejected device attempted to sync"),
        ("已同意设备", "Approved device"),
        ("已同意，等待重新发现", "Approved; waiting to rediscover"),
        ("已同意，等待同步", "Approved; waiting to sync"),
        ("已拒绝，未同步", "Rejected; not synced"),
        ("待确认，未同步", "Pending approval; not synced"),
        ("等待重新发现", "Waiting to rediscover"),
        ("正在同步", "Syncing"),
        ("同步完成", "Sync complete"),
        ("无新记录", "No new records"),
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
    text = text.replacingOccurrences(of: "失败", with: "failed")
    text = text.replacingOccurrences(of: "等待", with: "waiting")
    return text
}

private func stableAppleDeviceId() -> String {
    if let stored = keychainDeviceId() {
        return stored
    }
    let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
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
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    SecItemAdd(attributes as CFDictionary, nil)
}

#if canImport(_DeviceActivity_SwiftUI)
@available(iOS 16.0, *)
extension DeviceActivityReport.Context {
    static let screenTimeGuardianSummary = Self(ScreenTimeGuardianScreenTimeNames.reportContext)
}
#endif

enum StopAction: String, Codable, CaseIterable {
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

    var title: String {
        title(language: "zh")
    }

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

struct ScreenSession: Codable, Identifiable, Equatable {
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

struct DailyTotal: Codable, Identifiable {
    var id: String { "\(date)-\(deviceId ?? "all")" }
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

struct PlatformUsageSummary: Identifiable, Codable {
    var id: String { platform }
    var platform: String
    var totalSeconds: Int
    var averageDailySeconds: Int
}

struct DeviceUsageSummary: Identifiable, Codable {
    var id: String { deviceId }
    var deviceId: String
    var deviceName: String
    var platform: String
    var totalSeconds: Int
    var averageDailySeconds: Int
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

struct DeletedSession: Codable, Identifiable, Equatable {
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
    var iosScreenTimeCheckpointIntervalMinutes: Int?
    var trackingObject: String
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
        case iosScreenTimeCheckpointIntervalMinutes = "ios_screen_time_checkpoint_interval_minutes"
        case trackingObject = "tracking_object"
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
        let deviceName = UIDevice.current.name
        return AppSettings(
            language: "zh",
            postureIntervalMinutes: 6,
            postureSwitchEnabled: true,
            eyeRestIntervalMinutes: 3,
            postureRestIntervalMinutes: 6,
            iosScreenTimeCheckpointIntervalMinutes: 2,
            trackingObject: "LLM Ranking",
            p2pSyncEnabled: true,
            p2pPairingCode: AppSettings.newPairingCode(),
            p2pSyncIntervalMinutes: 5,
            trustedPeerIds: [],
            rejectedPeerIds: [],
            pairedPeers: [],
            deviceId: stableAppleDeviceId(),
            deviceName: deviceName,
            meetingMode: false,
            autoStartEnabled: false,
            plannedDailyMinutes: defaultPlannedDailyMinutes,
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
        iosScreenTimeCheckpointIntervalMinutes = min(1440, max(1, iosScreenTimeCheckpointIntervalMinutes ?? 2))
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

struct LLMRankingRow: Codable, Identifiable {
    var id: String { "\(rank)-\(llmName)" }
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

struct MessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum JsonCodec {
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

final class AppStore: ObservableObject {
    private let openSessionHeartbeatValidity: TimeInterval = 120
    let supportURL: URL
    let settingsURL: URL
    let sessionsURL: URL
    let deletedSessionsURL: URL
    let dailyTotalsURL: URL
    let identityURL: URL

    @Published var settings: AppSettings
    @Published private(set) var sessions: [ScreenSession]
    @Published private(set) var deletedSessions: [DeletedSession]
    @Published private(set) var dailyTotals: [DailyTotal]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        supportURL = base.appendingPathComponent("ScreenTimeGuardian", isDirectory: true)
        settingsURL = supportURL.appendingPathComponent("settings.json")
        sessionsURL = supportURL.appendingPathComponent("sessions.json")
        deletedSessionsURL = supportURL.appendingPathComponent("deleted_sessions.json")
        dailyTotalsURL = supportURL.appendingPathComponent("daily_totals.json")
        identityURL = supportURL.appendingPathComponent("device_id")
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        settings = AppSettings.defaults()
        sessions = []
        deletedSessions = []
        dailyTotals = []
        load()
        ensurePersistentDeviceId()
        ensureP2PSettings()
        cleanupDuplicateScreenTimeSessions()
        importScreenTimeEventSessions()
        refreshHistoricalArchives()
    }

    func load() {
        if let data = try? Data(contentsOf: settingsURL),
           let loaded = try? JsonCodec.decoder().decode(AppSettings.self, from: data) {
            settings = loaded
        } else {
            saveSettings()
        }

        if let data = try? Data(contentsOf: sessionsURL),
           let loaded = try? JsonCodec.decoder().decode([ScreenSession].self, from: data) {
            sessions = loaded
        }

        if let data = try? Data(contentsOf: deletedSessionsURL),
           let loaded = try? JsonCodec.decoder().decode([DeletedSession].self, from: data) {
            deletedSessions = loaded
        }

        if let data = try? Data(contentsOf: dailyTotalsURL),
           let loaded = try? JsonCodec.decoder().decode([DailyTotal].self, from: data) {
            dailyTotals = loaded
        }
    }

    func saveSettings() {
        settings.normalizeP2P()
        guard let data = try? JsonCodec.encoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
        UserDefaults.standard.set(settings.postureSwitchEnabled ?? true, forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(settings.postureSwitchEnabled ?? true, forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey)
        UserDefaults.standard.set(settings.meetingMode, forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(settings.meetingMode, forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey)
        UserDefaults.standard.set(settings.eyeRestIntervalMinutes ?? 3, forKey: ScreenTimeGuardianScreenTimeStorage.eyeRestIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(settings.eyeRestIntervalMinutes ?? 3, forKey: ScreenTimeGuardianScreenTimeStorage.eyeRestIntervalMinutesKey)
        UserDefaults.standard.set(AppSettings.derivedPostureRestIntervalMinutes(from: settings.eyeRestIntervalMinutes ?? 3), forKey: ScreenTimeGuardianScreenTimeStorage.postureRestIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(AppSettings.derivedPostureRestIntervalMinutes(from: settings.eyeRestIntervalMinutes ?? 3), forKey: ScreenTimeGuardianScreenTimeStorage.postureRestIntervalMinutesKey)
        UserDefaults.standard.set(settings.language, forKey: ScreenTimeGuardianScreenTimeStorage.languageKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(settings.language, forKey: ScreenTimeGuardianScreenTimeStorage.languageKey)
        UserDefaults.standard.set(settings.iosScreenTimeCheckpointIntervalMinutes ?? 2, forKey: ScreenTimeGuardianScreenTimeStorage.checkpointIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(settings.iosScreenTimeCheckpointIntervalMinutes ?? 2, forKey: ScreenTimeGuardianScreenTimeStorage.checkpointIntervalMinutesKey)
        // Sync daily plan to App Group for Extension overtime check
        let plannedMinutes = settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(plannedMinutes, forKey: "screen_time_guardian.planned_daily_minutes")
        saveKeychainDeviceId(settings.deviceId)
        try? settings.deviceId.data(using: .utf8)?.write(to: identityURL, options: .atomic)
    }

    func updateLanguage(_ language: String) {
        let normalized = language == "en" ? "en" : "zh"
        guard settings.language != normalized else { return }
        objectWillChange.send()
        settings.language = normalized
        saveSettings()
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

    func saveSessions() {
        guard let data = try? JsonCodec.encoder().encode(sessions) else { return }
        try? data.write(to: sessionsURL, options: .atomic)
    }

    func saveDeletedSessions() {
        guard let data = try? JsonCodec.encoder().encode(deletedSessions) else { return }
        try? data.write(to: deletedSessionsURL, options: .atomic)
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
                platform: currentAppleMobilePlatform(),
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

    func deleteSession(_ session: ScreenSession, now: Date = Date()) {
        let tombstone = DeletedSession(
            id: "session-\(session.id)-\(Int(now.timeIntervalSince1970))",
            sessionId: session.id,
            deviceId: session.deviceId,
            startAtUtc: session.startAtUtc,
            endAtUtc: session.endAtUtc,
            deletedByDeviceId: settings.deviceId,
            deletedAtUtc: now,
            updatedAtUtc: now
        )
        deletedSessions.append(tombstone)
        deletedSessions.sort { $0.updatedAtUtc > $1.updatedAtUtc }
        removeDeletedSessionsInMemory()
        saveDeletedSessions()
        saveSessions()
        recomputeDailyTotals()
        recomputeAppTotalFromSessions()
    }

    /// Recompute app_total_recorded_seconds from today's sessions only.
    /// Called after deleting a session so the alignment accumulator stays in sync.
    /// Uses the same date as the report to keep totals consistent.
    func recomputeAppTotalFromSessions() {
        let today = DateTools.dateString(Date())
        let todayTotal = dailyTotals[today]?.totalSeconds ?? 0
        let defaults = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()
        defaults?.set(todayTotal, forKey: "screen_time_guardian.app_total_recorded_seconds")
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

    var systemScreenTimeRecordingEnabled: Bool {
        let shared = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey) as? Bool
        let local = UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey) as? Bool
        return shared ?? local ?? true
    }

    var hasSavedScreenTimeSelection: Bool {
        #if canImport(FamilyControls)
        let shared = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.data(forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
        let local = UserDefaults.standard.data(forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
        guard let data = shared ?? local,
              let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return false
        }
        return !selection.applicationTokens.isEmpty ||
            !selection.categoryTokens.isEmpty ||
            !selection.webDomainTokens.isEmpty
        #else
        return false
        #endif
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

    @discardableResult
    func importScreenTimeEventSessions(now: Date = Date()) -> [ScreenSession] {
        guard hasSavedScreenTimeSelection else { return [] }
        guard let url = ScreenTimeGuardianScreenTimeStorage.eventLogURL(),
              let data = try? Data(contentsOf: url),
              let decodedRecords = try? ScreenTimeGuardianScreenTimeStorage.eventDecoder().decode([ScreenTimeGuardianScreenTimeEvent].self, from: data) else {
            return []
        }

        let records = deduplicatedScreenTimeEventRecords(decodedRecords)
        var changed = false
        var importedReminderSessions: [ScreenSession] = []
        for record in records {
            let sessionId = "ios-screen-time-\(stableScreenTimeEventId(for: record))"
            guard !sessions.contains(where: { $0.id == sessionId }) else { continue }

            let thresholdSeconds = max(1, record.thresholdSeconds)
            let durationSeconds = max(1, min(record.segmentDurationSeconds ?? min(thresholdSeconds, 20 * 60), thresholdSeconds))
            let end = record.reachedAtUtc
            let start = end.addingTimeInterval(TimeInterval(-durationSeconds))
            let action: StopAction
            switch record.eventName {
            case ScreenTimeGuardianScreenTimeNames.postureEvent:
                action = .postureRestPrompt
            case ScreenTimeGuardianScreenTimeNames.eyeRestEvent:
                action = .eyeRestPrompt
            default:
                action = .screenTimeCheckpoint
            }
            let session = ScreenSession(
                id: sessionId,
                deviceId: settings.deviceId,
                deviceName: settings.deviceName,
                platform: currentAppleMobilePlatform(),
                measurementScope: .iosScreenTimeSelected,
                startAtUtc: start,
                startTimezone: TimeZone.current.identifier,
                endAtUtc: end,
                endTimezone: TimeZone.current.identifier,
                durationSeconds: durationSeconds,
                stopAction: action,
                heartbeatAtUtc: end,
                createdAtUtc: record.createdAtUtc,
                updatedAtUtc: now,
                revision: 1,
                syncStatus: "local"
            )
            guard !isDeleted(session) else { continue }
            sessions.append(session)
            if action == .eyeRestPrompt || action == .postureRestPrompt {
                importedReminderSessions.append(session)
            }
            changed = true
        }

        guard changed else { return [] }
        _ = removeDuplicateScreenTimeSessionsInMemory()
        sessions.sort { $0.startAtUtc < $1.startAtUtc }
        saveSessions()
        recomputeDailyTotals()
        return importedReminderSessions
    }

    private func deduplicatedScreenTimeEventRecords(_ records: [ScreenTimeGuardianScreenTimeEvent]) -> [ScreenTimeGuardianScreenTimeEvent] {
        var bestById: [String: ScreenTimeGuardianScreenTimeEvent] = [:]
        for record in records {
            let stableId = stableScreenTimeEventId(for: record)
            if let existing = bestById[stableId] {
                if record.createdAtUtc < existing.createdAtUtc ||
                    (record.createdAtUtc == existing.createdAtUtc && record.reachedAtUtc < existing.reachedAtUtc) {
                    bestById[stableId] = record
                }
            } else {
                bestById[stableId] = record
            }
        }
        return bestById.values.sorted {
            if $0.reachedAtUtc == $1.reachedAtUtc {
                return $0.thresholdSeconds < $1.thresholdSeconds
            }
            return $0.reachedAtUtc < $1.reachedAtUtc
        }
    }

    private func stableScreenTimeEventId(for record: ScreenTimeGuardianScreenTimeEvent) -> String {
        "\(record.eventName)-\(DateTools.dateString(record.reachedAtUtc))-\(max(1, record.thresholdSeconds))"
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

    func recomputeDailyTotals() {
        var totals: [String: (seconds: Int, count: Int, deviceId: String?)] = [:]
        for session in sessions {
            guard let end = session.endAtUtc, end > session.startAtUtc else { continue }
            for segment in splitSecondsByLocalDate(start: session.startAtUtc, end: end) {
                let allKey = "\(segment.date)|all"
                let deviceKey = "\(segment.date)|\(session.deviceId)"
                totals[allKey, default: (0, 0, nil)].seconds += segment.seconds
                totals[allKey, default: (0, 0, nil)].count += 1
                totals[deviceKey, default: (0, 0, session.deviceId)].seconds += segment.seconds
                totals[deviceKey, default: (0, 0, session.deviceId)].count += 1
            }
        }

        dailyTotals = totals.map { key, value in
            DailyTotal(
                date: String(key.split(separator: "|", maxSplits: 1).first ?? ""),
                reportTimezone: TimeZone.current.identifier,
                deviceId: value.deviceId,
                durationSeconds: value.seconds,
                sourceSessionCount: value.count,
                updatedAtUtc: Date()
            )
        }.sorted { $0.date < $1.date }
        saveDailyTotals()
    }

    func sessionsForDate(_ date: Date) -> [ScreenSession] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        return sessions.filter { session in
            let end = effectiveEnd(for: session)
            return session.startAtUtc < dayEnd && end > dayStart
        }.sorted { $0.startAtUtc < $1.startAtUtc }
    }

    func totalSecondsForDayIncludingOpen(_ date: Date, now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        return totalSecondsIncludingOpen(from: dayStart, to: dayEnd, now: now)
    }

    func totalSecondsIncludingOpen(from start: Date, to end: Date, now: Date = Date()) -> Int {
        unionSeconds(for: sessions, from: start, to: end, now: now)
    }

    func platformUsageSummaries(from start: Date, to end: Date, dayCount: Int, now: Date = Date()) -> [PlatformUsageSummary] {
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
        let divisor = max(1, dayCount)
        let grouped = Dictionary(grouping: sessions) { session in
            let cleaned = session.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                return "\(normalizedPlatform(session.platform)):\(session.deviceName)"
            }
            return cleaned
        }

        return grouped.map { key, sessions in
            let latest = sessions.max { $0.updatedAtUtc < $1.updatedAtUtc } ?? sessions[0]
            let seconds = unionSeconds(for: sessions, from: start, to: end, now: now)
            return DeviceUsageSummary(
                deviceId: key,
                deviceName: latest.deviceName.isEmpty ? key : latest.deviceName,
                platform: normalizedPlatform(latest.platform),
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
        let url = trackingCacheURL(for: DateTools.weekId(Date()))
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .failure(MessageError(message: "本周缓存不存在，将从 OpenRouter 获取。"))
        }
        do {
            let data = try Data(contentsOf: url)
            return .success(try JsonCodec.decoder().decode(LLMRankingCache.self, from: data))
        } catch {
            return .failure(MessageError(message: "缓存读取失败：\(error.localizedDescription)"))
        }
    }

    func saveLLMRankingCache(_ cache: LLMRankingCache) throws {
        let url = trackingCacheURL(for: cache.weekId)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JsonCodec.encoder().encode(cache).write(to: url, options: .atomic)
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

struct P2PDiscoveredPeer: Identifiable {
    var id: String { deviceId }
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

final class P2PSyncService: ObservableObject {
    private static let serviceType = "_stg-sync._tcp"
    private static let maxFrameBytes = 16 * 1024 * 1024

    @Published private(set) var status = "P2P 未启动"
    @Published private(set) var peers: [P2PDiscoveredPeer] = []

    private let store: AppStore
    private let queue = DispatchQueue(label: "com.timbertrail.screentimeguardian.ios.p2p")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discoveredEndpoints: [String: NWEndpoint] = [:]
    private var discoveredPeers: [String: P2PDiscoveredPeer] = [:]
    private var lastSyncAttemptByEndpoint: [String: Date] = [:]
    private var syncTimer: DispatchSourceTimer?
    private var tcpPort: Int = 0
    private var retainedConnections: [NWConnection] = []

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
        setStatus("P2P 已开启，使用 Bonjour 发现局域网设备")
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
                "platform": currentAppleMobilePlatform(),
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
            let body = try encryptedEnvelopeData(for: currentSnapshot(since: since), peerCapabilities: peerCapabilities)
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
            platform: currentAppleMobilePlatform(),
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

    private func setStatus(_ value: String) {
        let peers = sortedPeers()
        DispatchQueue.main.async {
            self.status = value
            self.peers = peers
        }
    }

    private func notifyChanged() {
        let peers = sortedPeers()
        DispatchQueue.main.async {
            self.peers = peers
        }
    }

    private func sortedPeers() -> [P2PDiscoveredPeer] {
        discoveredPeers.values.sorted {
            if $0.lastSeenAt == $1.lastSeenAt {
                return $0.deviceName < $1.deviceName
            }
            return $0.lastSeenAt > $1.lastSeenAt
        }
    }
}

final class SessionTracker: ObservableObject {
    @Published var currentSessionId: String?
    @Published var activePrompt: RestPrompt?

    private let store: AppStore
    private var heartbeatTimer: Timer?
    private var reminderTimer: Timer?
    private var lastReminderSampleAt: Date?
    private var eyeActiveSeconds = 0
    private var postureActiveSeconds = 0
    private var promptedScreenTimeSessionIds = Set<String>()
    private let screenTimePromptGraceInterval: TimeInterval = 10 * 60

    init(store: AppStore) {
        self.store = store
        store.recoverOpenSessions()
        resetReminderCounters(now: Date())
        startTimers()
    }

    deinit {
        heartbeatTimer?.invalidate()
        reminderTimer?.invalidate()
    }

    var currentSession: ScreenSession? {
        guard let currentSessionId else { return nil }
        return store.sessions.first { $0.id == currentSessionId }
    }

    func appBecameActive() {
        let importedReminderSessions = store.importScreenTimeEventSessions()
        showPromptForScreenTimeReminderIfNeeded(from: importedReminderSessions, now: Date())
        if store.systemScreenTimeRecordingEnabled {
            endCurrentSession(action: .appBackgrounded)
        } else {
            startNewSession()
        }
        resetReminderCounters(now: Date())
        checkWeeklySummaryHint()
    }

    func appWentInactive() {
        endCurrentSession(action: .appBackgrounded)
    }

    func startNewSession(now: Date = Date()) {
        if store.systemScreenTimeRecordingEnabled {
            store.closeOpenSessionsForCurrentDevice(action: .appBackgrounded, now: now)
            currentSessionId = nil
            return
        }
        if let currentSession {
            store.closeOpenSessionsForCurrentDevice(except: currentSession.id, action: .crashRecovered, now: now)
            return
        }
        store.closeOpenSessionsForCurrentDevice(action: .crashRecovered, now: now)
        let session = ScreenSession(
            id: UUID().uuidString,
            deviceId: store.settings.deviceId,
            deviceName: store.settings.deviceName,
            platform: currentAppleMobilePlatform(),
            measurementScope: .appForegroundOnly,
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
        guard let id, var session = store.sessions.first(where: { $0.id == id }), session.endAtUtc == nil else {
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

    func heartbeat() {
        guard let id = currentSessionId,
              var session = store.sessions.first(where: { $0.id == id }) else { return }
        session.heartbeatAtUtc = Date()
        session.updatedAtUtc = Date()
        store.upsertSession(session)
    }

    func openReport() {
        endCurrentSession(action: .reportOpened)
    }

    func closeReport() {
        startNewSession()
    }

    func closePrompt() {
        activePrompt = nil
        startNewSession()
        resetReminderSampling(now: Date())
    }

    private func startTimers() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        reminderTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkReminders() }
        }
    }

    private func checkReminders() {
        guard activePrompt == nil else { return }
        let now = Date()
        if store.systemScreenTimeRecordingEnabled {
            let importedReminderSessions = store.importScreenTimeEventSessions(now: now)
            if showPromptForScreenTimeReminderIfNeeded(from: importedReminderSessions, now: now) {
                return
            }
            if shouldShowTimeoutPrompt(now: now) {
                showTimeoutPrompt(now: now)
            }
            return
        }
        guard currentSession != nil else {
            resetReminderSampling(now: Date())
            return
        }

        let language = store.settings.language
        accumulateReminderSeconds(now: now)

        if shouldShowTimeoutPrompt(now: now) {
            showTimeoutPrompt(now: now)
            return
        }

        let eyeRestMinutes = max(1, store.settings.eyeRestIntervalMinutes ?? 3)
        let eyeRestSeconds = eyeRestMinutes * 60
        let postureRestSeconds = AppSettings.derivedPostureRestIntervalMinutes(from: eyeRestMinutes) * 60
        let postureDue = (store.settings.postureSwitchEnabled ?? true) && postureActiveSeconds >= postureRestSeconds
        if eyeActiveSeconds >= eyeRestSeconds || postureDue {
            eyeActiveSeconds = 0
            if postureDue {
                postureActiveSeconds = 0
            }
            let includePosture = postureDue
            endCurrentSession(action: includePosture ? .postureRestPrompt : .eyeRestPrompt)
            activePrompt = RestPrompt(
                title: includePosture
                    ? localizedText("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder", language: language)
                    : localizedText("用眼休息提醒", "Eye Rest Reminder", language: language),
                message: includePosture
                    ? localizedText("请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。", "Switch between sitting and standing, then look 20 feet away to rest your eyes.", language: language)
                    : localizedText("请看 20 英尺外 20 秒。", "Look at something 20 feet away for 20 seconds.", language: language),
                countdownSeconds: includePosture ? 60 : 20,
                canCloseImmediately: store.settings.meetingMode
            )
        }
    }

    @discardableResult
    private func showPromptForScreenTimeReminderIfNeeded(from sessions: [ScreenSession], now: Date) -> Bool {
        guard activePrompt == nil else { return false }
        guard let session = sessions
            .filter({ session in
                guard let action = session.stopAction,
                      action == .eyeRestPrompt || action == .postureRestPrompt,
                      !promptedScreenTimeSessionIds.contains(session.id) else {
                    return false
                }
                let reachedAt = session.endAtUtc ?? session.createdAtUtc
                return abs(now.timeIntervalSince(reachedAt)) <= screenTimePromptGraceInterval
            })
            .max(by: { ($0.endAtUtc ?? $0.createdAtUtc) < ($1.endAtUtc ?? $1.createdAtUtc) }) else {
            return false
        }

        promptedScreenTimeSessionIds.insert(session.id)
        let language = store.settings.language
        let includePosture = session.stopAction == .postureRestPrompt
        activePrompt = RestPrompt(
            title: includePosture
                ? localizedText("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder", language: language)
                : localizedText("用眼休息提醒", "Eye Rest Reminder", language: language),
            message: includePosture
                ? localizedText("请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。", "Switch between sitting and standing, then look 20 feet away to rest your eyes.", language: language)
                : localizedText("请看 20 英尺外 20 秒。", "Look at something 20 feet away for 20 seconds.", language: language),
            countdownSeconds: includePosture ? 60 : 20,
            canCloseImmediately: store.settings.meetingMode
        )
        return true
    }

    private func showTimeoutPrompt(now: Date) {
        let language = store.settings.language
        let plannedMinutes = store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes
        let planText = DateTools.formatDuration(plannedMinutes * 60, language: language)
        store.settings.lastTimeoutPromptAtUtc = now
        store.settings.lastTimeoutPromptDate = DateTools.dateString(now)
        store.saveSettings()
        endCurrentSession(action: .timeoutPrompt)
        activePrompt = RestPrompt(
            title: localizedText("超过计划提醒", "Daily Plan Reached", language: language),
            message: "\(localizedText("今天的屏幕用时已超过计划", "Today's screen time has passed your plan", language: language))：\(planText)。\(localizedText("请休息一下，保护眼睛和身体状态。", "Take a break to protect your eyes and posture.", language: language))",
            countdownSeconds: timeoutPromptCloseDelaySeconds,
            canCloseImmediately: store.settings.meetingMode
        )
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

    private func shouldShowTimeoutPrompt(now: Date) -> Bool {
        let plannedMinutes = store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes
        guard plannedMinutes > 0 else { return false }
        let totalSeconds = store.totalSecondsForDayIncludingOpen(now, now: now)
        guard totalSeconds >= plannedMinutes * 60 else { return false }

        let today = DateTools.dateString(now)
        if store.settings.lastTimeoutPromptDate != today {
            return true
        }

        guard let lastPrompt = store.settings.lastTimeoutPromptAtUtc else {
            return true
        }
        return now.timeIntervalSince(lastPrompt) >= timeoutPromptRepeatIntervalSeconds
    }

    private func checkWeeklySummaryHint() {
        let weekday = Calendar.current.component(.weekday, from: Date())
        guard weekday == 2 else { return }
        if store.settings.plannedDailyMinutes == nil {
            store.settings.plannedDailyMinutes = defaultPlannedDailyMinutes
            store.saveSettings()
        }
    }
}

struct RestPrompt: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var countdownSeconds: Int
    var canCloseImmediately: Bool
    var createdAt: Date = Date()

    var canCloseAt: Date {
        createdAt.addingTimeInterval(TimeInterval(max(0, countdownSeconds)))
    }
}

final class OpenRouterClient {
    private let baseURL = URL(string: "https://openrouter.ai")!

    func fetchWeeklyPromptTokenTop20() async throws -> LLMRankingCache {
        let rankingEntries = try await fetchRankingEntries()
            .filter { !$0.permaslug.isEmpty && $0.promptTokens > 0 }
            .sorted { $0.promptTokens > $1.promptTokens }
            .prefix(20)

        var rows: [LLMRankingRow] = []
        var rank = 1
        for entry in rankingEntries {
            let pricing = (try? await fetchEffectivePricing(permaslug: entry.permaslug, variant: entry.variant))
                ?? OpenRouterEffectivePricing(weightedInputPricePerMillion: 0, weightedOutputPricePerMillion: 0)
            let revenue = entry.promptTokens / 1_000_000 * pricing.weightedInputPricePerMillion
                + entry.outputTokens / 1_000_000 * pricing.weightedOutputPricePerMillion
            rows.append(
                LLMRankingRow(
                    rank: rank,
                    llmName: entry.permaslug,
                    promptTokens: entry.promptTokens,
                    outputTokens: entry.outputTokens,
                    weightedAverageInputPrice: pricing.weightedInputPricePerMillion,
                    weightedAverageOutputPrice: pricing.weightedOutputPricePerMillion,
                    weeklyRevenue: revenue
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

    private func fetchRankingEntries() async throws -> [OpenRouterRankingEntry] {
        let url = URL(string: "/api/frontend/v1/rankings/models?view=week", relativeTo: baseURL)!.absoluteURL
        let json = try await fetchJSON(url: url)
        guard let root = json as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            throw MessageError(message: "OpenRouter rankings 返回格式缺少 data")
        }
        let entries = data.compactMap { row -> OpenRouterRankingEntry? in
            let permaslug = dynamicString(row["model_permaslug"])
            guard !permaslug.isEmpty else { return nil }
            return OpenRouterRankingEntry(
                permaslug: permaslug,
                variant: dynamicString(row["variant"]).isEmpty ? "standard" : dynamicString(row["variant"]),
                promptTokens: dynamicNumber(row["total_prompt_tokens"]),
                outputTokens: dynamicNumber(row["total_completion_tokens"])
            )
        }
        guard !entries.isEmpty else {
            throw MessageError(message: "OpenRouter rankings 没有可用数据")
        }
        return entries
    }

    private func fetchEffectivePricing(permaslug: String, variant: String) async throws -> OpenRouterEffectivePricing {
        var components = URLComponents(url: URL(string: "/api/frontend/v1/stats/effective-pricing", relativeTo: baseURL)!.absoluteURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "permaslug", value: permaslug),
            URLQueryItem(name: "variant", value: variant)
        ]
        guard let url = components.url else {
            throw MessageError(message: "无法生成 OpenRouter pricing URL")
        }
        let json = try await fetchJSON(url: url)
        guard let root = json as? [String: Any],
              let data = root["data"] as? [String: Any] else {
            throw MessageError(message: "OpenRouter pricing 返回格式缺少 data")
        }
        return OpenRouterEffectivePricing(
            weightedInputPricePerMillion: dynamicNumber(data["weightedInputPrice"]),
            weightedOutputPricePerMillion: dynamicNumber(data["weightedOutputPrice"])
        )
    }

    private func fetchJSON(url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ScreenTimeGuardianIOS/1.0.9", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MessageError(message: "OpenRouter 请求失败：HTTP \(http.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}

@main
struct ScreenTimeGuardianIOSApp: App {
    #if canImport(UserNotifications)
    @UIApplicationDelegateAdaptor(ScreenTimeGuardianAppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store: AppStore
    @StateObject private var tracker: SessionTracker
    @StateObject private var p2pService: P2PSyncService

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _tracker = StateObject(wrappedValue: SessionTracker(store: store))
        _p2pService = StateObject(wrappedValue: P2PSyncService(store: store))
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .environmentObject(tracker)
                .environmentObject(p2pService)
                .onAppear {
                    p2pService.refresh()
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        tracker.appBecameActive()
                        p2pService.refresh()
                    case .inactive, .background:
                        tracker.appWentInactive()
                        p2pService.stop()
                    @unknown default:
                        break
                    }
                }
        }
    }
}

enum HomeRoute: String, Identifiable {
    case report
    case settings
    case tracking
    case about

    var id: String { rawValue }
}

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var tracker: SessionTracker
    @EnvironmentObject private var p2pService: P2PSyncService
    @State private var route: HomeRoute?
    @State private var reportWasOpen = false

    var body: some View {
        let language = store.settings.language
        let now = Date()
        let todaySeconds = store.totalSecondsForDayIncludingOpen(now, now: now)
        let plannedSeconds = max(60, (store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes) * 60)
        let weekly = store.previousWeekUsageSummary(now: now)
        let topPlatform = weekly.platforms.first.map { platformTitle($0.platform) } ?? localizedText("暂无", "None", language: language)
        let approvedDeviceIds = Set(
            (store.settings.trustedPeerIds ?? []) +
                p2pService.peers
                .filter { store.trustStatus(for: $0.deviceId) == "已同意" }
                .map(\.deviceId)
        )
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HomeHeroCard(
                        label: localizedText("今日屏幕用时", "Today", language: language),
                        value: DateTools.formatDuration(todaySeconds, language: language),
                        plan: "\(localizedText("计划", "Plan", language: language)) \(DateTools.formatDuration(plannedSeconds, language: language))",
                        progress: Double(todaySeconds) / Double(plannedSeconds),
                        meta: "\(approvedDeviceIds.count) \(localizedText("台已同意设备", "approved devices", language: language)) · \(localizedSyncStatus(p2pService.status, language: language))"
                    )

                    Button {
                        store.saveSettings()
                        p2pService.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            p2pService.syncNow()
                        }
                    } label: {
                        Text(localizedText("立即同步", "Sync Now", language: language))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    VStack(spacing: 0) {
                        HomeActionRow(
                            icon: "doc.text",
                            title: localizedText("报告", "Report", language: language),
                            subtitle: localizedText("查看日报、多日报和设备明细", "Daily, multi-day, and device details", language: language)
                        ) {
                            reportWasOpen = true
                            tracker.openReport()
                            route = .report
                        }
                        Divider().padding(.leading, 56)
                        HomeActionRow(
                            icon: "gearshape",
                            title: localizedText("设置", "Settings", language: language),
                            subtitle: localizedText("同步码、提醒和权限", "Sync code, reminders, and permissions", language: language)
                        ) { route = .settings }
                        Divider().padding(.leading, 56)
                        HomeActionRow(
                            icon: "chart.line.uptrend.xyaxis",
                            title: localizedText("跟踪", "Tracking", language: language),
                            subtitle: "LLM Ranking"
                        ) { route = .tracking }
                        Divider().padding(.leading, 56)
                        HomeActionRow(
                            icon: "info.circle",
                            title: localizedText("关于", "About", language: language),
                            subtitle: localizedText("版本、说明和隐私", "Version, usage, and privacy", language: language)
                        ) { route = .about }
                    }
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    HomeSummaryCard(
                        title: localizedText("上周摘要", "Previous Week", language: language),
                        rows: [
                            (localizedText("平均每天", "Daily average", language: language), DateTools.formatDuration(weekly.averageDailySeconds, language: language)),
                            (localizedText("总用时", "Total", language: language), DateTools.formatDuration(weekly.totalSeconds, language: language)),
                            (localizedText("最多平台", "Top platform", language: language), topPlatform)
                        ]
                    )

                    HomeSummaryCard(
                        title: localizedText("状态", "Status", language: language),
                        rows: [
                            ("P2P \(localizedText("状态", "Status", language: language))", localizedSyncStatus(p2pService.status, language: language)),
                            (localizedText("设备名称", "Device Name", language: language), store.settings.deviceName),
                            (localizedText("日期", "Date", language: language), DateTools.dateString(now))
                        ]
                    )
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(appName)
            .sheet(item: $route, onDismiss: {
                if reportWasOpen {
                    reportWasOpen = false
                    tracker.closeReport()
                }
            }) { route in
                switch route {
                case .report:
                    ReportView()
                case .settings:
                    SettingsView()
                case .tracking:
                    TrackingView()
                case .about:
                    AboutView()
                }
            }
            .overlay {
                if let prompt = tracker.activePrompt {
                    RestPromptView(prompt: prompt) {
                        tracker.closePrompt()
                    }
                }
            }
            .task {
                #if canImport(UserNotifications)
                requestInitialNotificationAuthorizationIfNeeded()
                #endif
                #if canImport(FamilyControls)
                if #available(iOS 16.0, *) {
                    requestInitialScreenTimeAuthorizationIfNeeded()
                }
                #endif
            }
        }
    }
}

struct HomeHeroCard: View {
    var label: String
    var value: String
    var plan: String
    var progress: Double
    var meta: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Spacer()
                Text(plan)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            ProgressView(value: min(max(progress, 0), 1))
                .tint(.blue)
            Text(meta)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct HomeActionRow: View {
    var icon: String
    var title: String
    var subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 30, height: 30)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

struct HomeSummaryCard: View {
    var title: String
    var rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0)
                    Spacer()
                    Text(row.1)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.trailing)
                }
                .font(.body)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ReportView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var source = 0
    @State private var date = Date()
    @State private var startDate = DateTools.currentWeekStart()
    @State private var endDate = Date()

    var body: some View {
        let language = store.settings.language
        NavigationStack {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(localizedText("数据来源", "Data Source", language: language), selection: $source) {
                        Text(localizedText("本应用记录", "App Records", language: language)).tag(0)
                        Text(localizedText("系统屏幕时间", "System Screen Time", language: language)).tag(1)
                    }
                    .pickerStyle(.segmented)

                    Picker(localizedText("报告类型", "Report Type", language: language), selection: $mode) {
                        Text(localizedText("日报", "Daily", language: language)).tag(0)
                        Text(localizedText("多日报", "Multi-Day", language: language)).tag(1)
                    }
                    .pickerStyle(.segmented)

                    if source == 0 {
                        if mode == 0 {
                            DatePicker(localizedText("日期", "Date", language: language), selection: $date, displayedComponents: .date)
                            DailyReportContent(date: date)
                        } else {
                            DatePicker(localizedText("开始", "Start", language: language), selection: $startDate, displayedComponents: .date)
                            DatePicker(localizedText("结束", "End", language: language), selection: $endDate, displayedComponents: .date)
                            MultiDayReportContent(startDate: startDate, endDate: endDate)
                        }
                    } else {
                        if mode == 0 {
                            DatePicker(localizedText("日期", "Date", language: language), selection: $date, displayedComponents: .date)
                            SystemScreenTimeReportContent(startDate: date, endDate: date)
                        } else {
                            DatePicker(localizedText("开始", "Start", language: language), selection: $startDate, displayedComponents: .date)
                            DatePicker(localizedText("结束", "End", language: language), selection: $endDate, displayedComponents: .date)
                            SystemScreenTimeReportContent(startDate: startDate, endDate: endDate)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(localizedText("报告", "Report", language: language))
            .onAppear {
                store.closeExpiredOpenSessions()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedText("关闭", "Close", language: language)) { dismiss() }
                }
            }
        }
    }
}

struct DailyReportContent: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var p2pService: P2PSyncService
    @State private var showingClearConfirmation = false
    @State private var clearResultText: String?
    var date: Date

    var body: some View {
        let language = store.settings.language
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let total = store.totalSecondsForDayIncludingOpen(date)
        let sessions = store.sessionsForDate(date)
        VStack(alignment: .leading, spacing: 10) {
            Text("\(localizedText("去重总用时", "Deduplicated Total", language: language))：\(DateTools.formatDuration(total, language: language))")
                .font(.headline)
            Button(role: .destructive) {
                showingClearConfirmation = true
            } label: {
                Label(localizedText("清除当日记录", "Clear Day Records", language: language), systemImage: "trash")
            }
            if let clearResultText {
                Text(clearResultText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            DeviceUsageSummaryTable(startDate: dayStart, endDate: dayEnd, dayCount: 1)
            WeeklyPlatformSummaryView()
            ReportSection(title: localizedText("明细", "Details", language: language)) {
                if sessions.isEmpty {
                    Text(localizedText("暂无记录", "No records", language: language))
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ReportTable(
                        headers: [
                            localizedText("开始", "Start", language: language),
                            localizedText("结束", "End", language: language),
                            localizedText("时长", "Duration", language: language),
                            localizedText("停止动作", "Stop Action", language: language),
                            localizedText("平台", "Platform", language: language),
                            localizedText("设备", "Device", language: language),
                            localizedText("范围", "Scope", language: language)
                        ],
                        rows: sessions.map { session in
                            let clippedStart = max(session.startAtUtc, dayStart)
                            let clippedEnd = min(store.effectiveEnd(for: session), dayEnd)
                            return [
                                DateTools.dateTimeString(clippedStart),
                                store.isLocalOpenSession(session) ? localizedText("进行中", "In progress", language: language) : DateTools.dateTimeString(clippedEnd),
                                DateTools.formatDuration(effectiveDuration(session, dayStart: dayStart, dayEnd: dayEnd), language: language),
                                session.stopAction?.title(language: language) ?? localizedText("进行中", "In progress", language: language),
                                platformTitle(session.platform),
                                session.deviceName,
                                session.measurementScope.rawValue
                            ]
                        },
                        minWidth: 960
                    )
                    // Swipe-to-delete for individual sessions
                    VStack(spacing: 0) {
                        ForEach(sessions, id: \.id) { session in
                            let clippedStart = max(session.startAtUtc, dayStart)
                            let duration = effectiveDuration(session, dayStart: dayStart, dayEnd: dayEnd)
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(DateTools.dateTimeString(clippedStart)) · \(DateTools.formatDuration(duration, language: language))")
                                        .font(.caption)
                                    Text("\(platformTitle(session.platform)) · \(session.deviceName)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    store.deleteSession(session)
                                    p2pService.syncNow()
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            Divider()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator), lineWidth: 0.5))
                }
            }
        }
        .onAppear {
            store.closeExpiredOpenSessions()
        }
        .confirmationDialog(
            localizedText("清除当日记录？", "Clear this day's records?", language: language),
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(localizedText("清除", "Clear", language: language), role: .destructive) {
                let removed = store.clearSessions(for: date)
                p2pService.syncNow()
                clearResultText = "\(localizedText("已清除记录", "Cleared records", language: language))：\(removed)"
            }
            Button(localizedText("取消", "Cancel", language: language), role: .cancel) {}
        } message: {
            Text(localizedText(
                "将清除所选日期已记录的屏幕用时，并通过 P2P 同步删除到已同意设备。清除后新产生的记录会继续保存。",
                "This clears recorded screen time for the selected date and syncs the deletion to approved devices. New records after clearing will continue to be saved.",
                language: language
            ))
        }
    }

    private func effectiveDuration(_ session: ScreenSession, dayStart: Date, dayEnd: Date) -> Int {
        let end = min(store.effectiveEnd(for: session), dayEnd)
        let start = max(session.startAtUtc, dayStart)
        return max(0, Int(end.timeIntervalSince(start)))
    }
}

struct MultiDayReportContent: View {
    @EnvironmentObject private var store: AppStore
    var startDate: Date
    var endDate: Date

    var body: some View {
        let language = store.settings.language
        let rows = dailyRows()
        let total = rows.reduce(0) { $0 + $1.seconds }
        let average = rows.isEmpty ? 0 : total / rows.count
        let calendar = Calendar.current
        let rangeStart = calendar.startOfDay(for: min(startDate, endDate))
        let rangeEndDate = calendar.startOfDay(for: max(startDate, endDate))
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: rangeEndDate) ?? rangeEndDate
        VStack(alignment: .leading, spacing: 10) {
            Text("\(localizedText("去重总用时", "Deduplicated Total", language: language))：\(DateTools.formatDuration(total, language: language))")
                .font(.headline)
            Text("\(localizedText("每天平均", "Daily Average", language: language))：\(DateTools.formatDuration(average, language: language))")
            DeviceUsageSummaryTable(startDate: rangeStart, endDate: rangeEnd, dayCount: max(1, rows.count))
            WeeklyPlatformSummaryView()
            ReportSection(title: localizedText("每日汇总", "Daily Summary", language: language)) {
                ReportTable(
                    headers: [
                        localizedText("日期", "Date", language: language),
                        localizedText("去重总用时", "Deduplicated Total", language: language)
                    ],
                    rows: rows.map { [$0.dateString, DateTools.formatDuration($0.seconds, language: language)] },
                    minWidth: 360
                )
            }
        }
    }

    private func dailyRows() -> [(dateString: String, seconds: Int)] {
        let calendar = Calendar.current
        var current = calendar.startOfDay(for: min(startDate, endDate))
        let end = calendar.startOfDay(for: max(startDate, endDate))
        var rows: [(String, Int)] = []
        while current <= end {
            rows.append((DateTools.dateString(current), store.totalSecondsForDayIncludingOpen(current)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return rows
    }
}

struct WeeklyPlatformSummaryView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let language = store.settings.language
        let weekly = store.previousWeekUsageSummary()
        ReportSection(title: localizedText("上周各平台统计", "Previous Week by Platform", language: language)) {
            ReportTable(
                headers: [
                    localizedText("平台", "Platform", language: language),
                    localizedText("上周总计", "Weekly Total", language: language),
                    localizedText("平均每天", "Daily Average", language: language)
                ],
                rows: [[localizedText("全部平台去重", "All Platforms Deduplicated", language: language), DateTools.formatDuration(weekly.totalSeconds, language: language), DateTools.formatDuration(weekly.averageDailySeconds, language: language)]] + weekly.platforms.map {
                    [platformTitle($0.platform), DateTools.formatDuration($0.totalSeconds, language: language), DateTools.formatDuration($0.averageDailySeconds, language: language)]
                },
                minWidth: 520
            )
        }
    }
}

struct DeviceUsageSummaryTable: View {
    @EnvironmentObject private var store: AppStore
    var startDate: Date
    var endDate: Date
    var dayCount: Int

    var body: some View {
        let language = store.settings.language
        let rows = store.deviceUsageSummaries(from: startDate, to: endDate, dayCount: dayCount)
        ReportSection(title: localizedText("本报告范围各设备用时", "Device Usage in This Report", language: language)) {
            ReportTable(
                headers: [
                    localizedText("设备", "Device", language: language),
                    localizedText("平台", "Platform", language: language),
                    localizedText("总用时", "Total", language: language),
                    localizedText("平均每天", "Daily Average", language: language)
                ],
                rows: rows.map {
                    [$0.deviceName, platformTitle($0.platform), DateTools.formatDuration($0.totalSeconds, language: language), DateTools.formatDuration($0.averageDailySeconds, language: language)]
                },
                minWidth: 640
            )
        }
    }
}

struct ReportSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content
        }
    }
}

struct ReportTable: View {
    @EnvironmentObject private var store: AppStore
    var headers: [String]
    var rows: [[String]]
    var minWidth: CGFloat

    var body: some View {
        let visibleRows = rows.isEmpty ? [emptyRow] : rows
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                ReportTableRow(cells: headers, isHeader: true)
                ForEach(Array(visibleRows.enumerated()), id: \.offset) { _, row in
                    ReportTableRow(cells: normalized(row), isHeader: false)
                }
            }
            .frame(minWidth: minWidth, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }

    private var emptyRow: [String] {
        var row = Array(repeating: "-", count: headers.count)
        if !row.isEmpty {
            row[0] = localizedText("暂无记录", "No records", language: store.settings.language)
        }
        return row
    }

    private func normalized(_ row: [String]) -> [String] {
        if row.count == headers.count {
            return row
        }
        if row.count > headers.count {
            return Array(row.prefix(headers.count))
        }
        return row + Array(repeating: "", count: headers.count - row.count)
    }
}

struct ReportTableRow: View {
    var cells: [String]
    var isHeader: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                Text(cells[index])
                    .font(isHeader ? .caption.weight(.semibold) : .caption)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                if index < cells.count - 1 {
                    Divider()
                }
            }
        }
        .background(isHeader ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemBackground))
        Divider()
    }
}

#if canImport(FamilyControls) && canImport(DeviceActivity)
@available(iOS 16.0, *)
struct SystemScreenTimeReportContent: View {
    @EnvironmentObject private var store: AppStore
    var startDate: Date
    var endDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeviceActivityReport(.screenTimeGuardianSummary, filter: reportFilter)
                .frame(minHeight: 420)
        }
    }

    private var reportFilter: DeviceActivityFilter {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: min(startDate, endDate))
        let endStart = calendar.startOfDay(for: max(startDate, endDate))
        let end = calendar.date(byAdding: .day, value: 1, to: endStart) ?? endStart
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: end))
        )
    }
}
#else
struct SystemScreenTimeReportContent: View {
    @EnvironmentObject private var store: AppStore
    var startDate: Date
    var endDate: Date

    var body: some View {
        EmptyStateView(
            title: localizedText("当前 SDK 不支持系统屏幕时间报告", "System Screen Time reports are not supported by this SDK", language: store.settings.language),
            message: localizedText("请使用包含 FamilyControls 和 DeviceActivity 的 iOS SDK 构建。", "Build with an iOS SDK that includes FamilyControls and DeviceActivity.", language: store.settings.language)
        )
    }
}
#endif

struct EmptyStateView: View {
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var p2pService: P2PSyncService
    @Environment(\.dismiss) private var dismiss
    #if canImport(UserNotifications)
    @StateObject private var notificationPermissions = NotificationPermissionModel()
    #endif

    var body: some View {
        let language = store.settings.language
        NavigationStack {
            Form {
                Picker(localizedText("APP 语言", "App Language", language: language), selection: languageBinding) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }

                Section(localizedText("通用", "General", language: language)) {
                    TextField(localizedText("设备名称", "Device Name", language: language), text: $store.settings.deviceName)
                    TextField(localizedText("跟踪对象", "Tracking Target", language: language), text: trackingObjectBinding)
                    Toggle(localizedText("会议模式", "Meeting Mode", language: language), isOn: $store.settings.meetingMode)
                    HStack {
                        Text(localizedText("系统启动时自动启动", "Launch at system startup", language: language))
                        Spacer()
                        Text(localizedText("iOS 不支持", "Not supported on iOS", language: language))
                            .foregroundStyle(.secondary)
                    }
                }

                Section(localizedText("提醒", "Reminders", language: language)) {
                    Toggle(
                        localizedText("姿势切换", "Posture Switch", language: language),
                        isOn: postureSwitchBinding
                    )
                    minuteSettingRow(
                        title: localizedText("护眼间隔", "Eye Rest Interval", language: language),
                        value: eyeRestIntervalBinding,
                        language: language
                    )
                    LabeledContent(
                        localizedText("姿势提醒间隔", "Posture Interval", language: language),
                        value: "\(AppSettings.derivedPostureRestIntervalMinutes(from: store.settings.eyeRestIntervalMinutes ?? 3)) \(localizedText("分钟", "min", language: language))"
                    )
                    Text(localizedText("姿势切换按护眼间隔的 2 倍提醒。", "Posture switch uses 2x the eye-rest interval.", language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    minuteSettingRow(
                        title: localizedText("iOS 屏幕时间记录间隔", "iOS Screen Time Record Interval", language: language),
                        value: iosScreenTimeCheckpointIntervalBinding,
                        language: language
                    )
                }

                Section(localizedText("权限", "Permissions", language: language)) {
                    #if canImport(UserNotifications)
                    LabeledContent(localizedText("通知", "Notifications", language: language), value: notificationPermissions.authorizationText(language: language))
                    LabeledContent(localizedText("横幅/提醒", "Banner/Alert", language: language), value: notificationPermissions.alertText(language: language))
                    LabeledContent(localizedText("声音", "Sound", language: language), value: notificationPermissions.soundText(language: language))
                    LabeledContent(localizedText("提醒样式", "Alert Style", language: language), value: notificationPermissions.alertStyleText(language: language))
                    LabeledContent(localizedText("时间敏感", "Time Sensitive", language: language), value: notificationPermissions.timeSensitiveText(language: language))
                    if let error = notificationPermissions.lastError {
                        Text(error).foregroundStyle(.red)
                    }
                    if notificationPermissions.needsInitialRequest {
                        Button(localizedText("允许通知和声音", "Allow Notifications and Sound", language: language)) {
                            Task { await notificationPermissions.request() }
                        }
                    }
                    Button(localizedText("打开系统通知设置", "Open System Notification Settings", language: language)) {
                        notificationPermissions.openSettings()
                    }
                    Text(localizedText("持续横幅需要用户在系统设置中把本 App 的横幅样式改为持续。", "Persistent banners must be enabled by the user in iOS Settings for this app.", language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                    #if canImport(FamilyControls) && canImport(DeviceActivity) && canImport(UserNotifications)
                    if #available(iOS 16.0, *) {
                        ScreenTimeSettingsRows(
                            postureSwitchEnabled: store.settings.postureSwitchEnabled ?? true,
                            meetingMode: store.settings.meetingMode,
                            eyeRestIntervalMinutes: store.settings.eyeRestIntervalMinutes ?? 3,
                            postureRestIntervalMinutes: AppSettings.derivedPostureRestIntervalMinutes(from: store.settings.eyeRestIntervalMinutes ?? 3),
                            checkpointIntervalMinutes: store.settings.iosScreenTimeCheckpointIntervalMinutes ?? 2
                        )
                    }
                    #endif
                }

                Section(localizedText("同步", "Sync", language: language)) {
                    Toggle(localizedText("P2P 同步", "P2P Sync", language: language), isOn: p2pSyncBinding)
                    TextField(localizedText("配对码", "Pairing Code", language: language), text: p2pPairingCodeBinding)
                        .keyboardType(.numberPad)
                    HStack {
                        Text(localizedText("同步间隔", "Sync Interval", language: language))
                        Spacer()
                        TextField(localizedText("分钟", "Minutes", language: language), value: p2pSyncIntervalBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 96)
                        Text(localizedText("分钟", "min", language: language))
                            .foregroundStyle(.secondary)
                    }
                    Button(localizedText("立即同步", "Sync Now", language: language)) {
                        store.saveSettings()
                        p2pService.refresh()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            p2pService.syncNow()
                        }
                    }
                    Button(localizedText("重新发现设备", "Rediscover Devices", language: language)) {
                        store.saveSettings()
                        p2pService.refresh()
                    }
                    Text(localizedText("多台设备填同一个配对码后，会在同一局域网内发现；只有同意后的设备才会加密同步。", "Devices using the same pairing code can discover each other on the local network. Only approved devices can sync encrypted data.", language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(localizedText("设备 ID", "Device ID", language: language))：\(store.settings.deviceId)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("\(localizedText("状态", "Status", language: language))：\(localizedSyncStatus(p2pService.status, language: language))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(localizedText("配对设备", "Paired Devices", language: language)) {
                    let peers = displayedP2PPeers
                    if peers.isEmpty {
                        Text(localizedText("暂无发现设备", "No devices found", language: language))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(peers) { peer in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(peer.deviceName)
                                Text("\(platformTitle(peer.platform)) / \(localizedSyncStatus(peer.trustStatus, language: language)) / \(localizedSyncStatus(peer.status, language: language))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(peer.deviceId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                HStack {
                                    Button(localizedText("同意", "Approve", language: language)) {
                                        p2pService.approvePeer(peer.deviceId)
                                    }
                                    .disabled(!peer.pairingMatched)
                                    Button(localizedText("拒绝", "Reject", language: language), role: .destructive) {
                                        p2pService.rejectPeer(peer.deviceId)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(localizedText("本地数据", "Local Data", language: language)) {
                    Text(store.supportURL.path)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Section(localizedText("本周计划", "Weekly Plan", language: language)) {
                    HStack {
                        Text(localizedText("每天计划", "Daily Plan", language: language))
                        Spacer()
                        TextField(localizedText("小时", "Hours", language: language), value: plannedDailyHoursBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 56)
                        Text(localizedText("小时", "h", language: language))
                            .foregroundStyle(.secondary)
                        TextField(localizedText("分钟", "Minutes", language: language), value: plannedDailyMinuteRemainderBinding, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 56)
                        Text(localizedText("分钟", "min", language: language))
                            .foregroundStyle(.secondary)
                    }
                    Text(localizedText("默认 8 小时 0 分钟。", "Default is 8h 0m.", language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(localizedText("设置", "Settings", language: language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedText("关闭", "Close", language: language)) { dismiss() }
                }
            }
            .onDisappear {
                store.saveSettings()
                p2pService.refresh()
            }
            .onAppear {
                #if canImport(UserNotifications)
                notificationPermissions.refresh()
                #endif
            }
            .onChange(of: store.settings.language) { _ in
                store.saveSettings()
            }
        }
    }

    private var displayedP2PPeers: [P2PDiscoveredPeer] {
        let livePeers = p2pService.peers
        let livePeerIds = Set(livePeers.map { $0.deviceId.lowercased() })
        let savedPeers = (store.settings.pairedPeers ?? [])
            .filter {
                !livePeerIds.contains($0.deviceId.lowercased()) &&
                    store.trustStatus(for: $0.deviceId) == "已同意"
            }
            .map { record in
                let language = store.settings.language
                return P2PDiscoveredPeer(
                    deviceId: record.deviceId,
                    deviceName: record.deviceName.isEmpty ? "\(localizedText("已同意设备", "Approved Device", language: language)) \(record.deviceId.prefix(8))" : record.deviceName,
                    platform: record.platform.isEmpty ? "unknown" : record.platform,
                    appVersion: record.appVersion.isEmpty ? "unknown" : record.appVersion,
                    address: "等待重新发现",
                    tcpPort: 0,
                    lastSeenAt: record.lastSeenAtUtc,
                    lastSyncAt: nil,
                    status: "已同意，等待重新发现",
                    trustStatus: "已同意",
                    pairingMatched: true,
                    capabilities: normalizedSyncCapabilities(record.capabilities)
                )
            }
        return livePeers + savedPeers
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.language },
            set: { store.updateLanguage($0) }
        )
    }

    private var postureSwitchBinding: Binding<Bool> {
        Binding(
            get: { store.settings.postureSwitchEnabled ?? true },
            set: { store.settings.postureSwitchEnabled = $0 }
        )
    }

    private var eyeRestIntervalBinding: Binding<Int> {
        Binding(
            get: { store.settings.eyeRestIntervalMinutes ?? 3 },
            set: { store.settings.eyeRestIntervalMinutes = min(1440, max(1, $0)) }
        )
    }

    private var iosScreenTimeCheckpointIntervalBinding: Binding<Int> {
        Binding(
            get: { store.settings.iosScreenTimeCheckpointIntervalMinutes ?? 2 },
            set: { store.settings.iosScreenTimeCheckpointIntervalMinutes = min(1440, max(1, $0)) }
        )
    }

    private var trackingObjectBinding: Binding<String> {
        Binding(
            get: { store.settings.trackingObject },
            set: {
                let cleaned = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                store.settings.trackingObject = cleaned.isEmpty ? "LLM Ranking" : cleaned
            }
        )
    }

    private var plannedDailyHoursBinding: Binding<Int> {
        Binding(
            get: { (store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes) / 60 },
            set: { setPlannedDaily(hours: $0, minutes: nil) }
        )
    }

    private var plannedDailyMinuteRemainderBinding: Binding<Int> {
        Binding(
            get: { (store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes) % 60 },
            set: { setPlannedDaily(hours: nil, minutes: $0) }
        )
    }

    private func setPlannedDaily(hours newHours: Int?, minutes newMinutes: Int?) {
        let current = store.settings.plannedDailyMinutes ?? defaultPlannedDailyMinutes
        let hours = min(24, max(0, newHours ?? current / 60))
        let minutes = min(59, max(0, newMinutes ?? current % 60))
        let total = hours * 60 + minutes
        store.settings.plannedDailyMinutes = min(1440, max(1, total == 0 ? defaultPlannedDailyMinutes : total))
    }

    private var p2pSyncBinding: Binding<Bool> {
        Binding(
            get: { store.settings.p2pSyncEnabled ?? true },
            set: { store.settings.p2pSyncEnabled = $0 }
        )
    }

    private var p2pPairingCodeBinding: Binding<String> {
        Binding(
            get: { store.settings.p2pPairingCode ?? "" },
            set: { store.settings.p2pPairingCode = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private var p2pSyncIntervalBinding: Binding<Int> {
        Binding(
            get: { store.settings.p2pSyncIntervalMinutes ?? 5 },
            set: { store.settings.p2pSyncIntervalMinutes = min(1440, max(1, $0)) }
        )
    }

    private func minuteSettingRow(title: String, value: Binding<Int>, language: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(localizedText("分钟", "Minutes", language: language), value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 72)
            Text(localizedText("分钟", "min", language: language))
                .foregroundStyle(.secondary)
        }
    }
}

private enum TrackingSortColumn: Hashable {
    case rank
    case name
    case promptTokens
    case outputTokens
    case inputPrice
    case outputPrice
    case revenue
}

private struct TrackingColumnSpec: Identifiable {
    var id: TrackingSortColumn
    var title: String
    var width: CGFloat
    var alignment: NSTextAlignment
}

private let trackingColumns: [TrackingColumnSpec] = [
    TrackingColumnSpec(id: .rank, title: "排名", width: 64, alignment: .right),
    TrackingColumnSpec(id: .name, title: "LLM 名字", width: 270, alignment: .left),
    TrackingColumnSpec(id: .promptTokens, title: "Prompt Tokens", width: 145, alignment: .right),
    TrackingColumnSpec(id: .outputTokens, title: "Output Tokens", width: 145, alignment: .right),
    TrackingColumnSpec(id: .inputPrice, title: "Input Price / 1M", width: 160, alignment: .right),
    TrackingColumnSpec(id: .outputPrice, title: "Output Price / 1M", width: 170, alignment: .right),
    TrackingColumnSpec(id: .revenue, title: "Weekly Revenue", width: 150, alignment: .right)
]

private var trackingTableWidth: CGFloat {
    trackingColumns.reduce(CGFloat(0)) { $0 + $1.width }
}

private func trackingColumnTitle(_ column: TrackingSortColumn, language: String) -> String {
    switch column {
    case .rank: return localizedText("排名", "Rank", language: language)
    case .name: return localizedText("LLM 名字", "LLM Name", language: language)
    case .promptTokens: return "Prompt Tokens"
    case .outputTokens: return "Output Tokens"
    case .inputPrice: return "Input Price / 1M"
    case .outputPrice: return "Output Price / 1M"
    case .revenue: return "Weekly Revenue"
    }
}

struct TrackingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sourceRows: [LLMRankingRow] = []
    @State private var rows: [LLMRankingRow] = []
    @State private var status = "准备读取 LLM Ranking"
    @State private var isLoading = false
    @State private var sortColumn: TrackingSortColumn = .promptTokens
    @State private var sortAscending = false

    var body: some View {
        let language = store.settings.language
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localizedText("刷新数据", "Refresh", language: language)) {
                        Task { await fetchLatest() }
                    }
                    .disabled(isLoading)
                }
                TrackingTableUIKitView(
                    rows: rows,
                    language: language,
                    sortColumn: sortColumn,
                    sortAscending: sortAscending
                ) { column in
                    setSortColumn(column)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                }
                if rows.isEmpty && !isLoading {
                    Text(localizedText("暂无记录", "No records", language: language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(localizedText("跟踪", "Tracking", language: language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedText("关闭", "Close", language: language)) { dismiss() }
                }
            }
            .task {
                await loadCacheOrFetch()
            }
        }
    }

    private func loadCacheOrFetch() async {
        guard !isLoading else { return }
        isLoading = true
        let language = store.settings.language
        status = localizedText("正在读取 LLM Ranking 缓存...", "Loading LLM Ranking cache...", language: language)
        let url = store.trackingCacheURL(for: DateTools.weekId(Date()))
        let result = await loadRankingCache(from: url)
        switch result {
        case .success(let cache):
            apply(cache: cache)
            status = "\(localizedText("来源", "Source", language: language))：\(cache.source)  \(localizedText("周", "Week", language: language))：\(cache.weekId)"
            isLoading = false
        case .failure:
            isLoading = false
            await fetchLatest()
        }
    }

    private func fetchLatest() async {
        guard !isLoading else { return }
        isLoading = true
        let language = store.settings.language
        status = localizedText("正在从 OpenRouter 获取本周 prompt token Top 20...", "Fetching this week's prompt token Top 20 from OpenRouter...", language: language)
        do {
            let cache = try await OpenRouterClient().fetchWeeklyPromptTokenTop20()
            try store.saveLLMRankingCache(cache)
            apply(cache: cache)
            status = "\(localizedText("来源", "Source", language: language))：\(cache.source)  \(localizedText("周", "Week", language: language))：\(cache.weekId)"
        } catch {
            status = "\(localizedText("OpenRouter 获取失败", "OpenRouter fetch failed", language: language))：\(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadRankingCache(from url: URL) async -> Result<LLMRankingCache, MessageError> {
        await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(MessageError(message: "本周缓存不存在，将从 OpenRouter 获取。"))
            }
            do {
                let data = try Data(contentsOf: url)
                return .success(try JsonCodec.decoder().decode(LLMRankingCache.self, from: data))
            } catch {
                return .failure(MessageError(message: "缓存读取失败：\(error.localizedDescription)"))
            }
        }.value
    }

    private func apply(cache: LLMRankingCache) {
        sourceRows = cache.rows
        rows = sortedRows(sourceRows)
    }

    private func setSortColumn(_ column: TrackingSortColumn) {
        let nextAscending = sortColumn == column ? !sortAscending : (column == .rank || column == .name)
        sortColumn = column
        sortAscending = nextAscending
        if sourceRows.isEmpty {
            status = "\(localizedText("正在加载数据，已切换排序列", "Loading data; sort column set to", language: store.settings.language))：\(title(for: column, language: store.settings.language))"
            return
        }
        rows = sortedRows(sourceRows, column: column, ascending: nextAscending)
    }

    private func title(for column: TrackingSortColumn, language: String) -> String {
        switch column {
        case .rank: return localizedText("排名", "Rank", language: language)
        case .name: return localizedText("LLM 名字", "LLM Name", language: language)
        case .promptTokens: return "Prompt Tokens"
        case .outputTokens: return "Output Tokens"
        case .inputPrice: return "Input Price / 1M"
        case .outputPrice: return "Output Price / 1M"
        case .revenue: return "Weekly Revenue"
        }
    }

    private func sortedRows(_ source: [LLMRankingRow]) -> [LLMRankingRow] {
        sortedRows(source, column: sortColumn, ascending: sortAscending)
    }

    private func sortedRows(_ source: [LLMRankingRow], column: TrackingSortColumn, ascending: Bool) -> [LLMRankingRow] {
        switch column {
        case .rank:
            return sorted(source, ascending: ascending, by: { $0.rank })
        case .name:
            return sorted(source, ascending: ascending, by: { $0.llmName.localizedLowercase })
        case .promptTokens:
            return sorted(source, ascending: ascending, by: { $0.promptTokens })
        case .outputTokens:
            return sorted(source, ascending: ascending, by: { $0.outputTokens })
        case .inputPrice:
            return sorted(source, ascending: ascending, by: { $0.weightedAverageInputPrice })
        case .outputPrice:
            return sorted(source, ascending: ascending, by: { $0.weightedAverageOutputPrice })
        case .revenue:
            return sorted(source, ascending: ascending, by: { $0.weeklyRevenue })
        }
    }

    private func sorted<T: Comparable>(_ source: [LLMRankingRow], ascending: Bool, by selector: (LLMRankingRow) -> T) -> [LLMRankingRow] {
        source.sorted { lhs, rhs in
            let left = selector(lhs)
            let right = selector(rhs)
            if left == right {
                if lhs.rank != rhs.rank {
                    return lhs.rank < rhs.rank
                }
                return lhs.llmName.localizedCaseInsensitiveCompare(rhs.llmName) == .orderedAscending
            }
            return ascending ? left < right : left > right
        }
    }
}

private struct TrackingTableUIKitView: UIViewRepresentable {
    var rows: [LLMRankingRow]
    var language: String
    var sortColumn: TrackingSortColumn
    var sortAscending: Bool
    var onSort: (TrackingSortColumn) -> Void

    func makeUIView(context: Context) -> TrackingTableContainerView {
        let view = TrackingTableContainerView()
        view.onSort = onSort
        view.language = language
        view.apply(rows: rows, sortColumn: sortColumn, sortAscending: sortAscending)
        return view
    }

    func updateUIView(_ uiView: TrackingTableContainerView, context: Context) {
        uiView.onSort = onSort
        uiView.language = language
        uiView.apply(rows: rows, sortColumn: sortColumn, sortAscending: sortAscending)
    }
}

private final class TrackingTableContainerView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onSort: ((TrackingSortColumn) -> Void)?
    var language = "zh"

    private let horizontalScrollView = UIScrollView()
    private let contentView = UIView()
    private let headerStackView = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var rows: [LLMRankingRow] = []
    private var sortColumn: TrackingSortColumn = .promptTokens
    private var sortAscending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func apply(rows: [LLMRankingRow], sortColumn: TrackingSortColumn, sortAscending: Bool) {
        let horizontalOffset = horizontalScrollView.contentOffset
        let verticalOffset = tableView.contentOffset
        self.rows = rows
        self.sortColumn = sortColumn
        self.sortAscending = sortAscending
        rebuildHeader()
        tableView.reloadData()
        horizontalScrollView.setContentOffset(horizontalOffset, animated: false)
        tableView.setContentOffset(verticalOffset, animated: false)
    }

    private func setup() {
        backgroundColor = .systemBackground

        horizontalScrollView.translatesAutoresizingMaskIntoConstraints = false
        horizontalScrollView.showsHorizontalScrollIndicator = true
        horizontalScrollView.alwaysBounceHorizontal = true
        addSubview(horizontalScrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        horizontalScrollView.addSubview(contentView)

        headerStackView.translatesAutoresizingMaskIntoConstraints = false
        headerStackView.axis = .horizontal
        headerStackView.spacing = 0
        headerStackView.distribution = .fill
        contentView.addSubview(headerStackView)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 38
        tableView.estimatedRowHeight = 38
        tableView.separatorStyle = .singleLine
        tableView.alwaysBounceVertical = true
        tableView.alwaysBounceHorizontal = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.backgroundColor = .systemBackground
        tableView.register(TrackingTableCell.self, forCellReuseIdentifier: TrackingTableCell.reuseIdentifier)
        contentView.addSubview(tableView)

        NSLayoutConstraint.activate([
            horizontalScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            horizontalScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            horizontalScrollView.topAnchor.constraint(equalTo: topAnchor),
            horizontalScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: horizontalScrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: horizontalScrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: horizontalScrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: horizontalScrollView.contentLayoutGuide.bottomAnchor),
            contentView.heightAnchor.constraint(equalTo: horizontalScrollView.frameLayoutGuide.heightAnchor),
            contentView.widthAnchor.constraint(equalToConstant: trackingTableWidth),

            headerStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerStackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerStackView.heightAnchor.constraint(equalToConstant: 42),

            tableView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: headerStackView.bottomAnchor),
            tableView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        rebuildHeader()
    }

    private func rebuildHeader() {
        headerStackView.arrangedSubviews.forEach { view in
            headerStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, column) in trackingColumns.enumerated() {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
            button.titleLabel?.numberOfLines = 2
            button.titleLabel?.adjustsFontSizeToFitWidth = true
            button.titleLabel?.minimumScaleFactor = 0.75
            button.contentHorizontalAlignment = buttonAlignment(for: column.alignment)
            button.backgroundColor = .secondarySystemBackground
            button.layer.borderColor = UIColor.separator.cgColor
            button.layer.borderWidth = 0.5
            button.setTitle(headerTitle(for: column), for: .normal)
            button.setTitleColor(column.id == sortColumn ? .label : .secondaryLabel, for: .normal)
            button.addTarget(self, action: #selector(headerTapped(_:)), for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: column.width).isActive = true
            headerStackView.addArrangedSubview(button)
        }
    }

    private func headerTitle(for column: TrackingColumnSpec) -> String {
        let title = trackingColumnTitle(column.id, language: language)
        guard column.id == sortColumn else { return title }
        return "\(title) \(sortAscending ? "▲" : "▼")"
    }

    private func buttonAlignment(for alignment: NSTextAlignment) -> UIControl.ContentHorizontalAlignment {
        switch alignment {
        case .right:
            return .right
        case .center:
            return .center
        default:
            return .left
        }
    }

    @objc private func headerTapped(_ sender: UIButton) {
        guard trackingColumns.indices.contains(sender.tag) else { return }
        onSort?(trackingColumns[sender.tag].id)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TrackingTableCell.reuseIdentifier, for: indexPath)
        guard let trackingCell = cell as? TrackingTableCell else { return cell }
        trackingCell.configure(with: rows[indexPath.row])
        return trackingCell
    }
}

private final class TrackingTableCell: UITableViewCell {
    static let reuseIdentifier = "TrackingTableCell"

    private let stackView = UIStackView()
    private var labels: [UILabel] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(with row: LLMRankingRow) {
        let values = [
            "\(row.rank)",
            row.llmName,
            formatNumber(row.promptTokens),
            formatNumber(row.outputTokens),
            formatPrice(row.weightedAverageInputPrice),
            formatPrice(row.weightedAverageOutputPrice),
            formatWholeCurrency(row.weeklyRevenue)
        ]
        for (label, value) in zip(labels, values) {
            label.text = value
        }
    }

    private func setup() {
        selectionStyle = .none
        backgroundColor = .systemBackground
        contentView.backgroundColor = .systemBackground

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fill
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        labels = trackingColumns.map { column in
            let label = UILabel()
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .label
            label.textAlignment = column.alignment
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.75

            let wrapper = UIView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: wrapper.topAnchor),
                label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                wrapper.widthAnchor.constraint(equalToConstant: column.width)
            ])
            stackView.addArrangedSubview(wrapper)
            return label
        }
    }
}

struct ScreenTimeComplianceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let language = store.settings.language
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(localizedText("系统屏幕时间记录已移到设置的权限区域。", "System Screen Time recording has moved to Permissions in Settings.", language: language))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(localizedText("系统屏幕时间", "System Screen Time", language: language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedText("关闭", "Close", language: language)) { dismiss() }
                }
            }
        }
    }
}

#if canImport(FamilyControls) && canImport(DeviceActivity) && canImport(UserNotifications)
@available(iOS 16.0, *)
@MainActor
final class ScreenTimeAuthorizationModel: ObservableObject {
    @Published var statusText = "请选择要统计的 App 或类别后开启系统屏幕时间记录。"
    @Published var isMonitoring: Bool
    @Published var selection: FamilyActivitySelection

    private let center = DeviceActivityCenter()
    private var didAttemptAutoStart = false
    #if canImport(ManagedSettings)
    private let managedSettingsStore = ManagedSettingsStore()
    #endif

    init() {
        selection = Self.loadSavedSelection()
        let saved = UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey)
            ?? ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey)
        isMonitoring = (saved as? Bool) ?? true

        if Self.selectionIsEmpty(selection) {
            center.stopMonitoring([.screenTimeGuardianDaily])
            isMonitoring = false
            saveMonitoringEnabled(false)
            statusText = "请选择要统计的 App 或类别后开启系统屏幕时间记录。"
        } else if !isMonitoring {
            statusText = "系统屏幕时间记录已关闭。"
        } else {
            statusText = "系统屏幕时间记录已开启。"
        }
    }

    func ensureMonitoringIfEnabled(
        postureSwitchEnabled: Bool,
        meetingMode: Bool,
        eyeRestIntervalMinutes: Int,
        postureRestIntervalMinutes: Int,
        checkpointIntervalMinutes: Int
    ) async {
        guard isMonitoring, !didAttemptAutoStart else { return }
        didAttemptAutoStart = true
        await startMonitoring(
            postureSwitchEnabled: postureSwitchEnabled,
            meetingMode: meetingMode,
            eyeRestIntervalMinutes: eyeRestIntervalMinutes,
            postureRestIntervalMinutes: postureRestIntervalMinutes,
            checkpointIntervalMinutes: checkpointIntervalMinutes
        )
    }

    func startMonitoring(
        postureSwitchEnabled: Bool,
        meetingMode: Bool,
        eyeRestIntervalMinutes: Int,
        postureRestIntervalMinutes: Int,
        checkpointIntervalMinutes: Int
    ) async {
        do {
            let normalizedEyeRestInterval = min(1440, max(1, eyeRestIntervalMinutes))
            let normalizedPostureRestInterval = min(1440, max(1, postureRestIntervalMinutes))
            let normalizedCheckpointInterval = min(1440, max(1, checkpointIntervalMinutes))
            saveSelection()
            guard !Self.selectionIsEmpty(selection) else {
                center.stopMonitoring([.screenTimeGuardianDaily])
                clearManagedSettingsShield()
                isMonitoring = false
                saveSharedMonitoringState(
                    isEnabled: false,
                    postureSwitchEnabled: postureSwitchEnabled,
                    meetingMode: meetingMode,
                    eyeRestIntervalMinutes: normalizedEyeRestInterval,
                    postureRestIntervalMinutes: normalizedPostureRestInterval,
                    checkpointIntervalMinutes: normalizedCheckpointInterval
                )
                statusText = "请选择要统计的 App 或类别后开启系统屏幕时间记录。"
                return
            }

            statusText = "正在请求 Screen Time 和通知授权。"
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .providesAppNotificationSettings])
            center.stopMonitoring([.screenTimeGuardianDaily])
            clearManagedSettingsShield()
            clearScreenTimeEventLog()

            let schedule = DeviceActivitySchedule(
                intervalStart: DateComponents(hour: 0, minute: 0),
                intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
                repeats: true
            )
            saveSharedMonitoringState(
                isEnabled: true,
                postureSwitchEnabled: postureSwitchEnabled,
                meetingMode: meetingMode,
                eyeRestIntervalMinutes: normalizedEyeRestInterval,
                postureRestIntervalMinutes: normalizedPostureRestInterval,
                checkpointIntervalMinutes: normalizedCheckpointInterval,
                resetNotificationState: false
            )
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            let thresholds = monitoringThresholdMinutes(
                checkpointIntervalMinutes: normalizedCheckpointInterval,
                eyeRestIntervalMinutes: normalizedEyeRestInterval,
                postureRestIntervalMinutes: normalizedPostureRestInterval,
                postureSwitchEnabled: postureSwitchEnabled
            )
            for totalMinutes in thresholds {
                let threshold = DateComponents(hour: totalMinutes / 60, minute: totalMinutes % 60)
                if #available(iOS 17.4, *) {
                    events[.screenTimeGuardianRest(totalMinutes)] = DeviceActivityEvent(
                        applications: selection.applicationTokens,
                        categories: selection.categoryTokens,
                        webDomains: selection.webDomainTokens,
                        threshold: threshold,
                        includesPastActivity: false
                    )
                } else {
                    events[.screenTimeGuardianRest(totalMinutes)] = DeviceActivityEvent(
                        applications: selection.applicationTokens,
                        categories: selection.categoryTokens,
                        webDomains: selection.webDomainTokens,
                        threshold: threshold
                    )
                }
            }

            try center.startMonitoring(.screenTimeGuardianDaily, during: schedule, events: events)
            isMonitoring = true
            saveSharedMonitoringState(
                isEnabled: true,
                postureSwitchEnabled: postureSwitchEnabled,
                meetingMode: meetingMode,
                eyeRestIntervalMinutes: normalizedEyeRestInterval,
                postureRestIntervalMinutes: normalizedPostureRestInterval,
                checkpointIntervalMinutes: normalizedCheckpointInterval
            )
            statusText = postureSwitchEnabled
                ? "已启动系统屏幕时间记录：每累计使用 \(normalizedCheckpointInterval) 分钟记录，每 \(normalizedEyeRestInterval) 分钟提醒；姿势切换每 \(normalizedPostureRestInterval) 分钟。"
                : "已启动系统屏幕时间记录：每累计使用 \(normalizedCheckpointInterval) 分钟记录，每 \(normalizedEyeRestInterval) 分钟提醒；姿势切换已关闭。"
        } catch {
            isMonitoring = false
            saveSharedMonitoringState(
                isEnabled: false,
                postureSwitchEnabled: postureSwitchEnabled,
                meetingMode: meetingMode,
                eyeRestIntervalMinutes: eyeRestIntervalMinutes,
                postureRestIntervalMinutes: postureRestIntervalMinutes,
                checkpointIntervalMinutes: checkpointIntervalMinutes
            )
            statusText = "启动系统屏幕时间记录失败：\(error.localizedDescription)"
        }
    }

    private func monitoringThresholdMinutes(
        checkpointIntervalMinutes: Int,
        eyeRestIntervalMinutes: Int,
        postureRestIntervalMinutes: Int,
        postureSwitchEnabled: Bool
    ) -> [Int] {
        var thresholds = Set<Int>()
        addThresholds(to: &thresholds, intervalMinutes: checkpointIntervalMinutes)
        addThresholds(to: &thresholds, intervalMinutes: eyeRestIntervalMinutes)
        if postureSwitchEnabled {
            addThresholds(to: &thresholds, intervalMinutes: postureRestIntervalMinutes)
        }
        return thresholds.sorted()
    }

    private func addThresholds(to thresholds: inout Set<Int>, intervalMinutes: Int) {
        let interval = min(1440, max(1, intervalMinutes))
        var minute = interval
        while minute < 24 * 60 {
            thresholds.insert(minute)
            minute += interval
        }
    }

    func stopMonitoring() {
        center.stopMonitoring([.screenTimeGuardianDaily])
        clearManagedSettingsShield()
        isMonitoring = false
        saveSharedMonitoringState(
            isEnabled: false,
            postureSwitchEnabled: false,
            meetingMode: false,
            eyeRestIntervalMinutes: ScreenTimeGuardianScreenTimeNames.defaultEyeRestIntervalMinutes,
            postureRestIntervalMinutes: ScreenTimeGuardianScreenTimeNames.defaultPostureRestIntervalMinutes,
            checkpointIntervalMinutes: ScreenTimeGuardianScreenTimeNames.defaultCheckpointIntervalMinutes
        )
        statusText = "系统屏幕时间记录已关闭。"
    }

    func localizedStatusText(language: String) -> String {
        guard language == "en" else { return statusText }
        if statusText.hasPrefix("系统屏幕时间记录已开启：") {
            return "System Screen Time recording is on with the current recording and reminder intervals."
        }
        if statusText == "请选择要统计的 App 或类别后开启系统屏幕时间记录。" {
            return "Choose apps or categories to track before turning on System Screen Time recording."
        }
        if statusText == "系统屏幕时间记录已关闭。" {
            return "System Screen Time recording is off."
        }
        if statusText == "系统屏幕时间记录已开启。" {
            return "System Screen Time recording is on."
        }
        if statusText == "正在请求 Screen Time 和通知授权。" {
            return "Requesting Screen Time and notification authorization."
        }
        if statusText.hasPrefix("已启动系统屏幕时间记录：") {
            return "System Screen Time recording started with the current reminder and recording intervals."
        }
        if statusText.hasPrefix("启动系统屏幕时间记录失败：") {
            return "Failed to start System Screen Time recording: \(statusText.dropFirst("启动系统屏幕时间记录失败：".count))"
        }
        return statusText
    }

    var hasSelectedActivities: Bool {
        !Self.selectionIsEmpty(selection)
    }

    func selectionSummaryText(language: String) -> String {
        let appCount = selection.applicationTokens.count
        let categoryCount = selection.categoryTokens.count
        let webCount = selection.webDomainTokens.count
        if appCount + categoryCount + webCount == 0 {
            return localizedText(
                "未选择统计范围。为避免锁屏/黑屏时误记，请选择要统计的 App 或类别。",
                "No tracking scope selected. Choose apps or categories to avoid recording while the screen is locked or off.",
                language: language
            )
        }
        return localizedText(
            "已选择 \(appCount) 个 App、\(categoryCount) 个类别、\(webCount) 个网站。",
            "Selected \(appCount) apps, \(categoryCount) categories, and \(webCount) websites.",
            language: language
        )
    }

    private func saveSharedMonitoringState(
        isEnabled: Bool,
        postureSwitchEnabled: Bool,
        meetingMode: Bool,
        eyeRestIntervalMinutes: Int,
        postureRestIntervalMinutes: Int,
        checkpointIntervalMinutes: Int,
        resetNotificationState: Bool = true
    ) {
        saveMonitoringEnabled(isEnabled)
        UserDefaults.standard.set(postureSwitchEnabled, forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(postureSwitchEnabled, forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey)
        UserDefaults.standard.set(meetingMode, forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(meetingMode, forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey)
        UserDefaults.standard.set(eyeRestIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.eyeRestIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(eyeRestIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.eyeRestIntervalMinutesKey)
        UserDefaults.standard.set(postureRestIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.postureRestIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(postureRestIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.postureRestIntervalMinutesKey)
        UserDefaults.standard.set(checkpointIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.checkpointIntervalMinutesKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(checkpointIntervalMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.checkpointIntervalMinutesKey)
        if isEnabled {
            if resetNotificationState {
                let now = Date()
                UserDefaults.standard.set(now, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
                ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(now, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
                resetSharedNotificationGate()
            } else if UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey) == nil,
                      ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey) == nil {
                let now = Date()
                UserDefaults.standard.set(now, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
                ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(now, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
            ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.removeObject(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey)
        }
    }

    private func resetSharedNotificationGate() {
        let keys = [
            ScreenTimeGuardianScreenTimeStorage.lastNotificationDateKey,
            ScreenTimeGuardianScreenTimeStorage.lastNotificationThresholdMinutesKey,
            ScreenTimeGuardianScreenTimeStorage.lastNotificationAtUtcKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineDateKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineThresholdMinutesKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineAtUtcKey
        ]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.removeObject(forKey: key)
        }
    }

    private func saveMonitoringEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(isEnabled, forKey: ScreenTimeGuardianScreenTimeStorage.monitoringEnabledKey)
    }

    private func saveSelection() {
        guard let data = try? PropertyListEncoder().encode(selection) else { return }
        UserDefaults.standard.set(data, forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
        ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.set(data, forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
    }

    private func clearScreenTimeEventLog() {
        guard let url = ScreenTimeGuardianScreenTimeStorage.eventLogURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func loadSavedSelection() -> FamilyActivitySelection {
        let shared = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.data(forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
        let local = UserDefaults.standard.data(forKey: ScreenTimeGuardianScreenTimeStorage.selectionDataKey)
        if let data = shared ?? local,
           let selection = try? PropertyListDecoder().decode(FamilyActivitySelection.self, from: data) {
            return selection
        }
        return FamilyActivitySelection(includeEntireCategory: true)
    }

    private static func selectionIsEmpty(_ selection: FamilyActivitySelection) -> Bool {
        selection.applicationTokens.isEmpty &&
            selection.categoryTokens.isEmpty &&
            selection.webDomainTokens.isEmpty
    }

    private func clearManagedSettingsShield() {
        #if canImport(ManagedSettings)
        managedSettingsStore.clearAllSettings()
        #endif
    }
}

@available(iOS 16.0, *)
struct ScreenTimeSettingsRows: View {
    var postureSwitchEnabled: Bool
    var meetingMode: Bool
    var eyeRestIntervalMinutes: Int
    var postureRestIntervalMinutes: Int
    var checkpointIntervalMinutes: Int
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = ScreenTimeAuthorizationModel()
    @State private var pickerPresented = false

    var body: some View {
        let language = store.settings.language
        VStack(alignment: .leading, spacing: 8) {
            Button(localizedText("选择统计范围", "Choose Tracking Scope", language: language)) {
                pickerPresented = true
            }
            Text(model.selectionSummaryText(language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Toggle(
                localizedText("系统屏幕时间记录", "System Screen Time Recording", language: language),
                isOn: Binding(
                    get: { model.isMonitoring },
                    set: { enabled in
                        Task {
                            if enabled {
                                await startMonitoring()
                            } else {
                                model.stopMonitoring()
                            }
                        }
                    }
                )
            )
            .disabled(!model.hasSelectedActivities)
            if model.hasSelectedActivities {
                Button(localizedText("保存选择并重启记录", "Save Selection and Restart Recording", language: language)) {
                    Task {
                        await startMonitoring()
                    }
                }
            }
            Text(model.localizedStatusText(language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(localizedText("iOS 需要通过系统选择器授权统计范围；本 App 只记录和提醒，不限制任何 App。", "iOS requires the system picker to authorize the tracking scope. This app only records and reminds; it never restricts apps.", language: language))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .familyActivityPicker(isPresented: $pickerPresented, selection: $model.selection)
        .task {
            await model.ensureMonitoringIfEnabled(
                postureSwitchEnabled: postureSwitchEnabled,
                meetingMode: meetingMode,
                eyeRestIntervalMinutes: eyeRestIntervalMinutes,
                postureRestIntervalMinutes: AppSettings.derivedPostureRestIntervalMinutes(from: eyeRestIntervalMinutes),
                checkpointIntervalMinutes: checkpointIntervalMinutes
            )
        }
        .onChange(of: postureSwitchEnabled) { _ in
            Task { await restartMonitoringIfNeeded() }
        }
        .onChange(of: meetingMode) { _ in
            Task { await restartMonitoringIfNeeded() }
        }
        .onChange(of: eyeRestIntervalMinutes) { _ in
            Task { await restartMonitoringIfNeeded() }
        }
        .onChange(of: checkpointIntervalMinutes) { _ in
            Task { await restartMonitoringIfNeeded() }
        }
    }

    private func startMonitoring() async {
        await model.startMonitoring(
            postureSwitchEnabled: postureSwitchEnabled,
            meetingMode: meetingMode,
            eyeRestIntervalMinutes: eyeRestIntervalMinutes,
            postureRestIntervalMinutes: AppSettings.derivedPostureRestIntervalMinutes(from: eyeRestIntervalMinutes),
            checkpointIntervalMinutes: checkpointIntervalMinutes
        )
    }

    private func restartMonitoringIfNeeded() async {
        store.saveSettings()
        guard model.isMonitoring, model.hasSelectedActivities else { return }
        await startMonitoring()
    }
}
#endif

struct AboutView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let language = store.settings.language
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(appName).font(.title2.weight(.semibold))
                    Text("\(localizedText("开发者", "Developer", language: language))：\(developerName)")
                    Text("\(localizedText("版本", "Version", language: language))：\(appVersion)")
                    Text(localizedText("免费使用", "Free to use", language: language))
                    Divider()
                    Text(localizedText("使用说明", "Usage", language: language))
                        .font(.headline)
                    Text(localizedText(
                        "1. 本 App 利用 P2P 同步你的不同设备，以统计你总的屏幕使用时间。请在各平台 App 中设置统一的同步码，建议不要使用本 App 默认的同步码。\n\n2. 本 App 不使用云端数据，所有数据都保存在你的本地设备，请放心使用。\n\n3. 只有你同意的设备才会同步。",
                        "1. This app uses P2P to sync your devices and calculate your total screen time. Set the same sync code in every app, and avoid using the default code.\n\n2. This app does not use cloud data. All data stays on your local devices.\n\n3. Only devices you approve can sync.",
                        language: language
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(localizedText("关于", "About", language: language))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedText("关闭", "Close", language: language)) { dismiss() }
                }
            }
        }
    }
}

struct RestPromptView: View {
    var prompt: RestPrompt
    var onClose: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var now = Date()

    var body: some View {
        let language = store.settings.language
        let remaining = max(0, Int(ceil(prompt.canCloseAt.timeIntervalSince(now))))
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text(prompt.title)
                    .font(.title2.weight(.semibold))
                Text(prompt.message)
                    .multilineTextAlignment(.center)
                if prompt.canCloseImmediately {
                    Text(localizedText("会议模式：可以立即关闭", "Meeting mode: can close immediately", language: language))
                        .foregroundStyle(.secondary)
                } else if remaining > 0 {
                    Text(language == "en" ? "\(remaining) seconds remaining" : "剩余 \(remaining) 秒")
                        .font(.system(.title3, design: .monospaced))
                }
                if prompt.canCloseImmediately || remaining <= 0 {
                    Button(localizedText("关闭", "Close", language: language)) {
                        onClose()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            now = Date()
        }
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
        return String(format: "%04d-W%02d", calendar.component(.yearForWeekOfYear, from: date), calendar.component(.weekOfYear, from: date))
    }

    static func currentWeekStart(_ date: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        return calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: startOfDay) ?? startOfDay
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

func splitSecondsByLocalDate(start: Date, end: Date) -> [(date: String, seconds: Int)] {
    guard end > start else { return [] }
    let calendar = Calendar.current
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

func currentAppleMobilePlatform() -> String {
    UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
}

func dynamicString(_ value: Any?) -> String {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return ""
}

func dynamicNumber(_ value: Any?) -> Double {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? NSNumber { return value.doubleValue }
    if let value = value as? String { return Double(value) ?? 0 }
    return 0
}

func formatNumber(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
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
