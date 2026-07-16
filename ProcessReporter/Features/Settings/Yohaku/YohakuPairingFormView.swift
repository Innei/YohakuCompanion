import SwiftUI

struct YohakuPairingFormView: View {
    @ObservedObject var service: YohakuCompanionService
    @ObservedObject var store: YohakuSettingsStore

    var body: some View {
        SettingsPage(
            "Yohaku",
            subtitle: "Connect this Mac to your Yohaku site with a one-time pairing code."
        ) {
            if let warningMessage = store.warningMessage {
                SettingsInlineNotice(
                    message: warningMessage,
                    symbolName: "exclamationmark.triangle.fill"
                )
            }

            if let errorMessage = store.errorMessage {
                SettingsInlineNotice(message: errorMessage)
            }

            SettingsGroup(
                "Pair This Mac",
                footer: "Generate a pairing code in Yohaku Admin. Codes expire after 10 minutes and can be used only once."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Server URL")
                        TextField("https://your-yohaku.example", text: $store.serverURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityHint("The public address of your Yohaku site.")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Device Name")
                        TextField("This Mac", text: $store.deviceName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityHint("This name appears in Yohaku Admin.")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Pairing Code")
                        TextField("Enter the one-time code", text: $store.pairingCode)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .accessibilityHint("A single-use code generated in Yohaku Admin.")
                            .onSubmit(pair)
                    }

                }
                .padding(14)
            }

            HStack(spacing: 10) {
                if service.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Pairing with Yohaku")
                }

                Button(action: pair) {
                    Label("Pair with Yohaku", systemImage: "link")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(canSubmitPairing ? Color.white : Color.secondary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 34)
                        .background {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    canSubmitPairing
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.14)
                                )
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canSubmitPairing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            SettingsGroup("Privacy by Default") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Pairing does not publish your desktop activity.",
                        systemImage: "hand.raised.fill"
                    )
                    .bold()

                    Text("After pairing, Yohaku Companion shows the exact sanitized preview first. Live Desk starts only after you explicitly confirm that preview.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        }
    }

    private func pair() {
        guard canSubmitPairing else { return }
        Task {
            await store.pair(using: service)
        }
    }

    private var canSubmitPairing: Bool {
        store.canPair && !service.isBusy
    }
}
