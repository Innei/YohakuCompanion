import Foundation

enum SanitizedPresenceValidationError: Error, Equatable, Sendable {
    case missingRequiredText(field: String)
    case mediaIdentityMissing
}

enum LiveDeskAvailability: String, Codable, Sendable {
    case idle
    case active
}

enum CompanionMediaKind: String, Codable, Sendable {
    case music
    case podcast
    case video
    case unknown
}

enum CompanionMediaPlaybackState: String, Codable, Sendable {
    case playing
    case paused
}

struct SanitizedApplicationActivity: Equatable, Sendable {
    let key: String?
    let customLabel: String?

    init(key: String?, customLabel: String?) {
        self.key = PresenceTextNormalizer.optional(key)
        self.customLabel = PresenceTextNormalizer.optional(customLabel)
    }
}

struct SanitizedApplicationPresence: Equatable, Sendable {
    let displayName: String
    let activity: SanitizedApplicationActivity?
    let windowTitle: String?
    let iconURL: URL?

    init(
        displayName: String,
        activity: SanitizedApplicationActivity? = nil,
        windowTitle: String? = nil,
        iconURL: URL? = nil
    ) throws {
        self.displayName = try PresenceTextNormalizer.required(
            displayName,
            field: "application.displayName"
        )
        self.activity = activity
        self.windowTitle = PresenceTextNormalizer.optional(windowTitle)
        self.iconURL = iconURL
    }
}

struct SanitizedMediaPlayback: Equatable, Sendable {
    let state: CompanionMediaPlaybackState
    let durationSeconds: Double?
    let positionSeconds: Double?
    let sampledAt: Date
    let rate: Double
}

struct SanitizedMediaArtwork: Equatable, Sendable {
    let pngData: Data
    let contentHash: String
    let pixelWidth: Int
    let pixelHeight: Int
    let publicURL: URL?

    init(
        pngData: Data,
        contentHash: String,
        pixelWidth: Int,
        pixelHeight: Int,
        publicURL: URL? = nil
    ) {
        self.pngData = pngData
        self.contentHash = contentHash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.publicURL = publicURL
    }

    func hosted(at publicURL: URL?) -> Self {
        Self(
            pngData: pngData,
            contentHash: contentHash,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            publicURL: publicURL
        )
    }
}

struct SanitizedMediaPresence: Equatable, Sendable {
    let sessionID: UUID
    let kind: CompanionMediaKind
    let title: String?
    let artist: String?
    let album: String?
    let playerDisplayName: String?
    let playback: SanitizedMediaPlayback
    let artwork: SanitizedMediaArtwork?

    init(
        sessionID: UUID,
        kind: CompanionMediaKind,
        title: String?,
        artist: String?,
        album: String?,
        playerDisplayName: String?,
        playback: SanitizedMediaPlayback,
        artwork: SanitizedMediaArtwork? = nil
    ) throws {
        let normalizedTitle = PresenceTextNormalizer.optional(title)
        let normalizedArtist = PresenceTextNormalizer.optional(artist)
        guard normalizedTitle != nil || normalizedArtist != nil else {
            throw SanitizedPresenceValidationError.mediaIdentityMissing
        }

        self.sessionID = sessionID
        self.kind = kind
        self.title = normalizedTitle
        self.artist = normalizedArtist
        self.album = PresenceTextNormalizer.optional(album)
        self.playerDisplayName = PresenceTextNormalizer.optional(playerDisplayName)
        self.playback = playback
        self.artwork = artwork
    }

    func replacingArtwork(_ artwork: SanitizedMediaArtwork?) -> Self {
        Self(
            normalizedSessionID: sessionID,
            kind: kind,
            normalizedTitle: title,
            normalizedArtist: artist,
            normalizedAlbum: album,
            normalizedPlayerDisplayName: playerDisplayName,
            playback: playback,
            artwork: artwork
        )
    }

    private init(
        normalizedSessionID: UUID,
        kind: CompanionMediaKind,
        normalizedTitle: String?,
        normalizedArtist: String?,
        normalizedAlbum: String?,
        normalizedPlayerDisplayName: String?,
        playback: SanitizedMediaPlayback,
        artwork: SanitizedMediaArtwork?
    ) {
        sessionID = normalizedSessionID
        self.kind = kind
        title = normalizedTitle
        artist = normalizedArtist
        album = normalizedAlbum
        playerDisplayName = normalizedPlayerDisplayName
        self.playback = playback
        self.artwork = artwork
    }
}

struct SanitizedPresenceSnapshot: Equatable, Sendable {
    let observedAt: Date
    let application: SanitizedApplicationPresence?
    let media: SanitizedMediaPresence?

    var availability: LiveDeskAvailability {
        application == nil && media == nil ? .idle : .active
    }

    func replacingMediaArtwork(_ artwork: SanitizedMediaArtwork?) -> Self {
        Self(
            observedAt: observedAt,
            application: application,
            media: media?.replacingArtwork(artwork)
        )
    }
}

private enum PresenceTextNormalizer {
    static func optional(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return normalized.isEmpty ? nil : normalized
    }

    static func required(_ value: String, field: String) throws -> String {
        guard let normalized = optional(value) else {
            throw SanitizedPresenceValidationError.missingRequiredText(field: field)
        }
        return normalized
    }
}
