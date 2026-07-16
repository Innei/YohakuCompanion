import SwiftUI

struct YohakuConnectedView: View {
    let connection: YohakuCompanionConnectionSummary
    @ObservedObject var service: YohakuCompanionService
    @ObservedObject var store: YohakuSettingsStore

    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        SettingsPage(
            "Yohaku",
            subtitle: "Manage this Mac’s first-party connection and Live Desk sharing."
        ) {
            if let errorMessage = store.errorMessage {
                SettingsInlineNotice(message: errorMessage)
            }

            YohakuConnectionSummaryView(
                connection: connection,
                statusTitle: runtimeStatusTitle,
                statusSymbol: runtimeStatusSymbol
            )

            SettingsGroup(
                "Live Desk",
                footer: "Turning Live Desk off stops new updates immediately and makes a best-effort clear request. If the server is unreachable, the current projection disappears when its lease expires. This does not remove the pairing."
            ) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Share to Live Desk")
                        Text("Publish the latest sanitized application state. Media remains Bridge-only in this release.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button("Pause Live Desk", systemImage: "pause.circle", action: pauseLiveDesk)
                        .disabled(service.isBusy)
                }
                .padding(14)
            }

            SettingsGroup(
                "Current Sanitized Preview",
                footer: "This preview applies the same local privacy policy used by Live Desk delivery."
            ) {
                YohakuPresencePreviewView(preview: service.preview)
            }

            Button("Refresh Preview", systemImage: "arrow.clockwise", action: refreshPreview)
                .disabled(service.isBusy)

            SettingsGroup("Connection Control") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remove This Mac")
                        Text("Stops new Live Desk updates, requests remote clearing, and removes the protected device credential from this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Button("Remove Pairing…", role: .destructive) {
                        isShowingRemovalConfirmation = true
                    }
                    .disabled(service.isBusy)
                    .confirmationDialog(
                        "Remove Yohaku Pairing?",
                        isPresented: $isShowingRemovalConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Stop Live Desk and Remove", role: .destructive, action: removeConnection)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Yohaku Companion will stop new updates, make a best-effort clear request, then remove this Mac’s device credential. If the server is unreachable, the current projection expires automatically at the end of its lease.")
                    }
                }
                .padding(14)
            }

            if service.isBusy {
                ProgressView("Updating Yohaku connection…")
                    .frame(maxWidth: .infinity)
            }
        }
        .task {
            store.synchronize(using: service)
            store.refreshPreview(using: service)
        }
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

    private func pauseLiveDesk() {
        guard !service.isBusy else { return }
        Task { await store.setLiveDeskEnabled(false, using: service) }
    }

    private func refreshPreview() {
        store.refreshPreview(using: service)
    }

    private func removeConnection() {
        Task {
            await store.removeConnection(using: service)
        }
    }
}
