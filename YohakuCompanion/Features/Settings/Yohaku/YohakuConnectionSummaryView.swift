import SwiftUI

struct YohakuConnectionSummaryView: View {
    let connection: YohakuCompanionConnectionSummary
    let statusTitle: String
    let statusSymbol: String
    let statusDetail: String
    let statusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 40, height: 40)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Paired with Yohaku")
                        .font(.headline)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(statusColor.opacity(0.1))
                    .clipShape(Capsule())
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    connectionDetail("Server", value: connection.baseURL.absoluteString)
                    connectionDetail("Device ID", value: connection.deviceID, monospaced: true)
                }
                .padding(.top, 10)
                .padding(.leading, 22)
            } label: {
                Label("Connection Details", systemImage: "network")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func connectionDetail(
        _ label: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
                .accessibilityLabel("\(label), \(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
