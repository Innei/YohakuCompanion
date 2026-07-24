import Foundation
import SQLite3

protocol CompanionMediaPlaybackLinkResolving: Sendable {
    func resolvePlaybackURL(for mediaInfo: MediaInfo) async -> URL?
    func resolveArtworkData(for mediaInfo: MediaInfo) async -> Data?
}

extension CompanionMediaPlaybackLinkResolving {
    func resolveArtworkData(for _: MediaInfo) async -> Data? {
        nil
    }
}

typealias QQMusicSongDetailsLoader = @Sendable ([String]) async -> [MediaPlaybackQueueTrack]
typealias NetEaseMusicArtworkLoader = @Sendable (URL) async -> Data?

actor CompanionMediaPlaybackLinkResolver: CompanionMediaPlaybackLinkResolving {
    static let shared = CompanionMediaPlaybackLinkResolver()

    private struct CachedResolution: Sendable {
        let query: CompanionMediaPlaybackLinkQuery
        let url: URL?
        let resolvedAt: Date
    }

    private let homeDirectory: URL
    private let cacheLifetime: TimeInterval
    private let qqMusicSongDetailsLoader: QQMusicSongDetailsLoader
    private let netEaseMusicArtworkLoader: NetEaseMusicArtworkLoader
    private var cachedResolution: CachedResolution?

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheLifetime: TimeInterval = 15,
        qqMusicSongDetailsLoader: @escaping QQMusicSongDetailsLoader = {
            await QQMusicSongDetails.fetch(songMIDs: $0)
        },
        netEaseMusicArtworkLoader: @escaping NetEaseMusicArtworkLoader = {
            await NetEaseMusicArtworkDownloader.fetch(from: $0)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.cacheLifetime = max(0, cacheLifetime)
        self.qqMusicSongDetailsLoader = qqMusicSongDetailsLoader
        self.netEaseMusicArtworkLoader = netEaseMusicArtworkLoader
    }

    func resolvePlaybackURL(for mediaInfo: MediaInfo) async -> URL? {
        guard let query = CompanionMediaPlaybackLinkQuery(mediaInfo: mediaInfo) else {
            return nil
        }
        if let cachedResolution, cachedResolution.query == query {
            let cacheAge = Date().timeIntervalSince(cachedResolution.resolvedAt)
            if cacheAge >= 0, cacheAge < cacheLifetime {
                return cachedResolution.url
            }
        }

        let homeDirectory = homeDirectory
        let qqMusicSongDetailsLoader = qqMusicSongDetailsLoader
        let task = Task.detached(priority: .utility) {
            await Self.resolve(
                query: query,
                homeDirectory: homeDirectory,
                qqMusicSongDetailsLoader: qqMusicSongDetailsLoader
            )
        }
        let url = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        guard !Task.isCancelled else { return nil }

        cachedResolution = CachedResolution(query: query, url: url, resolvedAt: .now)
        return url
    }

    func resolveArtworkData(for mediaInfo: MediaInfo) async -> Data? {
        guard let query = CompanionMediaPlaybackLinkQuery(mediaInfo: mediaInfo),
              query.applicationIdentifier
                == CompanionMediaPlaybackLinkQuery.netEaseMusicBundleIdentifier
        else {
            return nil
        }

        let homeDirectory = homeDirectory
        let task = Task.detached(priority: .utility) {
            let url = NetEaseMusicPlaybackQueue.playingListURL(
                homeDirectory: homeDirectory
            )
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return nil as URL?
            }
            return NetEaseMusicPlaybackQueue.resolveArtworkURL(query: query, data: data)
        }
        let artworkURL = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        guard !Task.isCancelled, let artworkURL else { return nil }
        return await netEaseMusicArtworkLoader(artworkURL)
    }

    private nonisolated static func resolve(
        query: CompanionMediaPlaybackLinkQuery,
        homeDirectory: URL,
        qqMusicSongDetailsLoader: QQMusicSongDetailsLoader
    ) async -> URL? {
        switch query.applicationIdentifier {
        case CompanionMediaPlaybackLinkQuery.qqMusicBundleIdentifier:
            let applicationSupportURL = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent("com.tencent.QQMusicMac", isDirectory: true)
                .appendingPathComponent("Data", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("QQMusicMac", isDirectory: true)
            let playingListURL = applicationSupportURL
                .appendingPathComponent("iTemp", isDirectory: true)
                .appendingPathComponent("PlayingList.archive", isDirectory: false)
            if let data = try? Data(contentsOf: playingListURL, options: [.mappedIfSafe]),
               let url = QQMusicPlaybackQueue.resolve(query: query, archiveData: data)
            {
                return url
            }
            if let url = QQMusicSongDatabase.resolve(
                query: query,
                databaseURL: applicationSupportURL.appendingPathComponent(
                    "qqmusic.sqlite",
                    isDirectory: false
                )
            ) {
                return url
            }

            let songMIDs = QQMusicAutoMixCache.recentSongMIDs(
                directoryURL: applicationSupportURL.appendingPathComponent(
                    "AutoMixMir",
                    isDirectory: true
                )
            )
            guard !songMIDs.isEmpty, !Task.isCancelled else { return nil }
            let candidates = await qqMusicSongDetailsLoader(songMIDs)
            guard !Task.isCancelled,
                  let match = MediaPlaybackQueueMatcher.match(
                    query: query,
                    candidates: candidates
                  )
            else {
                return nil
            }
            return CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: match.identifier)

        case CompanionMediaPlaybackLinkQuery.netEaseMusicBundleIdentifier:
            let url = NetEaseMusicPlaybackQueue.playingListURL(
                homeDirectory: homeDirectory
            )
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                return nil
            }
            return NetEaseMusicPlaybackQueue.resolve(query: query, data: data)

        default:
            return nil
        }
    }
}

