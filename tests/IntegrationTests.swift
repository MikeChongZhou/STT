#!/usr/bin/env swift
/**
 * STT Integration Test Runner
 *
 * Tests core logic functions extracted from main.swift:
 * - Session lifecycle
 * - Deduplication (unionSeconds)
 * - Sync merge
 * - Tombstone handling
 * - Settings normalization
 *
 * Run: swift tests/IntegrationTests.swift
 * Or:  cd tests && swift IntegrationTests.swift
 */

import Foundation

// MARK: - Test Framework

var passed = 0
var failed = 0
var total = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    total += 1
    if condition {
        passed += 1
        print("  ✅ \(message)")
    } else {
        failed += 1
        print("  ❌ \(message) (line \(line))")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    assert(a == b, "\(message): expected \(b), got \(a)", file: file, line: line)
}

func testSection(_ name: String) {
    print("\n━━━ \(name) ━━━")
}

// MARK: - Data Models (copied from main.swift for standalone testing)

struct ScreenSession: Codable, Equatable {
    var id: String
    var deviceId: String
    var deviceName: String
    var platform: String
    var measurementScope: String
    var startAtUtc: Date
    var startTimezone: String
    var endAtUtc: Date?
    var endTimezone: String?
    var durationSeconds: Int
    var stopAction: String?
    var heartbeatAtUtc: Date?
    var createdAtUtc: Date
    var updatedAtUtc: Date
    var revision: Int
    var syncStatus: String
}

struct DeletedSession: Codable, Equatable {
    var id: String
    var sessionId: String?
    var startAtUtc: Date?
    var endAtUtc: Date?
    var deletedByDeviceId: String
    var deletedAtUtc: Date
    var updatedAtUtc: Date
}

struct SyncDeviceInfo: Codable {
    var deviceId: String
    var deviceName: String
    var platform: String
    var appVersion: String
    var updatedAtUtc: Date
}

struct SyncSnapshot: Codable {
    var protocolVersion: Int
    var capabilities: [String]?
    var device: SyncDeviceInfo
    var cursor: SyncCursor?
    var sessions: [ScreenSession]
    var deletedSessions: [DeletedSession]?
}

struct SyncCursor: Codable {
    var lastSyncAtUtc: Date
}

// MARK: - Helper Functions

func makeSession(
    id: String = UUID().uuidString,
    deviceId: String = "dev-001",
    platform: String = "macos",
    start: Date,
    end: Date? = nil,
    duration: Int = 0,
    stopAction: String? = nil
) -> ScreenSession {
    ScreenSession(
        id: id,
        deviceId: deviceId,
        deviceName: "Test Device",
        platform: platform,
        measurementScope: "global_exact",
        startAtUtc: start,
        startTimezone: "Asia/Shanghai",
        endAtUtc: end,
        endTimezone: end != nil ? "Asia/Shanghai" : nil,
        durationSeconds: duration,
        stopAction: stopAction,
        heartbeatAtUtc: end,
        createdAtUtc: start,
        updatedAtUtc: end ?? start,
        revision: 1,
        syncStatus: "local"
    )
}

func date(_ str: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: str) ?? Date()
}

func dateComponents(_ str: String) -> DateComponents {
    let d = date(str)
    let cal = Calendar.current
    return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
}

// MARK: - Deduplication (unionSeconds)

func unionSeconds(sessions: [ScreenSession], start: Date, end: Date, now: Date = Date()) -> Int {
    let intervals: [(Date, Date)] = sessions.compactMap { session in
        let sessionEnd = session.endAtUtc ?? now
        let overlapStart = max(session.startAtUtc, start)
        let overlapEnd = min(sessionEnd, end)
        return overlapEnd > overlapStart ? (overlapStart, overlapEnd) : nil
    }.sorted { $0.0 < $1.0 }

    guard !intervals.isEmpty else { return 0 }

    var total = 0
    var currentStart = intervals[0].0
    var currentEnd = intervals[0].1

    for i in 1..<intervals.count {
        let (intervalStart, intervalEnd) = intervals[i]
        if intervalStart <= currentEnd {
            if intervalEnd > currentEnd { currentEnd = intervalEnd }
        } else {
            total += Int(currentEnd.timeIntervalSince(currentStart))
            currentStart = intervalStart
            currentEnd = intervalEnd
        }
    }
    total += Int(currentEnd.timeIntervalSince(currentStart))
    return total
}

