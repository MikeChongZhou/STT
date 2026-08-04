import DeviceActivity
import Foundation
import ManagedSettings
import UserNotifications

final class ScreenTimeGuardianMonitorExtension: DeviceActivityMonitor {
    private let managedSettingsStore = ManagedSettingsStore()
    private let restNotificationIdentifier = "screen-time-guardian-rest-current"
    private let notificationBurstCooldownSeconds: TimeInterval = 45
    private let notificationTimingToleranceSeconds: TimeInterval = 15

    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        managedSettingsStore.clearAllSettings()
        resetNotificationDeliveryState(now: Date())
        // Reset checkpoint baseline for new monitoring interval
        let defaults = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()
        defaults?.removeObject(forKey: "screen_time_guardian.last_checkpoint_reached_at_utc")
        defaults?.removeObject(forKey: "screen_time_guardian.last_checkpoint_threshold_minutes")
        defaults?.removeObject(forKey: "screen_time_guardian.last_recorded_threshold_minutes")
        defaults?.removeObject(forKey: "screen_time_guardian.app_total_recorded_seconds")
        defaults?.removeObject(forKey: "screen_time_guardian.system_total_at_last_checkpoint")
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        managedSettingsStore.clearAllSettings()
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)

        let now = Date()
        let thresholdMinutes = restEventThresholdMinutes(for: event)
        if let thresholdMinutes, !shouldRecordThreshold(thresholdMinutes: thresholdMinutes, now: now) {
            clearManagedSettingsShield()
            return
        }

        let reminderThresholdMinutes = thresholdMinutes.flatMap { minutes in
            isReminderThreshold(minutes) ? minutes : nil
        }
        let shouldPrompt = reminderThresholdMinutes.map { shouldDeliverReminder(thresholdMinutes: $0, now: now) } ?? false

        recordEvent(for: event, reachedAt: now, suppressReminder: reminderThresholdMinutes != nil && !shouldPrompt)
        clearManagedSettingsShield()

        if shouldPrompt, let notification = notificationContent(for: event) {
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [restNotificationIdentifier])
            center.removeDeliveredNotifications(withIdentifiers: [restNotificationIdentifier])
            let request = UNNotificationRequest(
                identifier: restNotificationIdentifier,
                content: notification,
                trigger: nil
            )
            center.add(request)
        }
    }

    private func notificationContent(for event: DeviceActivityEvent.Name) -> UNMutableNotificationContent? {
        guard let thresholdMinutes = restEventThresholdMinutes(for: event),
              isReminderThreshold(thresholdMinutes) else {
            return nil
        }

        let content = UNMutableNotificationContent()
        if !meetingModeEnabled {
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        }

        if includesPosture(thresholdMinutes: thresholdMinutes) {
            content.title = localizedText("姿势切换与用眼休息提醒", "Posture and Eye Rest Reminder")
            content.body = localizedText(
                "屏幕使用已累计 \(postureRestIntervalMinutes) 分钟。请完成坐姿和站姿切换，并看 20 英尺外放松眼睛。",
                "Screen use has reached \(postureRestIntervalMinutes) minutes. Switch posture, then look 20 feet away to rest your eyes."
            )
        } else {
            content.title = localizedText("用眼休息提醒", "Eye Rest Reminder")
            content.body = localizedText(
                "屏幕使用已累计 \(eyeRestIntervalMinutes) 分钟。请看 20 英尺外 20 秒。",
                "Screen use has reached \(eyeRestIntervalMinutes) minutes. Look 20 feet away for 20 seconds."
            )
        }

        return content
    }

    private func localizedText(_ zh: String, _ en: String) -> String {
        language == "en" ? en : zh
    }

    private func recordEvent(for event: DeviceActivityEvent.Name, reachedAt: Date, suppressReminder: Bool) {
        guard let eventName = storageEventName(for: event, suppressReminder: suppressReminder),
              let thresholdSeconds = thresholdSeconds(for: event),
              let url = ScreenTimeGuardianScreenTimeStorage.eventLogURL() else {
            return
        }

        let now = reachedAt
        let defaults = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()

        // Align with system Screen Time: use the threshold value itself as the source of truth.
        // The system's DeviceActivity threshold = cumulative screen-on minutes since monitoring started.
        // So: actual segment = currentThreshold - lastRecordedThreshold.
        // This naturally excludes lock/sleep time because the system doesn't count them.
        //
        // IMPORTANT: Both checkpoint AND reminder events must update the shared baseline.
        // Otherwise, when checkpoint@6 and posture@6 fire at the same time,
        // both would record segment = 6-4 = 2min, double-counting the same window.
        let thresholdMinutes = thresholdSeconds / 60
        let lastThresholdKey = "screen_time_guardian.last_recorded_threshold_minutes"
        let lastThreshold = defaults?.integer(forKey: lastThresholdKey) ?? 0

        let actualSegmentSeconds: Int
        if lastThreshold > 0 {
            let deltaMinutes = thresholdMinutes - lastThreshold
            if deltaMinutes <= 0 {
                // Another event already recorded at this threshold — skip to avoid double-count
                actualSegmentSeconds = 0
            } else {
                actualSegmentSeconds = deltaMinutes * 60
            }
        } else {
            // First event ever — use the full threshold as the segment
            actualSegmentSeconds = thresholdSeconds
        }

        // Update shared baseline for ALL events (prevents double-count when checkpoint and reminder fire at same threshold)
        defaults?.set(thresholdMinutes, forKey: lastThresholdKey)

        // Only checkpoint events record time segments.
        // Reminder events (eye rest, posture) only trigger notifications — they don't add data.
        if !isCheckpointEvent(event) { return }

        // Skip zero-duration segments (duplicate threshold events)
        guard actualSegmentSeconds > 0 else { return }

        // ── System Screen Time Alignment ──
        // The system threshold = cumulative screen-on minutes since monitoring started.
        // At each checkpoint, compare system total vs app recorded total.
        // If system > app (gap from lock/sleep between checkpoints),
        // increase this segment's duration to close the gap.
        // If app > system (shouldn't happen), use the threshold delta as-is.
        let defaults2 = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()
        let appTotalKey = "screen_time_guardian.app_total_recorded_seconds"
        let systemTotalKey = "screen_time_guardian.system_total_at_last_checkpoint"
        let appTotalSeconds = defaults2?.integer(forKey: appTotalKey) ?? 0
        let systemTotalSeconds = defaults2?.integer(forKey: systemTotalKey) ?? 0

        // System's cumulative screen time at this checkpoint
        let currentSystemTotalSeconds = thresholdMinutes * 60

        // App's total after adding this segment
        let appTotalAfterSegment = appTotalSeconds + actualSegmentSeconds

        // Gap = system total - app total after this segment
        let gap = currentSystemTotalSeconds - appTotalAfterSegment

        let alignedSegmentSeconds: Int
        if gap > 0 {
            // System has recorded more screen time than app.
            // Distribute the gap into this segment to align.
            alignedSegmentSeconds = actualSegmentSeconds + gap
        } else {
            // App is aligned or ahead (shouldn't happen, but be safe)
            alignedSegmentSeconds = actualSegmentSeconds
        }

        // Update running totals
        defaults2?.set(appTotalSeconds + alignedSegmentSeconds, forKey: appTotalKey)
        defaults2?.set(currentSystemTotalSeconds, forKey: systemTotalKey)

        let stableId = stableEventId(eventName: eventName, thresholdSeconds: thresholdSeconds, reachedAt: reachedAt)
        let record = ScreenTimeGuardianScreenTimeEvent(
            id: stableId,
            eventName: ScreenTimeGuardianScreenTimeNames.checkpointEvent,
            thresholdSeconds: thresholdSeconds,
            segmentDurationSeconds: alignedSegmentSeconds,
            reachedAtUtc: reachedAt,
            createdAtUtc: now
        )
        var records: [ScreenTimeGuardianScreenTimeEvent] = []
        if let data = try? Data(contentsOf: url),
           let decoded = try? ScreenTimeGuardianScreenTimeStorage.eventDecoder().decode([ScreenTimeGuardianScreenTimeEvent].self, from: data) {
            records = decoded
        }
        records.removeAll { existing in
            existing.id == stableId ||
                stableEventId(eventName: existing.eventName, thresholdSeconds: existing.thresholdSeconds, reachedAt: existing.reachedAtUtc) == stableId
        }
        records.append(record)
        records = Array(records.suffix(500))

        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? ScreenTimeGuardianScreenTimeStorage.eventEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func stableEventId(eventName: String, thresholdSeconds: Int, reachedAt: Date) -> String {
        "\(eventName)-\(localDateString(reachedAt))-\(thresholdSeconds)"
    }

    private func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func clearManagedSettingsShield() {
        managedSettingsStore.clearAllSettings()
    }

    private func thresholdSeconds(for event: DeviceActivityEvent.Name) -> Int? {
        if let thresholdMinutes = restEventThresholdMinutes(for: event) {
            return thresholdMinutes * 60
        }

        switch event {
        case .screenTimeGuardianEyeRest:
            return eyeRestIntervalMinutes * 60
        case .screenTimeGuardianPosture:
            return postureRestIntervalMinutes * 60
        default:
            return nil
        }
    }

    private func segmentDurationSeconds(for event: DeviceActivityEvent.Name) -> Int {
        if let thresholdMinutes = restEventThresholdMinutes(for: event) {
            return segmentDurationMinutes(for: thresholdMinutes) * 60
        }
        return thresholdSeconds(for: event) ?? 20 * 60
    }

    private func storageEventName(for event: DeviceActivityEvent.Name, suppressReminder: Bool) -> String? {
        if let thresholdMinutes = restEventThresholdMinutes(for: event) {
            guard !suppressReminder, isReminderThreshold(thresholdMinutes) else {
                return ScreenTimeGuardianScreenTimeNames.checkpointEvent
            }
            return includesPosture(thresholdMinutes: thresholdMinutes) ? ScreenTimeGuardianScreenTimeNames.postureEvent : ScreenTimeGuardianScreenTimeNames.eyeRestEvent
        }

        switch event {
        case .screenTimeGuardianEyeRest:
            return ScreenTimeGuardianScreenTimeNames.eyeRestEvent
        case .screenTimeGuardianPosture:
            return ScreenTimeGuardianScreenTimeNames.postureEvent
        default:
            return nil
        }
    }

    private func restEventThresholdMinutes(for event: DeviceActivityEvent.Name) -> Int? {
        let rawValue = event.rawValue
        guard rawValue.hasPrefix(ScreenTimeGuardianScreenTimeNames.restEventPrefix) else { return nil }
        let suffix = rawValue.dropFirst(ScreenTimeGuardianScreenTimeNames.restEventPrefix.count)
        guard let minutes = Int(suffix), minutes > 0, minutes < 24 * 60 else { return nil }
        return minutes
    }

    private func includesPosture(thresholdMinutes: Int) -> Bool {
        postureSwitchEnabled && thresholdMinutes.isMultiple(of: postureRestIntervalMinutes)
    }

    private func isReminderThreshold(_ thresholdMinutes: Int) -> Bool {
        thresholdMinutes.isMultiple(of: eyeRestIntervalMinutes) || includesPosture(thresholdMinutes: thresholdMinutes)
    }

    private func isCheckpointEvent(_ event: DeviceActivityEvent.Name) -> Bool {
        guard let minutes = restEventThresholdMinutes(for: event) else { return true }
        return !isReminderThreshold(minutes)
    }

    private func segmentDurationMinutes(for thresholdMinutes: Int) -> Int {
        let previous = previousRecordedThresholdMinutes(before: thresholdMinutes)
        return max(1, thresholdMinutes - previous)
    }

    private func previousRecordedThresholdMinutes(before thresholdMinutes: Int) -> Int {
        let intervals = postureSwitchEnabled
            ? [checkpointIntervalMinutes, eyeRestIntervalMinutes, postureRestIntervalMinutes]
            : [checkpointIntervalMinutes, eyeRestIntervalMinutes]
        return intervals.reduce(0) { previous, interval in
            let candidate = ((thresholdMinutes - 1) / interval) * interval
            return max(previous, candidate)
        }
    }

    private func shouldRecordThreshold(thresholdMinutes: Int, now: Date) -> Bool {
        let today = localDateString(now)
        if let baseline = notificationBaseline(for: today, now: now),
           thresholdMinutes <= baseline.thresholdMinutes {
            // Always allow checkpoint events — they record data segments, not reminders.
            // A checkpoint at a previously-reached threshold is a new data point, not a duplicate.
            let isCheckpoint = !isReminderThreshold(thresholdMinutes)
            if !isCheckpoint {
                return false
            }
        }

        if isLikelyHistoricalCatchUp(thresholdMinutes: thresholdMinutes, today: today, now: now) {
            writeNotificationBaseline(date: today, thresholdMinutes: thresholdMinutes, reachedAt: now)
            return false
        }

        writeNotificationBaseline(date: today, thresholdMinutes: thresholdMinutes, reachedAt: now)
        return true
    }

    private func shouldDeliverReminder(thresholdMinutes: Int, now: Date) -> Bool {
        let today = localDateString(now)
        let lastDate = stringSetting(forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationDateKey)
        if lastDate == today {
            let lastThreshold = intSetting(forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationThresholdMinutesKey)
            if thresholdMinutes <= lastThreshold {
                return false
            }
            if let lastAt = dateSetting(forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationAtUtcKey),
               now.timeIntervalSince(lastAt) < notificationBurstCooldownSeconds {
                return false
            }
        }

        writeNotificationGate(date: today, thresholdMinutes: thresholdMinutes, notifiedAt: now)
        return true
    }

    private func isLikelyHistoricalCatchUp(thresholdMinutes: Int, today: String, now: Date) -> Bool {
        guard let baseline = notificationBaseline(for: today, now: now) else { return false }
        let deltaMinutes = max(0, thresholdMinutes - baseline.thresholdMinutes)
        let elapsed = max(0, now.timeIntervalSince(baseline.reachedAt))
        return TimeInterval(deltaMinutes * 60) > elapsed + notificationTimingToleranceSeconds
    }

    private func notificationBaseline(for today: String, now: Date) -> (thresholdMinutes: Int, reachedAt: Date)? {
        let baselineDate = stringSetting(forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineDateKey)
        if baselineDate == today,
           let baselineAt = dateSetting(forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineAtUtcKey) {
            return (
                thresholdMinutes: intSetting(forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineThresholdMinutesKey),
                reachedAt: baselineAt
            )
        }
        guard let monitoringStartedAt = dateSetting(forKey: ScreenTimeGuardianScreenTimeStorage.monitoringStartedAtUtcKey) else {
            return (thresholdMinutes: 0, reachedAt: Calendar.current.startOfDay(for: now))
        }
        let startOfToday = Calendar.current.startOfDay(for: now)
        let baselineStart = monitoringStartedAt > startOfToday ? monitoringStartedAt : startOfToday
        return (thresholdMinutes: 0, reachedAt: min(baselineStart, now))
    }

    private func writeNotificationGate(date: String, thresholdMinutes: Int, notifiedAt: Date) {
        for defaults in settingsStores {
            defaults.set(date, forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationDateKey)
            defaults.set(thresholdMinutes, forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationThresholdMinutesKey)
            defaults.set(notifiedAt, forKey: ScreenTimeGuardianScreenTimeStorage.lastNotificationAtUtcKey)
        }
    }

    private func writeNotificationBaseline(date: String, thresholdMinutes: Int, reachedAt: Date) {
        let existingDate = stringSetting(forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineDateKey)
        let existingThreshold = existingDate == date
            ? intSetting(forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineThresholdMinutesKey)
            : 0
        let nextThreshold = max(thresholdMinutes, existingThreshold)
        for defaults in settingsStores {
            defaults.set(date, forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineDateKey)
            defaults.set(nextThreshold, forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineThresholdMinutesKey)
            defaults.set(reachedAt, forKey: ScreenTimeGuardianScreenTimeStorage.notificationBaselineAtUtcKey)
        }
    }

    private func resetNotificationDeliveryState(now: Date) {
        let keys = [
            ScreenTimeGuardianScreenTimeStorage.lastNotificationDateKey,
            ScreenTimeGuardianScreenTimeStorage.lastNotificationThresholdMinutesKey,
            ScreenTimeGuardianScreenTimeStorage.lastNotificationAtUtcKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineDateKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineThresholdMinutesKey,
            ScreenTimeGuardianScreenTimeStorage.notificationBaselineAtUtcKey
        ]
        for defaults in settingsStores {
            for key in keys {
                defaults.removeObject(forKey: key)
            }
        }
        writeNotificationBaseline(date: localDateString(now), thresholdMinutes: 0, reachedAt: now)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [restNotificationIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [restNotificationIdentifier])
    }

    private var postureSwitchEnabled: Bool {
        if let value = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey) as? Bool {
            return value
        }
        if let value = UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.postureSwitchEnabledKey) as? Bool {
            return value
        }
        return true
    }

    private var meetingModeEnabled: Bool {
        if let value = ScreenTimeGuardianScreenTimeStorage.sharedDefaults()?.object(forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey) as? Bool {
            return value
        }
        if let value = UserDefaults.standard.object(forKey: ScreenTimeGuardianScreenTimeStorage.meetingModeKey) as? Bool {
            return value
        }
        return false
    }

    private var eyeRestIntervalMinutes: Int {
        minuteSetting(
            key: ScreenTimeGuardianScreenTimeStorage.eyeRestIntervalMinutesKey,
            defaultValue: ScreenTimeGuardianScreenTimeNames.defaultEyeRestIntervalMinutes
        )
    }

    private var postureRestIntervalMinutes: Int {
        min(1440, max(1, eyeRestIntervalMinutes) * 2)
    }

    private var checkpointIntervalMinutes: Int {
        minuteSetting(
            key: ScreenTimeGuardianScreenTimeStorage.checkpointIntervalMinutesKey,
            defaultValue: ScreenTimeGuardianScreenTimeNames.defaultCheckpointIntervalMinutes
        )
    }

    private func minuteSetting(key: String, defaultValue: Int) -> Int {
        if let value = objectSetting(forKey: key) as? Int {
            return min(1440, max(1, value))
        }
        return defaultValue
    }

    private var settingsStores: [UserDefaults] {
        var stores = [UserDefaults.standard]
        if let shared = ScreenTimeGuardianScreenTimeStorage.sharedDefaults() {
            stores.insert(shared, at: 0)
        }
        return stores
    }

    private func objectSetting(forKey key: String) -> Any? {
        for defaults in settingsStores {
            if let value = defaults.object(forKey: key) {
                return value
            }
        }
        return nil
    }

    private func dateSetting(forKey key: String) -> Date? {
        objectSetting(forKey: key) as? Date
    }

    private func stringSetting(forKey key: String) -> String? {
        objectSetting(forKey: key) as? String
    }

    private func intSetting(forKey key: String) -> Int {
        objectSetting(forKey: key) as? Int ?? 0
    }

    private var language: String {
        (objectSetting(forKey: ScreenTimeGuardianScreenTimeStorage.languageKey) as? String) == "en" ? "en" : "zh"
    }
}
