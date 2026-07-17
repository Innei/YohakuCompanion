import Foundation
import SQLite3

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): return message
        }
    }
}

@main
private struct MediaPlaybackLinksHarness {
    static func main() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory.appendingPathComponent(
            "yohaku-media-links-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }

        try writeQQMusicFixture(to: temporaryHome)
        try writeQQMusicDatabaseFixture(to: temporaryHome)
        try writeQQMusicAutoMixFixture(to: temporaryHome)
        try writeNetEaseMusicFixture(to: temporaryHome)

        let songDetailsData = try makeQQMusicSongDetailsFixture()
        let resolver = CompanionMediaPlaybackLinkResolver(
            homeDirectory: temporaryHome,
            qqMusicSongDetailsLoader: { songMIDs in
                QQMusicSongDetails.tracks(
                    from: songDetailsData,
                    requestedSongMIDs: songMIDs
                )
            }
        )
        try await verifiesQQMusicResolution(resolver: resolver)
        try await verifiesQQMusicDatabaseFallback(resolver: resolver)
        try await verifiesQQMusicAutoMixFallback(resolver: resolver)
        try await verifiesNetEaseMusicResolution(resolver: resolver)
        try verifiesAmbiguousMatchesFailClosed()
        try verifiesProviderURLPolicy()
        try await verifiesUnsupportedPlayersRemainUnlinked(resolver: resolver)
        print("Media playback link behavior passed")
    }

    private static func verifiesQQMusicDatabaseFallback(
        resolver: CompanionMediaPlaybackLinkResolver
    ) async throws {
        let info = makeMediaInfo(
            title: "眉南边",
            artist: "银临",
            album: "离地十公分·A面",
            duration: 201,
            applicationIdentifier: CompanionMediaPlaybackLinkQuery.qqMusicBundleIdentifier
        )
        let url = await resolver.resolvePlaybackURL(for: info)
        try expect(
            url?.absoluteString == "https://y.qq.com/n/ryqq/songDetail/000hTQrG2IWVPw",
            "QQ Music did not fall back to the read-only song database for a radio track"
        )
    }

    private static func verifiesQQMusicResolution(
        resolver: CompanionMediaPlaybackLinkResolver
    ) async throws {
        let info = makeMediaInfo(
            title: "Never Let You Down 秋夜独白",
            artist: "BEAUZ",
            album: "Never Let You Down 秋夜独白",
            duration: 160,
            applicationIdentifier: CompanionMediaPlaybackLinkQuery.qqMusicBundleIdentifier
        )
        let url = await resolver.resolvePlaybackURL(for: info)
        try expect(
            url?.absoluteString == "https://y.qq.com/n/ryqq/songDetail/001lzbAN14boA4",
            "QQ Music did not resolve the current queue entry's song_Mid"
        )
    }

    private static func verifiesQQMusicAutoMixFallback(
        resolver: CompanionMediaPlaybackLinkResolver
    ) async throws {
        let info = makeMediaInfo(
            title: "问棋",
            artist: "扇宝",
            album: "问棋",
            duration: 193,
            applicationIdentifier: CompanionMediaPlaybackLinkQuery.qqMusicBundleIdentifier
        )
        let url = await resolver.resolvePlaybackURL(for: info)
        try expect(
            url?.absoluteString == "https://y.qq.com/n/ryqq/songDetail/000sxYlY1Oho1M",
            "QQ Music did not resolve a radio track from its AutoMix song MID cache"
        )
    }

    private static func verifiesNetEaseMusicResolution(
        resolver: CompanionMediaPlaybackLinkResolver
    ) async throws {
        let info = makeMediaInfo(
            title: "让我走向你",
            artist: "忘乡",
            album: "让我走向你",
            duration: 168.671,
            applicationIdentifier: CompanionMediaPlaybackLinkQuery.netEaseMusicBundleIdentifier
        )
        let url = await resolver.resolvePlaybackURL(for: info)
        try expect(
            url?.absoluteString == "https://music.163.com/song?id=3339827986",
            "NetEase Music did not resolve the current playingList track.id"
        )
    }

