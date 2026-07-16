import SwiftUI

struct YohakuSettingsView: View {
    @StateObject private var service = YohakuCompanionService.shared
    @StateObject private var store = YohakuSettingsStore()

    var body: some View {
        Group {
            if !store.hasLoaded {
                SettingsPage(
                    "Yohaku",
                    subtitle: "Connect this Mac to your Yohaku site."
                ) {
                    ProgressView("Loading Yohaku connection…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
            } else if let connection = service.connection {
                if connection.isLiveDeskEnabled {
                    YohakuConnectedView(
                        connection: connection,
                        service: service,
                        store: store
                    )
                } else {
                    YohakuConsentView(
                        connection: connection,
                        service: service,
                        store: store
                    )
                }
            } else {
                YohakuPairingFormView(service: service, store: store)
            }
        }
        .task {
            await store.load(using: service)
        }
    }
}
