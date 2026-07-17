import Foundation

enum CompanionMediaPlaybackURLPolicy {
    private static let qqMusicHost = "y.qq.com"
    private static let netEaseMusicHost = "music.163.com"

    static func qqMusicURL(songMID: String) -> URL? {
        guard isQQMusicSongMID(songMID) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = qqMusicHost
        components.path = "/n/ryqq/songDetail/\(songMID)"
        guard let url = components.url, isAllowed(url) else { return nil }
        return url
    }

    static func netEaseMusicURL(songID: String) -> URL? {
        guard isNetEaseMusicSongID(songID) else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = netEaseMusicHost
        components.path = "/song"
        components.queryItems = [URLQueryItem(name: "id", value: songID)]
        guard let url = components.url, isAllowed(url) else { return nil }
        return url
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased()
        else {
            return false
        }

        switch host {
        case qqMusicHost:
            guard components.query == nil else { return false }
            let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
            return segments.count == 4
                && segments[0] == "n"
                && segments[1] == "ryqq"
                && segments[2] == "songDetail"
                && isQQMusicSongMID(String(segments[3]))

        case netEaseMusicHost:
            guard components.path == "/song",
                  let queryItems = components.queryItems,
                  queryItems.count == 1,
                  queryItems[0].name == "id",
                  let songID = queryItems[0].value
            else {
                return false
            }
            return isNetEaseMusicSongID(songID)

        default:
            return false
        }
    }

    private static func isQQMusicSongMID(_ value: String) -> Bool {
        value.utf8.count == 14 && value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII
        }
    }

    private static func isNetEaseMusicSongID(_ value: String) -> Bool {
        guard (1...20).contains(value.utf8.count), value != "0" else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(Character(scalar))
        }
    }
}