// MARK: - Session Merge

func mergeSessions(local: [ScreenSession], incoming: [ScreenSession]) -> (merged: [ScreenSession], newCount: Int) {
    var map = [String: ScreenSession]()
    for s in local { map[s.id] = s }

    var newCount = 0
    for incoming_session in incoming {
        if let existing = map[incoming_session.id] {
            if incoming_session.updatedAtUtc > existing.updatedAtUtc {
                map[incoming_session.id] = incoming_session
            }
        } else {
            map[incoming_session.id] = incoming_session
            newCount += 1
        }
    }

    let merged = map.values.sorted { $0.startAtUtc < $1.startAtUtc }
    return (merged, newCount)
}

// MARK: - Tombstone Check

func isDeleted(session: ScreenSession, tombstones: [DeletedSession]) -> Bool {
    for tombstone in tombstones {
        if tombstone.sessionId == session.id { return true }
        if let tombstoneStart = tombstone.startAtUtc,
           let tombstoneEnd = tombstone.endAtUtc {
            if session.startAtUtc >= tombstoneStart && session.startAtUtc < tombstoneEnd {
                return true
            }
        }
    }
    return false
}

// MARK: - Settings Normalization

func normalizePairingCode(_ value: String?) -> String {
    let digits = String((value ?? "").filter { $0.isNumber }.prefix(6))
    guard !digits.isEmpty else { return "000000" }
    return digits.padding(toLength: 6, withPad: "0", startingAt: 0)
}

func derivedPostureRestIntervalMinutes(from eyeRestMinutes: Int) -> Int {
    min(1440, max(1, eyeRestMinutes) * 2)
}

// ============================================================
// TESTS
// ============================================================

// MARK: T5 - Deduplication

testSection("T5: Cross-device deduplication (unionSeconds)")

let h1 = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
let h2 = Calendar.current.date(byAdding: .hour, value: 2, to: Date())!
let h3 = Calendar.current.date(byAdding: .hour, value: 3, to: Date())!
let h4 = Calendar.current.date(byAdding: .hour, value: 4, to: Date())!

// T5.1: Same time, two devices → 1 hour
do {
    let sessions = [
        makeSession(deviceId: "A", start: h1, end: h2, duration: 3600),
        makeSession(deviceId: "B", start: h1, end: h2, duration: 3600),
    ]
    let result = unionSeconds(sessions: sessions, start: h1, end: h2)
    assertEqual(result, 3600, "T5.1: Same time overlap = 1 hour")
}

// T5.2: No overlap → 2 hours
do {
    let sessions = [
        makeSession(deviceId: "A", start: h1, end: h2, duration: 3600),
        makeSession(deviceId: "B", start: h2, end: h3, duration: 3600),
    ]
    let result = unionSeconds(sessions: sessions, start: h1, end: h3)
    assertEqual(result, 7200, "T5.2: No overlap = 2 hours")
}

// T5.3: Partial overlap → 2 hours
do {
    let sessions = [
        makeSession(deviceId: "A", start: h1, end: h3, duration: 7200),
        makeSession(deviceId: "B", start: h2, end: h4, duration: 7200),
    ]
    let result = unionSeconds(sessions: sessions, start: h1, end: h4)
    assertEqual(result, 10800, "T5.3: Partial overlap = 3 hours")
}

// T5.4: Three devices, full overlap → 1 hour
do {
    let sessions = [
        makeSession(deviceId: "A", start: h1, end: h2, duration: 3600),
        makeSession(deviceId: "B", start: h1, end: h2, duration: 3600),
        makeSession(deviceId: "C", start: h1, end: h2, duration: 3600),
    ]
    let result = unionSeconds(sessions: sessions, start: h1, end: h2)
    assertEqual(result, 3600, "T5.4: Three devices full overlap = 1 hour")
}

