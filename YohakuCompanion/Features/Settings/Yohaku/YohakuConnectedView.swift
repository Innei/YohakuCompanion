import SwiftUI

struct YohakuConnectedView: View {
    let connection: YohakuCompanionConnectionSummary
    @ObservedObject var service: YohakuCompanionService
    @ObservedObject var store: YohakuSettingsStore

    var body: some View {
        SettingsPage(
            "Yohaku",
            subtitle: "Share a privacy-filtered view of this Mac on Live Desk."
        ) {
            if let errorMessage = store.errorMessage {
                SettingsInlineNotice(message: errorMessage)
            }

            YohakuConnectionSummaryView(
                connection: connection,
                statusTitle: runtimeStatusTitle,
                statusSymbol: runtimeStatusSymbol,
                statusDetail: runtimeStatusDetail,
                statusColor: runtimeStatusColor
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Current Sanitized Preview")
                        .font(.headline)

                    Spacer()

                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshPreview)
                        .controlSize(.small)
                        .disabled(service.isBusy)
                }

                YohakuPresencePreviewView(preview: service.preview)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    liveDeskMessage
                    Spacer(minLength: 12)
                    pauseButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    liveDeskMessage
                    pauseButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            YohakuConnectionControlView(
                isBusy: service.isBusy,
                onRemove: removeConnection
            )

            if service.isBusy {
                ProgressView("Updating Yohaku connection…")
                    .frame(maxWidth: .infinity)
            }
        }
        .task {
            store.synchronize(using: service)
            await store.refreshPreview(using: service)
        }
    }

    private var liveDeskMessage: some View {
        Label(
            "Live Desk is enabled and shares only the latest sanitized application and media state.",
            systemImage: "lock.shield.fill"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pauseButton: some View {
        Button("Pause Live Desk", systemImage: "pause.circle", action: pauseLiveDesk)
            .disabled(service.isBusy)
    }

    private var runtimeStatusTitle: String {
        switch service.runtimeState {
        case .disabled: return "Live Desk Paused"
        case .connecting: return "Connecting"
        case .updateRequired: return "Update Required"
        case .serverFeatureUnavailable: return "Unavailable on Server"
        case .active: return "Connected"
        case .degraded: return "Connection Issue"
        case .suspended: return "Suspended"
        }
    }

    private var runtimeStatusSymbol: String {
        switch service.runtimeState {
        case .disabled: return "pause.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .updateRequired: return "arrow.down.circle"
        case .serverFeatureUnavailable: return "xmark.circle"
        case .active: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.circle"
        case .suspended: return "moon.zzz"
        }
    }

    private var runtimeStatusDetail: String {
        switch service.runtimeState {
        case .disabled: return "Live Desk is paused on this Mac."
        case .connecting: return "Sending the first sanitized update to Yohaku."
        case .updateRequired: return "This version must be updated before publishing can continue."
        case .serverFeatureUnavailable: return "Live Desk is currently unavailable on the paired server."
        case .active: return "Sanitized application and media activity is being delivered to Yohaku."
        case .degraded: return "The last delivery failed; Yohaku Companion will retry automatically."
        case .suspended: return "Delivery is suspended while this Mac is inactive."
        }
    }

    private var runtimeStatusColor: Color {
        switch service.runtimeState {
        case .active: return .green
        case .connecting: return .accentColor
        case .degraded, .updateRequired: return .orange
        case .serverFeatureUnavailable: return .red
        case .disabled, .suspended: return .secondary
        }
    }

    private func pauseLiveDesk() {
        guard !service.isBusy else { return }
        Task { await store.setLiveDeskEnabled(false, using: service) }
    }

    private func refreshPreview() {
        Task {
            await store.refreshPreview(using: service)
        }
    }

    private func removeConnection() {
        Task {
            await store.removeConnection(using: service)
        }
    }
}