    private static func verifiesAmbiguousMatchesFailClosed() throws {
        let info = makeMediaInfo(
            title: "Duplicate",
            artist: "Artist",
            album: nil,
            duration: 180,
            applicationIdentifier: CompanionMediaPlaybackLinkQuery.qqMusicBundleIdentifier
        )
        guard let query = CompanionMediaPlaybackLinkQuery(mediaInfo: info) else {
            throw HarnessFailure.assertion("could not construct ambiguity query")
        }
        let match = MediaPlaybackQueueMatcher.match(
            query: query,
            candidates: [
                MediaPlaybackQueueTrack(
                    identifier: "00123456789ABC",
                    title: "Duplicate",
                    artists: ["Artist"],
                    album: nil,
                    durationSeconds: 180
                ),
                MediaPlaybackQueueTrack(
                    identifier: "00987654321ABC",
                    title: "Duplicate",
                    artists: ["Artist"],
                    album: nil,
                    durationSeconds: 180
                ),
            ]
        )
        try expect(match == nil, "an ambiguous local queue match produced a link")
    }

    private static func verifiesProviderURLPolicy() throws {
        try expect(
            CompanionMediaPlaybackURLPolicy.qqMusicURL(songMID: "001lzbAN14boA4") != nil,
            "a valid QQ Music song_Mid was rejected"
        )
        try expect(
            CompanionMediaPlaybackURLPolicy.netEaseMusicURL(songID: "3339827986") != nil,
            "a valid NetEase Music song ID was rejected"
        )
        try expect(
            !CompanionMediaPlaybackURLPolicy.isAllowed(
                URL(string: "https://y.qq.com.evil.example/n/ryqq/songDetail/001lzbAN14boA4")!
            ),
            "a spoofed QQ Music host was accepted"
        )
        try expect(
            !CompanionMediaPlaybackURLPolicy.isAllowed(
                URL(string: "https://music.163.com/song?id=3339827986&utm_source=tracker")!
            ),
            "a tracking query was accepted on a NetEase Music link"
        )
    }

    private static func verifiesUnsupportedPlayersRemainUnlinked(
        resolver: CompanionMediaPlaybackLinkResolver
    ) async throws {
        let info = makeMediaInfo(
            title: "Never Let You Down 秋夜独白",
            artist: "BEAUZ",
            album: nil,
            duration: 160,
            applicationIdentifier: "com.example.player"
        )
        let url = await resolver.resolvePlaybackURL(for: info)
        try expect(
            url == nil,
            "an unsupported player produced a playback link"
        )
    }

    private static func makeMediaInfo(
        title: String,
        artist: String?,
        album: String?,
        duration: Double?,
        applicationIdentifier: String
    ) -> MediaInfo {
        MediaInfo(
            name: title,
            artist: artist,
            album: album,
            image: nil,
            duration: duration,
            elapsedTime: 0,
            processID: 0,
            processName: "Player",
            executablePath: "",
            playing: true,
            applicationIdentifier: applicationIdentifier
        )
    }

