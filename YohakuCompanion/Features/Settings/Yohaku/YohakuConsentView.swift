import SwiftUI

struct YohakuConsentView: View {
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
                statusTitle: "Live Desk Off",
                statusSymbol: "checkmark.shield.fill",
                statusDetail: "This Mac is ready to publish after you approve the preview below.",
                statusColor: .secondary
            )

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Text("Public Preview")
                        .font(.headline)

                    Spacer()

                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshPreview)
                        .controlSize(.small)
                        .disabled(service.isBusy)
                }

                YohakuPresencePreviewView(preview: service.preview)
            }

            if !service.isPreviewCurrent {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing the preview for the current privacy settings…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    consentMessage
                    Spacer(minLength: 12)
                    enableButton
                }

                VStack(alignment: .leading, spacing: 12) {
                    consentMessage
                    enableButton
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
    }

    private var consentMessage: some View {
        Label(
            "Nothing is public until Live Desk is turned on.",
            systemImage: "hand.raised.fill"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var enableButton: some View {
        Button(
            "Turn On Live Desk",
            systemImage: "dot.radiowaves.left.and.right",
            action: enableLiveDesk
        )
        .buttonStyle(.borderedProminent)
        .disabled(
            service.isBusy
                || service.preview == nil
                || !service.isPreviewCurrent
        )
    }

    private func refreshPreview() {
        Task {
            await store.refreshPreview(using: service)
        }
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
