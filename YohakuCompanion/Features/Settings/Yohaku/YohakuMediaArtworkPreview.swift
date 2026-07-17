import AppKit
import SwiftUI

struct YohakuMediaArtworkPreview: View {
    private let image: NSImage?

    init(artwork: SanitizedMediaArtwork?) {
        image = artwork.flatMap { NSImage(data: $0.pngData) }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Album artwork shared with Live Desk")
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Album artwork not shared")
            }
        }
        .frame(width: 52, height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
    }
}
