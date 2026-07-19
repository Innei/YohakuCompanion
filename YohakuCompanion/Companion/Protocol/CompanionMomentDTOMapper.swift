import Foundation

enum CompanionMomentMappingError: Error, Equatable, Sendable {
    case emptyMoment
    case textTooLong(field: String, maximumUnicodeScalars: Int)
    case invalidNumber(field: String)
    case invalidArtworkURL
}

struct CompanionMomentDraft: Equatable, Sendable {
    let content: String
    let snapshot: SanitizedPresenceSnapshot
    let includesApplication: Bool
    let includesWindowTitle: Bool
    let includesMedia: Bool
}

struct CompanionMomentDTOMapper: Sendable {
    func makeRequest(
        draft: CompanionMomentDraft,
        artworkURL: URL? = nil,
        requestID: String = UUID().uuidString
    ) throws -> CompanionMomentRequestV1 {
        let content = draft.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        try validateLength(content, field: "data.content", maximum: 5_000)

        let application = try draft.includesApplication
            ? draft.snapshot.application.map {
                try makeApplication($0, includesWindowTitle: draft.includesWindowTitle)
            }
            : nil
        let media = try draft.includesMedia
            ? draft.snapshot.media.map { try makeMedia($0, artworkURL: artworkURL) }
            : nil
        guard !content.isEmpty || application != nil || media != nil else {
            throw CompanionMomentMappingError.emptyMoment
        }

        return CompanionMomentRequestV1(
            meta: CompanionMomentRequestMetaV1(
                requestID: requestID,
                observedAt: draft.snapshot.observedAt
            ),
            data: CompanionMomentDataV1(
                content: content,
                application: application,
                media: media
            )
        )
    }

    private func makeApplication(
        _ application: SanitizedApplicationPresence,
        includesWindowTitle: Bool
    ) throws -> CompanionApplicationContextV2 {
        try validateLength(
            application.displayName,
            field: "data.application.displayName",
            maximum: 120
        )
        let activity = try application.activity.map { activity in
            if let customLabel = activity.customLabel {
                try validateLength(
                    customLabel,
                    field: "data.application.activity.customLabel",
                    maximum: 80
                )
            }
            return CompanionActivityV2(key: activity.key, customLabel: activity.customLabel)
        }
        let window = try includesWindowTitle
            ? application.windowTitle.map { title in
                try validateLength(title, field: "data.application.window.title", maximum: 500)
                return CompanionWindowV2(title: title)
            }
            : nil
        let icon: CompanionIconV2? = application.iconURL.flatMap { url in
            guard url.scheme?.lowercased() == "https" else { return nil }
            return CompanionIconV2(url: url.absoluteString)
        }
        return CompanionApplicationContextV2(
            displayName: application.displayName,
            activity: activity,
            window: window,
            icon: icon
        )
    }

    private func makeMedia(
        _ media: SanitizedMediaPresence,
        artworkURL: URL?
    ) throws -> CompanionMomentMediaV1 {
        for (value, field) in [
            (media.title, "data.media.title"),
            (media.artist, "data.media.artist"),
            (media.album, "data.media.album"),
        ] {
            if let value { try validateLength(value, field: field, maximum: 300) }
        }
        if let player = media.playerDisplayName {
            try validateLength(player, field: "data.media.player.displayName", maximum: 120)
        }

        let duration = try media.playback.durationSeconds.map {
            try milliseconds(from: $0, field: "data.media.playback.durationMs")
        }
        var position = try media.playback.positionSeconds.map {
            try milliseconds(from: $0, field: "data.media.playback.positionMs")
        }
        if let duration, let currentPosition = position {
            position = min(duration, currentPosition)
        }

        let artwork = try artworkURL.map { url in
            guard url.absoluteString.range(
                of: #"^https://[^?#]+/[0-9a-f]{2}/[0-9a-f]{64}\.png$"#,
                options: .regularExpression
            ) != nil else {
                throw CompanionMomentMappingError.invalidArtworkURL
            }
            return CompanionMediaArtworkV2(url: url.absoluteString)
        }
        return CompanionMomentMediaV1(
            kind: media.kind,
            title: media.title,
            artist: media.artist,
            album: media.album,
            player: media.playerDisplayName.map(CompanionPlayerV2.init(displayName:)),
            playback: CompanionMomentPlaybackV1(
                state: media.playback.state,
                durationMilliseconds: duration,
                positionMilliseconds: position
            ),
            artwork: artwork,
            link: media.playbackURL.map { CompanionMediaLinkV2(url: $0.absoluteString) }
        )
    }

    private func milliseconds(from seconds: Double, field: String) throws -> Int {
        guard seconds.isFinite, seconds >= 0 else {
            throw CompanionMomentMappingError.invalidNumber(field: field)
        }
        let value = (seconds * 1_000).rounded()
        guard value <= Double(CompanionProtocolV2.maximumSafeInteger) else {
            throw CompanionMomentMappingError.invalidNumber(field: field)
        }
        return Int(value)
    }

    private func validateLength(_ value: String, field: String, maximum: Int) throws {
        guard value.unicodeScalars.count <= maximum else {
            throw CompanionMomentMappingError.textTooLong(
                field: field,
                maximumUnicodeScalars: maximum
            )
        }
    }
}
