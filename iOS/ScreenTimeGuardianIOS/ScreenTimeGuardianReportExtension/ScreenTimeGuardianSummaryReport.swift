import DeviceActivity
import ExtensionKit
import SwiftUI

extension DeviceActivityReport.Context {
    static let screenTimeGuardianSummary = Self(ScreenTimeGuardianScreenTimeNames.reportContext)
}

struct ScreenTimeReportRow: Identifiable, Equatable {
    var id: String { "\(kind)-\(name)" }
    var kind: String
    var name: String
    var durationSeconds: Int
    var pickups: Int
    var notifications: Int
}

struct ScreenTimeReportConfiguration: Equatable {
    var totalSeconds: Int
    var rows: [ScreenTimeReportRow]
}

struct ScreenTimeGuardianSummaryReport: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context = .screenTimeGuardianSummary
    let content: (ScreenTimeReportConfiguration) -> ScreenTimeGuardianSummaryReportView

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> ScreenTimeReportConfiguration {
        var totalSeconds = 0
        var rowsById: [String: ScreenTimeReportRow] = [:]

        for await deviceData in data {
            for await segment in deviceData.activitySegments {
                totalSeconds += max(0, Int(segment.totalActivityDuration))

                for await category in segment.categories {
                    let categoryName = category.category.localizedDisplayName ?? "未命名类别"
                    merge(
                        ScreenTimeReportRow(
                            kind: "类别",
                            name: categoryName,
                            durationSeconds: max(0, Int(category.totalActivityDuration)),
                            pickups: 0,
                            notifications: 0
                        ),
                        into: &rowsById
                    )

                    for await application in category.applications {
                        let app = application.application
                        let name = app.localizedDisplayName ?? app.bundleIdentifier ?? "未命名 App"
                        merge(
                            ScreenTimeReportRow(
                                kind: "App",
                                name: name,
                                durationSeconds: max(0, Int(application.totalActivityDuration)),
                                pickups: application.numberOfPickups,
                                notifications: application.numberOfNotifications
                            ),
                            into: &rowsById
                        )
                    }

                    for await webDomain in category.webDomains {
                        let domain = webDomain.webDomain.domain ?? "未命名网站"
                        merge(
                            ScreenTimeReportRow(
                                kind: "网站",
                                name: domain,
                                durationSeconds: max(0, Int(webDomain.totalActivityDuration)),
                                pickups: 0,
                                notifications: 0
                            ),
                            into: &rowsById
                        )
                    }
                }
            }
        }

        let rows = rowsById.values
            .filter { $0.durationSeconds > 0 }
            .sorted { lhs, rhs in
                if lhs.durationSeconds == rhs.durationSeconds {
                    return lhs.name < rhs.name
                }
                return lhs.durationSeconds > rhs.durationSeconds
            }

        return ScreenTimeReportConfiguration(totalSeconds: totalSeconds, rows: rows)
    }

    private func merge(_ row: ScreenTimeReportRow, into rowsById: inout [String: ScreenTimeReportRow]) {
        if var existing = rowsById[row.id] {
            existing.durationSeconds += row.durationSeconds
            existing.pickups += row.pickups
            existing.notifications += row.notifications
            rowsById[row.id] = existing
        } else {
            rowsById[row.id] = row
        }
    }
}
