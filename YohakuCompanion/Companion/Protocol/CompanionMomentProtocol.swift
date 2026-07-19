import Foundation

extension CompanionProtocolV2 {
    static let momentSchema = "yohaku.companion.moment"
    static let momentSchemaVersion = 1
}

struct CompanionMomentRequestMetaV1: Codable, Equatable, Sendable {
    let schema = CompanionProtocolV2.momentSchema
    let schemaVersion = CompanionProtocolV2.momentSchemaVersion
    let requestID: String
    let observedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion
        case requestID = "requestId"
        case observedAt
    }
}

struct CompanionMomentPlaybackV1: Codable, Equatable, Sendable {
    let state: CompanionMediaPlaybackState
    let durationMilliseconds: Int?
    let positionMilliseconds: Int?

    private enum CodingKeys: String, CodingKey {
        case state
        case durationMilliseconds = "durationMs"
        case positionMilliseconds = "positionMs"
    }
}

struct CompanionMomentMediaV1: Codable, Equatable, Sendable {
    let kind: CompanionMediaKind
    let title: String?
    let artist: String?
    let album: String?
    let player: CompanionPlayerV2?
    let playback: CompanionMomentPlaybackV1
    let artwork: CompanionMediaArtworkV2?
    let link: CompanionMediaLinkV2?

    init(
        kind: CompanionMediaKind,
        title: String?,
        artist: String?,
        album: String?,
        player: CompanionPlayerV2?,
        playback: CompanionMomentPlaybackV1,
        artwork: CompanionMediaArtworkV2?,
        link: CompanionMediaLinkV2?
    ) {
        self.kind = kind
        self.title = title
        self.artist = artist
        self.album = album
        self.player = player
        self.playback = playback
        self.artwork = artwork
        self.link = link
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CompanionMediaKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        player = try container.decodeIfPresent(CompanionPlayerV2.self, forKey: .player)
        playback = try container.decode(CompanionMomentPlaybackV1.self, forKey: .playback)
        artwork = try container.decodeIfPresent(CompanionMediaArtworkV2.self, forKey: .artwork)
        link = try container.decodeIfPresent(CompanionMediaLinkV2.self, forKey: .link)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeOptional(title, forKey: .title)
        try container.encodeOptional(artist, forKey: .artist)
        try container.encodeOptional(album, forKey: .album)
        try container.encodeOptional(player, forKey: .player)
        try container.encode(playback, forKey: .playback)
        try container.encodeOptional(artwork, forKey: .artwork)
        try container.encodeOptional(link, forKey: .link)
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title, artist, album, player, playback, artwork, link
    }
}

struct CompanionMomentDataV1: Codable, Equatable, Sendable {
    let content: String
    let application: CompanionApplicationContextV2?
    let media: CompanionMomentMediaV1?

    init(
        content: String,
        application: CompanionApplicationContextV2?,
        media: CompanionMomentMediaV1?
    ) {
        self.content = content
        self.application = application
        self.media = media
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(String.self, forKey: .content)
        application = try container.decodeIfPresent(
            CompanionApplicationContextV2.self,
            forKey: .application
        )
        media = try container.decodeIfPresent(CompanionMomentMediaV1.self, forKey: .media)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encodeOptional(application, forKey: .application)
        try container.encodeOptional(media, forKey: .media)
    }

    private enum CodingKeys: String, CodingKey {
        case content, application, media
    }
}

struct CompanionMomentRequestV1: Codable, Equatable, Sendable {
    let meta: CompanionMomentRequestMetaV1
    let data: CompanionMomentDataV1
}

struct CompanionMomentMutationDataV1: Decodable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let url: URL?
}

struct CompanionMomentMutationResponseV1: Decodable, Equatable, Sendable {
    let meta: CompanionResponseMetaV2
    let data: CompanionMomentMutationDataV1
}

extension CompanionMomentMutationResponseV1: CompanionResponseEnvelopeV2 {}

private extension KeyedEncodingContainer {
    mutating func encodeOptional<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