enum QQMusicAutoMixCache {
    private struct Entry {
        let songMID: String
        let activityDate: Date
    }

    private static let maximumCandidateCount = 16

    static func recentSongMIDs(directoryURL: URL) -> [String] {
        guard directoryURL.isFileURL else { return [] }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentAccessDateKey,
            .contentModificationDateKey,
            .creationDateKey,
        ]
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL -> Entry? in
            guard fileURL.pathExtension.lowercased() == "mir",
                  let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true
            else {
                return nil
            }

            let songMID = fileURL.deletingPathExtension().lastPathComponent
            guard CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: songMID) != nil else {
                return nil
            }
            let activityDate = [
                values.contentAccessDate,
                values.contentModificationDate,
                values.creationDate,
            ]
            .compactMap { $0 }
            .max() ?? .distantPast
            return Entry(songMID: songMID, activityDate: activityDate)
        }
        .sorted { left, right in
            if left.activityDate != right.activityDate {
                return left.activityDate > right.activityDate
            }
            return left.songMID < right.songMID
        }
        .prefix(maximumCandidateCount)
        .map(\.songMID)
    }
}

enum QQMusicSongDetails {
    private struct Response: Decodable {
        let code: Int
        let data: [Song]
    }

    private struct Song: Decodable {
        struct Singer: Decodable {
            let name: String?
        }

        struct Album: Decodable {
            let name: String?
        }

        let mid: String
        let name: String?
        let interval: Int?
        let singer: [Singer]?
        let album: Album?
    }

    private static let maximumResponseBytes = 1_000_000

    static func fetch(songMIDs: [String]) async -> [MediaPlaybackQueueTrack] {
        guard !songMIDs.isEmpty else { return [] }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "c.y.qq.com"
        components.path = "/v8/fcg-bin/fcg_play_single_song.fcg"
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "songmid", value: songMIDs.joined(separator: ",")),
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  data.count <= maximumResponseBytes
            else {
                return []
            }
            return tracks(from: data, requestedSongMIDs: songMIDs)
        } catch {
            return []
        }
    }

    static func tracks(
        from data: Data,
        requestedSongMIDs: [String]
    ) -> [MediaPlaybackQueueTrack] {
        guard data.count <= maximumResponseBytes,
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.code == 0
        else {
            return []
        }

        let requestedSongMIDs = Set(requestedSongMIDs)
        return response.data.compactMap { song in
            guard requestedSongMIDs.contains(song.mid),
                  CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: song.mid) != nil,
                  let title = song.name
            else {
                return nil
            }
            return MediaPlaybackQueueTrack(
                identifier: song.mid,
                title: title,
                artists: song.singer?.compactMap(\.name) ?? [],
                album: song.album?.name,
                durationSeconds: song.interval.flatMap { $0 > 0 ? Double($0) : nil }
            )
        }
    }
}

