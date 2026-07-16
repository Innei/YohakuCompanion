import SwiftUI

struct YohakuConnectionSummaryView: View {
    let connection: YohakuCompanionConnectionSummary
    let statusTitle: String
    let statusSymbol: String

    var body: some View {
        SettingsGroup("Yohaku Connection") {
            VStack(spacing: 0) {
                LabeledContent("Status") {
                    Label(statusTitle, systemImage: statusSymbol)
                }

                SettingsDivider()

                LabeledContent("Server") {
                    Text(connection.baseURL.absoluteString)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                SettingsDivider()

                LabeledContent("Device ID") {
                    Text(connection.deviceID)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(14)
        }
    }
}