// T5.5: Empty sessions
do {
    let result = unionSeconds(sessions: [], start: h1, end: h2)
    assertEqual(result, 0, "T5.5: Empty sessions = 0")
}

// MARK: T1 - Session Lifecycle

testSection("T1: Session lifecycle")

// T1.1: Create session with duration
do {
    let session = makeSession(start: h1, end: h2, duration: 3600, stopAction: "screen_locked")
    assertEqual(session.durationSeconds, 3600, "T1.1: Session duration")
    assertEqual(session.stopAction, "screen_locked", "T1.1: Stop action")
    assert(session.endAtUtc != nil, "T1.1: End time set")
}

// T1.2: Active session (no end)
do {
    let session = makeSession(start: h1)
    assert(session.endAtUtc == nil, "T1.2: Active session has no end time")
    assertEqual(session.durationSeconds, 0, "T1.2: Active session duration = 0")
}

// MARK: T4 - P2P Sync Merge

testSection("T4: P2P sync merge")

// T4.1: Merge new sessions
do {
    let local = [makeSession(id: "s1", start: h1, end: h2, duration: 3600)]
    let incoming = [makeSession(id: "s2", start: h2, end: h3, duration: 3600)]
    let (merged, newCount) = mergeSessions(local: local, incoming: incoming)
    assertEqual(merged.count, 2, "T4.1: Merge adds new session")
    assertEqual(newCount, 1, "T4.1: One new session")
}

// T4.2: Merge same session, newer version wins
do {
    let local = [makeSession(id: "s1", start: h1, end: h2, duration: 3600)]
    var incoming = makeSession(id: "s1", start: h1, end: h2, duration: 3700)
    incoming.updatedAtUtc = h3 // newer
    let (merged, newCount) = mergeSessions(local: local, incoming: [incoming])
    assertEqual(merged.count, 1, "T4.2: Same ID, one result")
    assertEqual(newCount, 0, "T4.2: Not new")
    assertEqual(merged[0].durationSeconds, 3700, "T4.2: Newer version wins")
}

// T4.3: Merge same session, older version ignored
do {
    var local = makeSession(id: "s1", start: h1, end: h2, duration: 3700)
    local.updatedAtUtc = h3
    let incoming = [makeSession(id: "s1", start: h1, end: h2, duration: 3600)]
    let (merged, _) = mergeSessions(local: local, incoming: incoming)
    assertEqual(merged[0].durationSeconds, 3700, "T4.3: Older version ignored")
}

// T4.4: Cross-device dedup after sync
do {
    // Device A and B both used 9:00-10:00
    let sessions = [
        makeSession(deviceId: "A", start: h1, end: h2, duration: 3600),
        makeSession(deviceId: "B", start: h1, end: h2, duration: 3600),
    ]
    let deduped = unionSeconds(sessions: sessions, start: h1, end: h2)
    assertEqual(deduped, 3600, "T4.4: Cross-device dedup = 1 hour")
}

// MARK: Tombstone

testSection("Tombstone handling")

// Tombstone marks session as deleted
do {
    let session = makeSession(id: "s1", start: h1, end: h2, duration: 3600)
    let tombstone = DeletedSession(
        id: "t1",
        sessionId: "s1",
        startAtUtc: h1,
        endAtUtc: h2,
        deletedByDeviceId: "dev-002",
        deletedAtUtc: h3,
        updatedAtUtc: h3
    )
    assert(isDeleted(session: session, tombstones: [tombstone]), "Tombstone: session s1 is deleted")
    assert(!isDeleted(session: makeSession(id: "s2", start: h1, end: h2), tombstones: [tombstone]), "Tombstone: session s2 is not deleted")
}

// MARK: Settings

testSection("Settings normalization")

// Pairing code normalization
assertEqual(normalizePairingCode("123456"), "123456", "Pairing: 6 digits OK")
assertEqual(normalizePairingCode("12345"), "123450", "Pairing: 5 digits padded")
assertEqual(normalizePairingCode("12345678"), "123456", "Pairing: 8 digits truncated")
assertEqual(normalizePairingCode("abc123def"), "123000", "Pairing: letters stripped, digits padded")
assertEqual(normalizePairingCode(nil), "000000", "Pairing: nil → 000000")
assertEqual(normalizePairingCode(""), "000000", "Pairing: empty → 000000")

