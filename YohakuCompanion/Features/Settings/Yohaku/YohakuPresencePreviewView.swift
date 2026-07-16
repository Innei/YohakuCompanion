import SwiftUI

struct YohakuPresencePreviewView: View {
    let preview: SanitizedPresenceSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    previewMetric(
                        title: "Availability",
                        value: availabilityTitle,
                        symbol: availabilitySymbol
                    )

                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)

                    previewMetric(
                        title: "Application",
                        value: preview?.application?.displayName ?? "Not shared",
                        symbol: preview?.application == nil ? "app.dashed" : "app.fill"
                    )

                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)

                    previewMetric(
                        title: "Window Title",
                        value: preview?.application?.windowTitle ?? "Not shared",
                        symbol: preview?.application?.windowTitle == nil ? "eye.slash" : "macwindow"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    previewMetric(
                        title: "Availability",
                        value: availabilityTitle,
                        symbol: availabilitySymbol
                    )
                    previewMetric(
                        title: "Application",
                        value: preview?.application?.displayName ?? "Not shared",
                        symbol: preview?.application == nil ? "app.dashed" : "app.fill"
                    )
                    previewMetric(
                        title: "Window Title",
                        value: preview?.application?.windowTitle ?? "Not shared",
                        symbol: preview?.application?.windowTitle == nil ? "eye.slash" : "macwindow"
                    )
                }
            }
            .padding(16)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    previewMetric(
                        title: "Media",
                        value: mediaSummary,
                        symbol: mediaSymbol
                    )

                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)

                    previewMetric(
                        title: "Track",
                        value: trackSummary,
                        symbol: preview?.media == nil ? "waveform.slash" : "music.note"
                    )

                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)

                    previewMetric(
                        title: "Artist",
                        value: preview?.media?.artist ?? "Not shared",
                        symbol: preview?.media?.artist == nil ? "person.slash" : "person.fill"
                    )

                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 2)

                    previewMetric(
                        title: "Player",
                        value: preview?.media?.playerDisplayName ?? "Not shared",
                        symbol: preview?.media?.playerDisplayName == nil ? "play.slash" : "play.square.fill"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    previewMetric(title: "Media", value: mediaSummary, symbol: mediaSymbol)
                    previewMetric(
                        title: "Track",
                        value: trackSummary,
                        symbol: preview?.media == nil ? "waveform.slash" : "music.note"
                    )
                    previewMetric(
                        title: "Artist",
                        value: preview?.media?.artist ?? "Not shared",
                        symbol: preview?.media?.artist == nil ? "person.slash" : "person.fill"
                    )
                    previewMetric(
                        title: "Player",
                        value: preview?.media?.playerDisplayName ?? "Not shared",
                        symbol: preview?.media?.playerDisplayName == nil ? "play.slash" : "play.square.fill"
                    )
                }
            }
            .padding(16)

            Divider()

            Label(
                "Only these sanitized values and the current playback timeline can appear on Live Desk. Raw app identifiers and artwork stay on this Mac.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func previewMetric(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 17)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .help(value)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var availabilityTitle: String {
        guard let preview else { return "Preparing…" }
        switch preview.availability {
        case .active: return "Active"
        case .idle: return "Quiet"
        }
    }

    private var availabilitySymbol: String {
        guard let preview else { return "ellipsis.circle" }
        switch preview.availability {
        case .active: return "circle.fill"
        case .idle: return "moon.stars"
        }
    }

    private var mediaSummary: String {
        guard let media = preview?.media else { return "Not shared" }
        let kind: String
        switch media.kind {
        case .music: kind = "Music"
        case .podcast: kind = "Podcast"
        case .video: kind = "Video"
        case .unknown: kind = "Media"
        }
        let playback = media.playback.state == .playing ? "Playing" : "Paused"
        return "\(kind) · \(playback)"
    }

    private var mediaSymbol: String {
        guard let media = preview?.media else { return "waveform.slash" }
        switch media.kind {
        case .music: return "music.note"
        case .podcast: return "mic.fill"
        case .video: return "play.rectangle.fill"
        case .unknown: return "waveform"
        }
    }

    private var trackSummary: String {
        guard let media = preview?.media else { return "Not shared" }
        let values: [String] = [media.title, media.album].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        return values.isEmpty ? "Not shared" : values.joined(separator: " · ")
    }
}
