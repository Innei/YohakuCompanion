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
        try verifyRPCFrameStreaming()
        try verifyRPCPayloads()
        try verifyRPCResponses()
        try verifyIPCPathPriority()

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

    private static func verifyRPCFrameStreaming() throws {
        let firstPayload = Data("{\"evt\":\"READY\"}".utf8)
        let secondPayload = Data("ping-body".utf8)
        let firstFrame = try DiscordRPCFrameCodec.encode(
            opcode: .frame,
            payload: firstPayload
        )
        let secondFrame = try DiscordRPCFrameCodec.encode(
            opcode: .ping,
            payload: secondPayload
        )
        let stream = firstFrame + secondFrame

        var decoder = DiscordRPCFrameDecoder()
        guard try decoder.append(stream.prefix(3)).isEmpty,
              try decoder.append(stream.dropFirst(3).prefix(8)).isEmpty
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "fragmented RPC headers remained buffered",
                actual: "decoded prematurely"
            )
        }
        let decoded = try decoder.append(stream.dropFirst(11))
        guard decoded == [
            DiscordRPCFrame(opcode: .frame, payload: firstPayload),
            DiscordRPCFrame(opcode: .ping, payload: secondPayload),
        ] else {
            throw HarnessFailure.unexpectedValue(
                caseName: "fragmented and coalesced RPC frames",
                actual: "\(decoded)"
            )
        }

        var malformedDecoder = DiscordRPCFrameDecoder()
        do {
            _ = try malformedDecoder.append(Data([99, 0, 0, 0, 0, 0, 0, 0]))
            throw HarnessFailure.unexpectedValue(
                caseName: "unsupported RPC opcode",
                actual: "accepted"
            )
        } catch DiscordRPCProtocolError.invalidOpcode(99) {
            // Expected protocol rejection.
        }
    }

    private static func verifyRPCPayloads() throws {
        let handshakeFrame = try decodeSingleFrame(
            DiscordRPCPayload.handshake(applicationID: "1409932866091225098")
        )
        let handshake = try jsonObject(handshakeFrame.payload)
        guard handshakeFrame.opcode == .handshake,
              handshake["v"] as? Int == 1,
              handshake["client_id"] as? String == "1409932866091225098"
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "Discord RPC handshake",
                actual: String(data: handshakeFrame.payload, encoding: .utf8)
            )
        }

        let activity = try DiscordRPCActivity(
            name: "QQ 音乐",
            details: "冬月恋歌",
            state: "雪球",
            activityType: 2,
            statusDisplayType: 2,
            startTimestamp: 1_700_000_000_000,
            endTimestamp: 1_700_000_184_000,
            largeImageKey: "https://cdn.example.com/cover.png",
            largeImageText: "QQ 音乐",
            smallImageKey: "qqmusic",
            smallImageText: "QQ 音乐",
            buttons: [
                .init(label: "Open", url: "https://example.com/1"),
                .init(label: "Artist", url: "https://example.com/2"),
                .init(label: "Ignored", url: "https://example.com/3"),
            ]
        )
        let activityFrame = try decodeSingleFrame(
            DiscordRPCPayload.setActivity(
                processID: 4242,
                activity: activity,
                nonce: "activity-nonce"
            )
        )
        let command = try jsonObject(activityFrame.payload)
        let arguments = command["args"] as? [String: Any]
        let encodedActivity = arguments?["activity"] as? [String: Any]
        let timestamps = encodedActivity?["timestamps"] as? [String: Any]
        let assets = encodedActivity?["assets"] as? [String: Any]
        let buttons = encodedActivity?["buttons"] as? [[String: Any]]
        guard activityFrame.opcode == .frame,
              command["cmd"] as? String == "SET_ACTIVITY",
              command["nonce"] as? String == "activity-nonce",
              arguments?["pid"] as? Int == 4242,
              encodedActivity?["name"] as? String == "QQ 音乐",
              encodedActivity?["type"] as? Int == 2,
              encodedActivity?["status_display_type"] as? Int == 2,
              timestamps?["start"] as? Int64 == 1_700_000_000_000,
              timestamps?["end"] as? Int64 == 1_700_000_184_000,
              assets?["large_image"] as? String == "https://cdn.example.com/cover.png",
              buttons?.count == 2
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "SET_ACTIVITY RPC payload",
                actual: String(data: activityFrame.payload, encoding: .utf8)
            )
        }

        let clearFrame = try decodeSingleFrame(
            DiscordRPCPayload.clearActivity(processID: 4242, nonce: "clear-nonce")
        )
        let clearCommand = try jsonObject(clearFrame.payload)
        let clearArguments = clearCommand["args"] as? [String: Any]
        guard clearCommand["cmd"] as? String == "SET_ACTIVITY",
              clearArguments?["activity"] is NSNull
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "explicit Discord Presence clear",
                actual: String(data: clearFrame.payload, encoding: .utf8)
            )
        }

        do {
            _ = try DiscordRPCActivity(
                name: "Unsupported",
                details: nil,
                state: nil,
                activityType: 4,
                statusDisplayType: nil,
                startTimestamp: nil,
                endTimestamp: nil,
                largeImageKey: nil,
                largeImageText: nil,
                smallImageKey: nil,
                smallImageText: nil,
                buttons: nil
            )
            throw HarnessFailure.unexpectedValue(
                caseName: "unsupported SET_ACTIVITY type",
                actual: "accepted"
            )
        } catch DiscordRPCProtocolError.invalidActivityType(4) {
            // Expected: SET_ACTIVITY only accepts Playing, Listening, Watching, and Competing.
        }
    }

    private static func verifyRPCResponses() throws {
        let ready = try DiscordRPCPayload.response(
            from: Data("{\"cmd\":\"DISPATCH\",\"evt\":\"READY\",\"data\":{\"v\":1}}".utf8)
        )
        guard ready.command == "DISPATCH", ready.event == "READY" else {
            throw HarnessFailure.unexpectedValue(
                caseName: "READY response",
                actual: "\(ready)"
            )
        }

        let rejected = try DiscordRPCPayload.response(
            from: Data("{\"cmd\":\"SET_ACTIVITY\",\"evt\":\"ERROR\",\"nonce\":\"n\",\"data\":{\"code\":4000,\"message\":\"rejected\"}}".utf8)
        )
        guard rejected.nonce == "n",
              rejected.data?.code == 4000,
              rejected.data?.message == "rejected"
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "nonce-correlated RPC error",
                actual: "\(rejected)"
            )
        }
    }

    private static func verifyIPCPathPriority() throws {
        let paths = DiscordIPCPathResolver.candidatePaths(environment: [
            "XDG_RUNTIME_DIR": "/run/user/test",
            "TMPDIR": "/private/tmp/custom/",
            "TMP": "/private/tmp/custom",
            "TEMP": "/private/tmp/secondary",
        ])
        guard paths.count == 40,
              paths.first == "/run/user/test/discord-ipc-0",
              paths[9] == "/run/user/test/discord-ipc-9",
              paths[10] == "/private/tmp/custom/discord-ipc-0",
              paths.last == "/tmp/discord-ipc-9"
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: "Discord IPC path priority and deduplication",
                actual: paths.joined(separator: ",")
            )
        }
    }

    private static func decodeSingleFrame(_ data: Data) throws -> DiscordRPCFrame {
        var decoder = DiscordRPCFrameDecoder()
        let frames = try decoder.append(data)
        guard frames.count == 1, let frame = frames.first else {
            throw HarnessFailure.unexpectedValue(
                caseName: "single RPC frame",
                actual: "\(frames.count) frames"
            )
        }
        return frame
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessFailure.unexpectedValue(
                caseName: "RPC JSON object",
                actual: String(data: data, encoding: .utf8)
            )
        }
        return object
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