// Posture interval derivation
assertEqual(derivedPostureRestIntervalMinutes(from: 3), 6, "Posture: 3 → 6")
assertEqual(derivedPostureRestIntervalMinutes(from: 20), 40, "Posture: 20 → 40")
assertEqual(derivedPostureRestIntervalMinutes(from: 1), 2, "Posture: 1 → 2")
assertEqual(derivedPostureRestIntervalMinutes(from: 1000), 1440, "Posture: capped at 1440")

// MARK: Sync Snapshot Serialization

testSection("SyncSnapshot serialization")

do {
    let device = SyncDeviceInfo(
        deviceId: "dev-001",
        deviceName: "Test Mac",
        platform: "macos",
        appVersion: "1.0.9",
        updatedAtUtc: Date()
    )
    let snapshot = SyncSnapshot(
        protocolVersion: 1,
        capabilities: ["delta_sync", "gzip"],
        device: device,
        cursor: SyncCursor(lastSyncAtUtc: Date()),
        sessions: [makeSession(start: h1, end: h2, duration: 3600)],
        deletedSessions: []
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snapshot)
    let json = String(data: data, encoding: .utf8)!

    assert(json.contains("\"protocol_version\" : 1"), "Snapshot: protocol_version in JSON")
    assert(json.contains("\"delta_sync\""), "Snapshot: capabilities in JSON")
    assert(json.contains("\"device_id\""), "Snapshot: device_id in JSON")
    assert(json.contains("\"deleted_sessions\""), "Snapshot: deleted_sessions in JSON")

    // Round-trip
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SyncSnapshot.self, from: data)
    assertEqual(decoded.protocolVersion, 1, "Snapshot: round-trip protocol_version")
    assertEqual(decoded.device.deviceId, "dev-001", "Snapshot: round-trip device_id")
    assertEqual(decoded.sessions.count, 1, "Snapshot: round-trip sessions count")
    assertEqual(decoded.capabilities?.count, 2, "Snapshot: round-trip capabilities")
}

// MARK: T6 - iOS ScreenTime Alignment Simulation

testSection("T6: iOS ScreenTime alignment simulation")

// Simulates the checkpoint-based recording with cumulative total alignment
struct CheckpointSimulator {
    var lastRecordedThreshold: Int = 0
    var appTotalRecorded: Int = 0
    var records: [(threshold: Int, segment: Int, systemTotal: Int, appTotal: Int)] = []

    mutating func checkpoint(thresholdMinutes: Int) {
        let delta = thresholdMinutes - lastRecordedThreshold
        guard delta > 0 else { return }
        lastRecordedThreshold = thresholdMinutes
        let segment = delta * 60
        let systemTotal = thresholdMinutes * 60
        let appTotalAfter = appTotalRecorded + segment
        let gap = systemTotal - appTotalAfter
        let aligned = gap > 0 ? segment + gap : segment
        appTotalRecorded += aligned
        records.append((threshold: thresholdMinutes, segment: aligned, systemTotal: systemTotal, appTotal: appTotalRecorded))
    }

    mutating func reminder(thresholdMinutes: Int) {
        let delta = thresholdMinutes - lastRecordedThreshold
        if delta > 0 { lastRecordedThreshold = thresholdMinutes }
    }
}

// T6.1: Continuous usage — perfectly aligned
var sim1 = CheckpointSimulator()
for m in stride(from: 2, through: 10, by: 2) { sim1.checkpoint(thresholdMinutes: m) }
assertEqual(sim1.records.last!.appTotal, 600, "T6.1: 10min continuous = 600s")
assertEqual(sim1.records.last!.appTotal, sim1.records.last!.systemTotal, "T6.1: app == system")