enum QQMusicSongDatabase {
    private static let query = """
        SELECT id, name, singer, album, K_SONG_RESERVE1, K_SONG_RESERVE12
        FROM SONGS
        WHERE name = ? COLLATE NOCASE
          AND K_SONG_RESERVE1 <> ''
        LIMIT 64
        """
    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    static func resolve(
        query playbackQuery: CompanionMediaPlaybackLinkQuery,
        databaseURL: URL
    ) -> URL? {
        guard databaseURL.isFileURL else { return nil }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let bindResult = playbackQuery.lookupTitle.withCString { title in
            sqlite3_bind_text(statement, 1, title, -1, transientDestructor)
        }
        guard bindResult == SQLITE_OK else { return nil }

        var candidates: [MediaPlaybackQueueTrack] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard sqlite3_column_int64(statement, 0) > 0,
                  let title = text(in: statement, column: 1),
                  let songMID = text(in: statement, column: 4),
                  CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: songMID) != nil
            else {
                continue
            }

            let singer = text(in: statement, column: 2)
            let album = text(in: statement, column: 3)
            let durationMilliseconds = sqlite3_column_int64(statement, 5)
            candidates.append(
                MediaPlaybackQueueTrack(
                    identifier: songMID,
                    title: title,
                    artists: singer?
                        .components(separatedBy: .newlines)
                        .compactMap(MediaPlaybackQueueMatcher.normalized) ?? [],
                    album: album,
                    durationSeconds: durationMilliseconds > 0
                        ? Double(durationMilliseconds) / 1_000
                        : nil
                )
            )
        }

        guard let match = MediaPlaybackQueueMatcher.match(
            query: playbackQuery,
            candidates: candidates
        ) else {
            return nil
        }
        return CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: match.identifier)
    }

    private static func text(
        in statement: OpaquePointer,
        column: Int32
    ) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }
}

struct CompanionMediaPlaybackLinkQuery: Equatable, Sendable {
    static let qqMusicBundleIdentifier = "com.tencent.QQMusicMac"
    static let netEaseMusicBundleIdentifier = "com.netease.163music"

    let applicationIdentifier: String
    let lookupTitle: String
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Double?

    init?(mediaInfo: MediaInfo) {
        guard let applicationIdentifier = mediaInfo.applicationIdentifier,
              applicationIdentifier == Self.qqMusicBundleIdentifier
                || applicationIdentifier == Self.netEaseMusicBundleIdentifier,
              let lookupTitle = mediaInfo.name?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !lookupTitle.isEmpty,
              let title = MediaPlaybackQueueMatcher.normalized(lookupTitle)
        else {
            return nil
        }

        self.applicationIdentifier = applicationIdentifier
        self.lookupTitle = lookupTitle.precomposedStringWithCanonicalMapping
        self.title = title
        artist = MediaPlaybackQueueMatcher.normalized(mediaInfo.artist)
        album = MediaPlaybackQueueMatcher.normalized(mediaInfo.album)
        durationSeconds = mediaInfo.duration
    }
}

struct MediaPlaybackQueueTrack: Equatable, Sendable {
    let identifier: String
    let title: String
    let artists: [String]
    let album: String?
    let durationSeconds: Double?
    let artworkURL: URL?

    init(
        identifier: String,
        title: String,
        artists: [String],
        album: String?,
        durationSeconds: Double?,
        artworkURL: URL? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.artists = artists
        self.album = album
        self.durationSeconds = durationSeconds
        self.artworkURL = artworkURL
    }
}

enum MediaPlaybackQueueMatcher {
    private struct RankedCandidate {
        let score: Int
        let track: MediaPlaybackQueueTrack
    }

    static func match(
        query: CompanionMediaPlaybackLinkQuery,
        candidates: [MediaPlaybackQueueTrack]
    ) -> MediaPlaybackQueueTrack? {
        let ranked = candidates.compactMap { candidate -> RankedCandidate? in
            guard normalized(candidate.title) == query.title else { return nil }

            var score = 100
            if let expectedDuration = query.durationSeconds,
               let candidateDuration = candidate.durationSeconds
            {
                let difference = abs(expectedDuration - candidateDuration)
                guard difference <= 2 else { return nil }
                score += difference < 0.5 ? 30 : 20
            }

            if let expectedArtist = query.artist, !candidate.artists.isEmpty {
                guard artistsOverlap(expectedArtist, candidate.artists) else { return nil }
                score += 30
            }

            if let expectedAlbum = query.album,
               let candidateAlbum = normalized(candidate.album),
               candidateAlbum == expectedAlbum
            {
                score += 10
            }

            return RankedCandidate(score: score, track: candidate)
        }
        .sorted { left, right in
            if left.score != right.score { return left.score > right.score }
            return left.track.identifier < right.track.identifier
        }

        guard let first = ranked.first else { return nil }
        if ranked.dropFirst().first?.score == first.score,
           ranked.dropFirst().first?.track.identifier != first.track.identifier
        {
            return nil
        }
        return first.track
    }

    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let collapsed = folded
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func artistsOverlap(_ expectedArtist: String, _ candidateArtists: [String]) -> Bool {
        let expected = artistComponents(expectedArtist)
        let candidates = Set(candidateArtists.flatMap(artistComponents))
        return !expected.isDisjoint(with: candidates)
    }

