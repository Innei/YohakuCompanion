import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case unexpectedValue(caseName: String, actual: String?)
    case unexpectedButton(caseName: String, label: String?, url: String?)

    var description: String {
        switch self {
        case .unexpectedValue(let caseName, let actual):
            let renderedValue = actual.map { "'\($0)'" } ?? "nil"
            return "\(caseName) produced \(renderedValue)"
        case .unexpectedButton(let caseName, let label, let url):
            return "\(caseName) produced label=\(label ?? "nil"), url=\(url ?? "nil")"
        }
    }
}

@main
private struct DiscordTransportContractHarness {
    static func main() throws {
        try expectText("遥", equals: nil, caseName: "single CJK activity character")
        try expectText("X", equals: nil, caseName: "single ASCII activity character")
        try expectText("🎵", equals: nil, caseName: "single emoji activity character")
        try expectText("遥远", equals: "遥远", caseName: "two CJK activity characters")
        try expectText("🎵🎵", equals: "🎵🎵", caseName: "two emoji activity characters")

        let oversizedText = String(repeating: "遥", count: 129)
        let boundedText = DiscordTransportContract.text(oversizedText)
        guard boundedText?.count == 128 else {
            throw HarnessFailure.unexpectedValue(
                caseName: "Unicode activity character limit",
                actual: boundedText
            )
        }

        let singleCharacterAsset = DiscordTransportContract.assetIdentifier("x")
        guard singleCharacterAsset == "x" else {
            throw HarnessFailure.unexpectedValue(
                caseName: "single-character asset identifier",
                actual: singleCharacterAsset
            )
        }

        try expectAsset(
            "https://cdn.example.com/artwork/播放中.png?size=large",
            accepted: true,
            caseName: "public HTTPS artwork URL"
        )
        try expectAsset(
            "http://cdn.example.com/artwork.png",
            accepted: false,
            caseName: "insecure artwork URL"
        )
        try expectAsset(
            "https://user:secret@cdn.example.com/artwork.png",
            accepted: false,
            caseName: "credential-bearing artwork URL"
        )

        let oversizedArtworkURL = "https://cdn.example.com/" + String(repeating: "a", count: 280)
        try expectAsset(
            oversizedArtworkURL,
            accepted: false,
            caseName: "oversized artwork URL"
        )

        try expectAsset(
            String(repeating: "遥", count: 300),
            accepted: true,
            caseName: "maximum-length Unicode asset identifier"
        )
        try expectAsset(
            String(repeating: "遥", count: 301),
            accepted: false,
            caseName: "oversized Unicode asset identifier"
        )

        try expectButton(
            DiscordButton(label: "Open Yohaku", url: "https://innei.in"),
            label: "Open Yohaku",
            url: "https://innei.in",
            caseName: "public HTTPS Rich Presence button"
        )
        try expectButton(
            DiscordButton(label: "Open Yohaku", url: "http://innei.in"),
            label: nil,
            url: nil,
            caseName: "insecure Rich Presence button"
        )
        try expectButton(
            DiscordButton(
                label: "Open Yohaku",
                url: "https://innei.in/" + String(repeating: "a", count: 500)
            ),
            label: nil,
            url: nil,
            caseName: "oversized Rich Presence button URL"
        )

        let longButtonLabel = String(repeating: "遥", count: 33)
        try expectButton(
            DiscordButton(label: longButtonLabel, url: "https://innei.in"),
            label: String(repeating: "遥", count: 32),
            url: "https://innei.in",
            caseName: "Unicode Rich Presence button label limit"
        )

        try verifyArtworkRetentionAcrossProgressUpdates()

        print("Discord transport contract behavior passed")
    }

    private static func verifyArtworkRetentionAcrossProgressUpdates() throws {
        var cache = DiscordMediaArtworkCache()
        let firstTrack = DiscordMediaArtworkCache.MediaIdentity(
            title: "First Track",
            artist: "Artist",
            album: "Album",
            player: "Player",
            applicationIdentifier: "player.example"
        )
        let secondTrack = DiscordMediaArtworkCache.MediaIdentity(
            title: "Second Track",
            artist: "Artist",
            album: "Album",
            player: "Player",
            applicationIdentifier: "player.example"
        )
        let firstURL = "https://cdn.example.com/first.png?v=1"

        guard cache.resolve(identity: firstTrack, hostedURL: firstURL) == firstURL,
              cache.resolve(identity: firstTrack, hostedURL: nil) == firstURL
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "progress-only update retained hosted artwork",
                actual: nil
            )
        }

        guard cache.resolve(identity: secondTrack, hostedURL: nil) == nil else {
            throw HarnessFailure.unexpectedValue(
                caseName: "track change rejected stale hosted artwork",
                actual: firstURL
            )
        }

        _ = cache.resolve(identity: firstTrack, hostedURL: firstURL)
        cache.clear()
        guard cache.resolve(identity: firstTrack, hostedURL: nil) == nil else {
            throw HarnessFailure.unexpectedValue(
                caseName: "privacy clear removed hosted artwork",
                actual: firstURL
            )
        }
    }

    private static func expectText(
        _ input: String?,
        equals expected: String?,
        caseName: String
    ) throws {
        let actual = DiscordTransportContract.text(input)
        guard actual == expected else {
            throw HarnessFailure.unexpectedValue(caseName: caseName, actual: actual)
        }
    }


    private static func expectAsset(
        _ input: String,
        accepted: Bool,
        caseName: String
    ) throws {
        let actual = DiscordTransportContract.assetIdentifier(input)
        guard (actual != nil) == accepted else {
            throw HarnessFailure.unexpectedValue(caseName: caseName, actual: actual)
        }
    }

    private static func expectButton(
        _ input: DiscordButton,
        label expectedLabel: String?,
        url expectedURL: String?,
        caseName: String
    ) throws {
        let actual = DiscordTransportContract.button(input)
        guard actual?.label == expectedLabel, actual?.url == expectedURL else {
            throw HarnessFailure.unexpectedButton(
                caseName: caseName,
                label: actual?.label,
                url: actual?.url
            )
        }
    }
}