// T6.2: With reminders — no double-count
var sim2 = CheckpointSimulator()
sim2.checkpoint(thresholdMinutes: 2)
sim2.reminder(thresholdMinutes: 3)
sim2.checkpoint(thresholdMinutes: 4)
sim2.checkpoint(thresholdMinutes: 6)
sim2.reminder(thresholdMinutes: 6)
sim2.checkpoint(thresholdMinutes: 8)
sim2.reminder(thresholdMinutes: 9)
sim2.checkpoint(thresholdMinutes: 10)
assertEqual(sim2.records.last!.appTotal, 600, "T6.2: With reminders = 600s")

// T6.3: Lock gap — system pauses, thresholds don't advance
var sim3 = CheckpointSimulator()
sim3.checkpoint(thresholdMinutes: 2)
sim3.checkpoint(thresholdMinutes: 4)
// Lock 10min — system pauses, no thresholds fire
sim3.checkpoint(thresholdMinutes: 6)
sim3.checkpoint(thresholdMinutes: 8)
assertEqual(sim3.records.last!.appTotal, 480, "T6.3: With lock gap = 480s")
assertEqual(sim3.records.last!.appTotal, sim3.records.last!.systemTotal, "T6.3: aligned after gap")

// T6.4: All checkpoints maintain alignment
var sim4 = CheckpointSimulator()
for m in stride(from: 2, through: 60, by: 2) { sim4.checkpoint(thresholdMinutes: m) }
var allAligned = true
for r in sim4.records { if r.appTotal != r.systemTotal { allAligned = false; break } }
assert(allAligned, "T6.4: All 30 checkpoints maintain alignment")

// T6.5: 1-minute checkpoint interval
var sim5 = CheckpointSimulator()
for m in 1...60 { sim5.checkpoint(thresholdMinutes: m) }
assertEqual(sim5.records.last!.appTotal, 3600, "T6.5: 60x1min = 3600s")
assertEqual(sim5.records.last!.appTotal, sim5.records.last!.systemTotal, "T6.5: aligned")

// T6.6: Reminder at same threshold as checkpoint
var sim6 = CheckpointSimulator()
sim6.checkpoint(thresholdMinutes: 2)
sim6.checkpoint(thresholdMinutes: 4)
sim6.checkpoint(thresholdMinutes: 6)
sim6.reminder(thresholdMinutes: 6) // duplicate threshold
sim6.checkpoint(thresholdMinutes: 8)
assertEqual(sim6.records.count, 4, "T6.6: 4 records not 5")
assertEqual(sim6.records.last!.appTotal, 480, "T6.6: total=480s")

// MARK: Edge Cases

testSection("Edge cases")

// Empty date range
do {
    let result = unionSeconds(sessions: [], start: h1, end: h1)
    assertEqual(result, 0, "Edge: empty range = 0")
}

// Session with end before start (corrupted data)
do {
    let session = makeSession(start: h2, end: h1, duration: -3600)
    let result = unionSeconds(sessions: [session], start: h1, end: h3)
    assertEqual(result, 0, "Edge: end before start = 0 (no overlap)")
}

// Very long session (24 hours)
do {
    let h24 = Calendar.current.date(byAdding: .hour, value: 24, to: h1)!
    let session = makeSession(start: h1, end: h24, duration: 86400)
    let result = unionSeconds(sessions: [session], start: h1, end: h24)
    assertEqual(result, 86400, "Edge: 24-hour session = 86400 seconds")
}

// Many small sessions (1 minute each, 60 in an hour)
do {
    var sessions = [ScreenSession]()
    for i in 0..<60 {
        let start = Calendar.current.date(byAdding: .minute, value: i, to: h1)!
        let end = Calendar.current.date(byAdding: .minute, value: i + 1, to: h1)!
        sessions.append(makeSession(deviceId: "A", start: start, end: end, duration: 60))
    }
    let result = unionSeconds(sessions: sessions, start: h1, end: h2)
    assertEqual(result, 3600, "Edge: 60 x 1-min sessions = 3600 seconds")
}

// MARK: - Results

print("\n" + String(repeating: "=", count: 50))
print("Results: \(passed)/\(total) passed, \(failed) failed")
if failed == 0 {
    print("🎉 ALL TESTS PASSED")
} else {
    print("⚠️  \(failed) TESTS FAILED")
    exit(1)
}