    private static func artistComponents(_ value: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/／,，、&＆;；")
        let components = value.components(separatedBy: separators).compactMap(normalized)
        return Set(components.isEmpty ? [value] : components)
    }
}

enum QQMusicPlaybackQueue {
    static func resolve(
        query: CompanionMediaPlaybackLinkQuery,
        archiveData: Data
    ) -> URL? {
        guard let songs = decodeSongs(from: archiveData) else { return nil }
        let candidates = songs.compactMap { song -> MediaPlaybackQueueTrack? in
            guard song.songID > 0,
                  let title = song.name,
                  let songMID = song.songMID,
                  CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: songMID) != nil
            else {
                return nil
            }
            return MediaPlaybackQueueTrack(
                identifier: songMID,
                title: title,
                artists: song.singers.compactMap(\.name),
                album: song.album?.name,
                durationSeconds: song.durationSeconds.map(Double.init)
            )
        }
        guard let match = MediaPlaybackQueueMatcher.match(query: query, candidates: candidates) else {
            return nil
        }
        return CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: match.identifier)
    }

    private static func decodeSongs(from data: Data) -> [QQMusicArchivedSong]? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.setClass(QQMusicArchivedPlayingList.self, forClassName: "ListBase")
        unarchiver.setClass(QQMusicArchivedSong.self, forClassName: "SongInfo")
        unarchiver.setClass(QQMusicArchivedSinger.self, forClassName: "SingerInfo")
        unarchiver.setClass(QQMusicArchivedAlbum.self, forClassName: "AlbumInfo")
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }

        let playingList = unarchiver.decodeObject(
            of: QQMusicArchivedPlayingList.self,
            forKey: "PlayingList"
        )
        guard unarchiver.error == nil else { return nil }
        return playingList?.songs
    }
}

final class QQMusicArchivedPlayingList: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let songs: [QQMusicArchivedSong]

    init(songs: [QQMusicArchivedSong]) {
        self.songs = songs
        super.init()
    }

    required init?(coder: NSCoder) {
        songs = coder.decodeObject(
            of: [NSArray.self, QQMusicArchivedSong.self],
            forKey: "ListData"
        ) as? [QQMusicArchivedSong] ?? []
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(songs, forKey: "ListData")
    }
}

final class QQMusicArchivedSong: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let songID: Int64
    let songMID: String?
    let name: String?
    let durationSeconds: Int?
    let singers: [QQMusicArchivedSinger]
    let album: QQMusicArchivedAlbum?

    init(
        songID: Int64,
        songMID: String?,
        name: String?,
        durationSeconds: Int?,
        singers: [QQMusicArchivedSinger],
        album: QQMusicArchivedAlbum?
    ) {
        self.songID = songID
        self.songMID = songMID
        self.name = name
        self.durationSeconds = durationSeconds
        self.singers = singers
        self.album = album
        super.init()
    }

    required init?(coder: NSCoder) {
        songID = coder.decodeInt64(forKey: "songId")
        songMID = coder.decodeObject(of: NSString.self, forKey: "song_Mid") as String?
        name = coder.decodeObject(of: NSString.self, forKey: "songName") as String?
        durationSeconds = (
            coder.decodeObject(of: NSNumber.self, forKey: "song_Duration")
        )?.intValue
        singers = coder.decodeObject(
            of: [NSArray.self, QQMusicArchivedSinger.self],
            forKey: "singerList"
        ) as? [QQMusicArchivedSinger] ?? []
        album = coder.decodeObject(of: QQMusicArchivedAlbum.self, forKey: "albumInfo")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(songID, forKey: "songId")
        coder.encode(songMID, forKey: "song_Mid")
        coder.encode(name, forKey: "songName")
        coder.encode(durationSeconds.map(NSNumber.init(value:)), forKey: "song_Duration")
        coder.encode(singers, forKey: "singerList")
        coder.encode(album, forKey: "albumInfo")
    }
}

