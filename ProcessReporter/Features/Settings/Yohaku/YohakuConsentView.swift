import SwiftUI

struct YohakuConsentView: View {
    let connection: YohakuCompanionConnectionSummary
    @ObservedObject var service: YohakuCompanionService
    @ObservedObject var store: YohakuSettingsStore

    @State private var isShowingRemovalConfirmation = false

    var body: some View {
        SettingsPage(
            "Yohaku",
            subtitle: "This Mac is paired. Review the public preview before enabling Live Desk."
        ) {
            if let errorMessage = store.errorMessage {
                SettingsInlineNotice(message: errorMessage)
            }

            YohakuConnectionSummaryView(
                connection: connection,
                statusTitle: "Paired · Live Desk Off",
                statusSymbol: "checkmark.shield"
            )

            SettingsGroup(
                "Public Live Desk Preview",
                footer: "Only these sanitized fields can be published. The preview updates when source or privacy settings change. Raw bundle identifiers and the device credential are never shown or sent as Presence content."
            ) {
                YohakuPresencePreviewView(preview: service.preview)
            }

            if !service.isPreviewCurrent {
                SettingsInlineNotice(
                    message: "The public preview is being refreshed for the current privacy settings."
                )
            }

            HStack(spacing: 10) {
                Button("Refresh Preview", systemImage: "arrow.clockwise", action: refreshPreview)
                    .disabled(service.isBusy)

                Spacer()

                Button("Enable Live Desk", systemImage: "dot.radiowaves.left.and.right", action: enableLiveDesk)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        service.isBusy
                            || service.preview == nil
                            || !service.isPreviewCurrent
                    )
            }

            SettingsGroup("Connection Control") {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remove This Mac")
                        Text("Deletes the protected device credential from this Mac. The device can also be revoked in Yohaku Admin.")
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
                        Button("Remove Pairing", role: .destructive, action: removeConnection)
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Live Desk will remain off and the protected device credential will be removed from this Mac.")
                    }
                }
                .padding(14)
            }

            if service.isBusy {
                ProgressView("Updating Yohaku connection…")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func refreshPreview() {
        store.refreshPreview(using: service)
    }

    private func enableLiveDesk() {
        Task {
            await store.setLiveDeskEnabled(true, using: service)
        }
    }

    private func removeConnection() {
        Task {
            await store.removeConnection(using: service)
        }
    }
}
