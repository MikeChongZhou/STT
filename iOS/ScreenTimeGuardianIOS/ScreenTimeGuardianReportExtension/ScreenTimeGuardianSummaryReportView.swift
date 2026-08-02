import SwiftUI

struct ScreenTimeGuardianSummaryReportView: View {
    var configuration: ScreenTimeReportConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统屏幕时间")
                        .font(.headline)
                    Text("授权范围内的 App、类别和网站")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(formatDuration(configuration.totalSeconds))
                    .font(.headline.monospacedDigit())
            }

            if configuration.rows.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无系统屏幕时间数据")
                        .font(.subheadline.weight(.semibold))
                    Text("请确认已授权 Screen Time，并选择了 App、类别或网站。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(configuration.rows) { row in
                            VStack(spacing: 0) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(row.kind)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 42, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.name)
                                            .font(.subheadline)
                                            .lineLimit(2)
                                        if row.pickups > 0 || row.notifications > 0 {
                                            Text("拿起 \(row.pickups) 次  通知 \(row.notifications) 次")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(formatDuration(row.durationSeconds))
                                        .font(.subheadline.monospacedDigit())
                                }
                                .padding(.vertical, 10)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }

    private func formatDuration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)小时\(minutes)分钟"
        }
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "\(seconds)秒"
    }
}