final class QQMusicArchivedSinger: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let name: String?

    init(name: String?) {
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "name") as String?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
    }
}

final class QQMusicArchivedAlbum: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let name: String?

    init(name: String?) {
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) {
        name = coder.decodeObject(of: NSString.self, forKey: "name") as String?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
    }
}

enum NetEaseMusicPlaybackQueue {
    static func playingListURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("com.netease.163music", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("file_storage", isDirectory: true)
            .appendingPathComponent("webdata", isDirectory: true)
            .appendingPathComponent("file", isDirectory: true)
            .appendingPathComponent("playingList", isDirectory: false)
    }

    static func resolve(query: CompanionMediaPlaybackLinkQuery, data: Data) -> URL? {
        guard let match = resolveTrack(query: query, data: data) else { return nil }
        return CompanionMediaPlaybackURLPolicy.netEaseMusicURL(songID: match.identifier)
    }

    static func resolveArtworkURL(
        query: CompanionMediaPlaybackLinkQuery,
        data: Data
    ) -> URL? {
        resolveTrack(query: query, data: data)?.artworkURL
    }

    private static func resolveTrack(
        query: CompanionMediaPlaybackLinkQuery,
        data: Data
    ) -> MediaPlaybackQueueTrack? {
        guard let queue = try? JSONDecoder().decode(NetEaseMusicPlayingList.self, from: data) else {
            return nil
        }
        let candidates = queue.list.compactMap { entry -> MediaPlaybackQueueTrack? in
            guard let track = entry.track,
                  let identifier = track.id?.value ?? entry.id?.value,
                  CompanionMediaPlaybackURLPolicy.netEaseMusicURL(songID: identifier) != nil,
                  let title = track.name
            else {
                return nil
            }
            return MediaPlaybackQueueTrack(
                identifier: identifier,
                title: title,
                artists: track.artists?.compactMap(\.name) ?? [],
                album: track.album?.name,
                durationSeconds: track.duration.map { Double($0) / 1_000 },
                artworkURL: NetEaseMusicArtworkURLPolicy.normalizedURL(
                    track.album?.picUrl ?? track.album?.cover
                )
            )
        }
        return MediaPlaybackQueueMatcher.match(query: query, candidates: candidates)
    }
}

enum NetEaseMusicArtworkURLPolicy {
    static func normalizedURL(_ value: String?) -> URL? {
        guard let value,
              var components = URLComponents(string: value),
              components.scheme == "http" || components.scheme == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              isAllowedHost(host),
              !components.percentEncodedPath.isEmpty
        else {
            return nil
        }

        components.scheme = "https"
        components.host = host
        components.queryItems = [URLQueryItem(name: "param", value: "512y512")]
        return components.url
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4,
              labels[1] == "music",
              labels[2] == "126",
              labels[3] == "net"
        else {
            return false
        }
        let shard = labels[0]
        return shard.first == "p"
            && shard.dropFirst().allSatisfy(\.isNumber)
            && shard.count > 1
    }
}

enum NetEaseMusicArtworkDownloader {
    private static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func fetch(from url: URL) async -> Data? {
        guard NetEaseMusicArtworkURLPolicy.normalizedURL(url.absoluteString) == url else {
            return nil
        }

        var request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 3
        )
        request.httpMethod = "GET"
        request.setValue("image/avif,image/webp,image/*", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.mimeType?.lowercased().hasPrefix("image/") == true,
                  !data.isEmpty,
                  data.count <= maximumResponseBytes
            else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

private struct NetEaseMusicPlayingList: Decodable {
    let list: [NetEaseMusicPlayingListEntry]
}

private struct NetEaseMusicPlayingListEntry: Decodable {
    let id: LosslessStringIdentifier?
    let track: NetEaseMusicTrack?
}

private struct NetEaseMusicTrack: Decodable {
    struct Artist: Decodable {
        let name: String?
    }

    struct Album: Decodable {
        let name: String?
        let picUrl: String?
        let cover: String?
    }

    let id: LosslessStringIdentifier?
    let name: String?
    let duration: Int?
    let artists: [Artist]?
    let album: Album?
}

private struct LosslessStringIdentifier: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
        } else if let value = try? container.decode(Int64.self) {
            self.value = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a string or integer identifier."
                )
            )
        }
    }
}
