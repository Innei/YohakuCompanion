import SwiftUI

struct YohakuPresencePreviewView: View {
    let preview: SanitizedPresenceSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            LabeledContent("Availability", value: availabilityTitle)

            SettingsDivider()

            LabeledContent("Application", value: preview?.application?.displayName ?? "Not shared")

            SettingsDivider()

            LabeledContent("Window Title", value: preview?.application?.windowTitle ?? "Not shared")

            SettingsDivider()

            LabeledContent("Media", value: mediaTitle)
        }
        .padding(14)
        .accessibilityElement(children: .contain)
    }

    private var availabilityTitle: String {
        guard let preview else { return "No preview available" }
        switch preview.availability {
        case .active: return "Active"
        case .idle: return "Quiet"
        }
    }

    private var mediaTitle: String {
        guard let media = preview?.media else { return "Not shared" }
        let identity = [media.title, media.artist].compactMap { $0 }
        return identity.isEmpty ? "Not shared" : identity.joined(separator: " — ")
    }
}