    private static func writeQQMusicFixture(to home: URL) throws {
        let destination = home
            .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iTemp", isDirectory: true)
            .appendingPathComponent("PlayingList.archive", isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let songs = [
            FixtureQQSong(
                songID: 479_441_930,
                songMID: "001lzbAN14boA4",
                name: "Never Let You Down 秋夜独白",
                duration: 160,
                singers: ["BEAUZ", "Miles Away", "RYYZN", "陈雪凝"],
                album: "Never Let You Down 秋夜独白"
            ),
            FixtureQQSong(
                songID: 123,
                songMID: "00123456789ABC",
                name: "Never Let You Down 秋夜独白",
                duration: 200,
                singers: ["Someone Else"],
                album: "Other Album"
            ),
        ]
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.setClassName("ListBase", for: FixtureQQPlayingList.self)
        archiver.setClassName("SongInfo", for: FixtureQQSong.self)
        archiver.setClassName("SingerInfo", for: FixtureQQSinger.self)
        archiver.setClassName("AlbumInfo", for: FixtureQQAlbum.self)
        archiver.encode(FixtureQQPlayingList(songs: songs), forKey: "PlayingList")
        archiver.finishEncoding()
        try archiver.encodedData.write(to: destination, options: .atomic)
    }

    private static func writeNetEaseMusicFixture(to home: URL) throws {
        let destination = home
            .appendingPathComponent("Library/Containers/com.netease.163music/Data/Documents/storage/file_storage/webdata/file", isDirectory: true)
            .appendingPathComponent("playingList", isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fixture: [String: Any] = [
            "list": [
                [
                    "id": "3339827986",
                    "track": [
                        "id": 3_339_827_986,
                        "name": "让我走向你",
                        "duration": 168_671,
                        "artists": [["name": "忘乡"]],
                        "album": ["name": "让我走向你"],
                    ],
                ],
                [
                    "id": "1",
                    "track": [
                        "id": "1",
                        "name": "让我走向你",
                        "duration": 200_000,
                        "artists": [["name": "Other Artist"]],
                        "album": ["name": "Other Album"],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        try data.write(to: destination, options: .atomic)
    }

    private static func writeQQMusicDatabaseFixture(to home: URL) throws {
        let destination = home
            .appendingPathComponent("Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac", isDirectory: true)
            .appendingPathComponent("qqmusic.sqlite", isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            destination.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw HarnessFailure.assertion("could not create the QQ Music database fixture")
        }
        defer { sqlite3_close(database) }

        let sql = """
            CREATE TABLE SONGS (
                id INTEGER NOT NULL,
                name TEXT NOT NULL,
                singer TEXT NOT NULL,
                album TEXT NOT NULL,
                K_SONG_RESERVE1 TEXT NOT NULL,
                K_SONG_RESERVE12 INTEGER NOT NULL
            );
            INSERT INTO SONGS VALUES (
                349164426,
                '眉南边',
                '银临',
                '离地十公分·A面',
                '000hTQrG2IWVPw',
                201000
            );
            INSERT INTO SONGS VALUES (
                1,
                '眉南边',
                'Other Artist',
                'Other Album',
                '00123456789ABC',
                300000
            );
            """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw HarnessFailure.assertion("could not populate the QQ Music database fixture")
        }
    }

    private static func writeQQMusicAutoMixFixture(to home: URL) throws {
        let directory = home
            .appendingPathComponent(
                "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/AutoMixMir",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for filename in [
            "000sxYlY1Oho1M.mir",
            "000m07jK2MRSVg.mir",
            "not-a-song-id.mir",
        ] {
            try Data().write(to: directory.appendingPathComponent(filename))
        }
    }

    private static func makeQQMusicSongDetailsFixture() throws -> Data {
        let response: [String: Any] = [
            "code": 0,
            "data": [
                [
                    "mid": "000sxYlY1Oho1M",
                    "name": "问棋",
                    "interval": 193,
                    "singer": [["name": "扇宝"]],
                    "album": ["name": "问棋"],
                ],
                [
                    "mid": "000m07jK2MRSVg",
                    "name": "Goldfish Song",
                    "interval": 159,
                    "singer": [["name": "Goodmorning Pancake"]],
                    "album": ["name": "Ah!Chim!"],
                ],
                [
                    "mid": "00123456789ABC",
                    "name": "问棋",
                    "interval": 193,
                    "singer": [["name": "扇宝"]],
                    "album": ["name": "问棋"],
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}

@objc(YohakuFixtureQQPlayingList)
private final class FixtureQQPlayingList: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let songs: [FixtureQQSong]

    init(songs: [FixtureQQSong]) {
        self.songs = songs
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(songs, forKey: "ListData")
    }
}

@objc(YohakuFixtureQQSong)
private final class FixtureQQSong: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let songID: Int64
    let songMID: String
    let name: String
    let duration: Int
    let singers: [FixtureQQSinger]
    let album: FixtureQQAlbum

    init(
        songID: Int64,
        songMID: String,
        name: String,
        duration: Int,
        singers: [String],
        album: String
    ) {
        self.songID = songID
        self.songMID = songMID
        self.name = name
        self.duration = duration
        self.singers = singers.map(FixtureQQSinger.init(name:))
        self.album = FixtureQQAlbum(name: album)
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(songID, forKey: "songId")
        coder.encode(songMID, forKey: "song_Mid")
        coder.encode(name, forKey: "songName")
        coder.encode(NSNumber(value: duration), forKey: "song_Duration")
        coder.encode(singers, forKey: "singerList")
        coder.encode(album, forKey: "albumInfo")
    }
}

@objc(YohakuFixtureQQSinger)
private final class FixtureQQSinger: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let name: String

    init(name: String) {
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
    }
}

@objc(YohakuFixtureQQAlbum)
private final class FixtureQQAlbum: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let name: String

    init(name: String) {
        self.name = name
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    func encode(with coder: NSCoder) {
        coder.encode(name, forKey: "name")
    }
}
