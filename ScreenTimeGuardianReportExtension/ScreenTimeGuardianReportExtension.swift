import DeviceActivity
import ExtensionKit
import SwiftUI

@main
struct ScreenTimeGuardianReportExtension: DeviceActivityReportExtension {
    var body: some DeviceActivityReportScene {
        ScreenTimeGuardianSummaryReport { configuration in
            ScreenTimeGuardianSummaryReportView(configuration: configuration)
        }
    }
}
