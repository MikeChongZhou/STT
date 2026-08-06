import Foundation

#if canImport(DeviceActivity)
import DeviceActivity
#endif

enum ScreenTimeGuardianScreenTimeNames {
    static let dailyActivity = "screen-time-guardian.daily"
    static let checkpointEvent = "screen-time-guardian.checkpoint"
    static let eyeRestEvent = "screen-time-guardian.eye-rest"
    static let postureEvent = "screen-time-guardian.posture"
    static let restEventPrefix = "screen-time-guardian.rest."
    static let defaultEyeRestIntervalMinutes = 3
    static let defaultPostureRestIntervalMinutes = 6
    static let defaultCheckpointIntervalMinutes = 2
    static let reportContext = "screen-time-guardian.summary-report"

    static func restEventName(index: Int) -> String {
        "\(restEventPrefix)\(index)"
    }
}

enum ScreenTimeGuardianScreenTimeStorage {
    static let appGroupIdentifier = "group.com.timbertrail.screentimeguardian"
    static let selectionDataKey = "screen_time_guardian.family_activity_selection"
    static let monitoringEnabledKey = "screen_time_guardian.monitoring_enabled"
    static let postureThresholdSecondsKey = "screen_time_guardian.posture_threshold_seconds"
    static let postureSwitchEnabledKey = "screen_time_guardian.posture_switch_enabled"
    static let meetingModeKey = "screen_time_guardian.meeting_mode"
    static let languageKey = "screen_time_guardian.language"
    static let eyeRestIntervalMinutesKey = "screen_time_guardian.eye_rest_interval_minutes"
    static let postureRestIntervalMinutesKey = "screen_time_guardian.posture_rest_interval_minutes"
    static let checkpointIntervalMinutesKey = "screen_time_guardian.checkpoint_interval_minutes"
    static let monitoringStartedAtUtcKey = "screen_time_guardian.monitoring_started_at_utc"
    static let lastNotificationDateKey = "screen_time_guardian.last_notification_date"
    static let lastNotificationThresholdMinutesKey = "screen_time_guardian.last_notification_threshold_minutes"
    static let lastNotificationAtUtcKey = "screen_time_guardian.last_notification_at_utc"
    static let notificationBaselineDateKey = "screen_time_guardian.notification_baseline_date"
    static let notificationBaselineThresholdMinutesKey = "screen_time_guardian.notification_baseline_threshold_minutes"
    static let notificationBaselineAtUtcKey = "screen_time_guardian.notification_baseline_at_utc"
    static let eventLogFileName = "screen_time_events.json"
    static let overtimeRepeatExtraMinutesKey = "screen_time_guardian.overtime_repeat_extra_minutes"
    static let overtimeBaselineThresholdMinutesKey = "screen_time_guardian.overtime_baseline_threshold_minutes"
    static let cachedPeersKey = "screen_time_guardian.cached_peers"

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func sharedContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    static func eventLogURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(eventLogFileName)
    }

    static func eventEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        return encoder
    }

    static func eventDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct ScreenTimeGuardianScreenTimeEvent: Codable, Equatable, Identifiable {
    var id: String
    var eventName: String
    var thresholdSeconds: Int
    var segmentDurationSeconds: Int?
    var reachedAtUtc: Date
    var createdAtUtc: Date
}

#if canImport(DeviceActivity)
extension DeviceActivityName {
    static let screenTimeGuardianDaily = Self(ScreenTimeGuardianScreenTimeNames.dailyActivity)
}

extension DeviceActivityEvent.Name {
    static let screenTimeGuardianEyeRest = Self(ScreenTimeGuardianScreenTimeNames.eyeRestEvent)
    static let screenTimeGuardianPosture = Self(ScreenTimeGuardianScreenTimeNames.postureEvent)
    static func screenTimeGuardianRest(_ index: Int) -> Self {
        Self(ScreenTimeGuardianScreenTimeNames.restEventName(index: index))
    }
}
#endif
