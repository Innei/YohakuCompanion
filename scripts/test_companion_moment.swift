import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

@main
private enum CompanionMomentHarness {
    static func main() async throws {
        try verifiesStablePublicProjection()
        try verifiesEmptyMomentIsRejected()
        try await verifiesDurableOutboxRoundTrip()
        print("Companion Moment behavior passed")
    }

    private static func verifiesStablePublicProjection() throws {
        let request = try CompanionMomentDTOMapper().makeRequest(
            draft: CompanionMomentDraft(
                content: "",
                snapshot: try snapshot(),
                includesApplication: true,
                includesWindowTitle: false,
                includesMedia: true
            ),
            requestID: "00000000-0000-4000-8000-000000000001"
        )
        let data = try CompanionJSON.makeEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let meta = object["meta"] as! [String: Any]
        let body = object["data"] as! [String: Any]
        let application = body["application"] as! [String: Any]
        let media = body["media"] as! [String: Any]
        let playback = media["playback"] as! [String: Any]

        try expect(meta["deviceId"] == nil, "Moment request persisted device identity")
        try expect(application["window"] is NSNull, "window title was not excluded")
        try expect(media["sessionId"] == nil, "media session identity was published")
        try expect(playback["sampledAt"] == nil, "live sampling time was published")
        try expect(playback["rate"] == nil, "live playback rate was published")
        try expect(playback["positionMs"] as? Int == 72_000, "position was not frozen")
    }

    private static func verifiesEmptyMomentIsRejected() throws {
        let empty = SanitizedPresenceSnapshot(
            observedAt: Date(timeIntervalSince1970: 1_721_131_200),
            application: nil,
            media: nil
        )
        do {
            _ = try CompanionMomentDTOMapper().makeRequest(
                draft: CompanionMomentDraft(
                    content: "  ",
                    snapshot: empty,
                    includesApplication: false,
                    includesWindowTitle: false,
                    includesMedia: false
                )
            )
            throw HarnessFailure.assertion("an empty Moment was accepted")
        } catch CompanionMomentMappingError.emptyMoment {
            // Expected.
        }
    }

    private static func verifiesDurableOutboxRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YohakuCompanionMomentHarness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let outbox = CompanionMomentOutbox(directoryURL: directory)
        let request = try CompanionMomentDTOMapper().makeRequest(
            draft: CompanionMomentDraft(
                content: "A concise progress note.",
                snapshot: try snapshot(),
                includesApplication: true,
                includesWindowTitle: false,
                includesMedia: false
            ),
            requestID: "00000000-0000-4000-8000-000000000002"
        )

        try await outbox.enqueue(request)
        let entries = try await outbox.entries()
        try expect(entries.count == 1, "outbox did not persist one entry")
        try expect(
            entries.first?.request.meta.requestID == request.meta.requestID,
            "outbox changed the request identity"
        )
        try await outbox.remove(requestID: request.meta.requestID)
        let remainingCount = try await outbox.count()
        try expect(remainingCount == 0, "outbox did not remove the sent entry")
    }

    private static func snapshot() throws -> SanitizedPresenceSnapshot {
        let application = try SanitizedApplicationPresence(
            displayName: "Xcode",
            activity: SanitizedApplicationActivity(key: "editing", customLabel: nil),
            windowTitle: "Private Project — Editor"
        )
        let media = try SanitizedMediaPresence(
            sessionID: UUID(),
            kind: .music,
            title: "Track title",
            artist: "Artist",
            album: nil,
            playerDisplayName: "Music",
            playback: SanitizedMediaPlayback(
                state: .paused,
                durationSeconds: 203,
                positionSeconds: 72,
                sampledAt: Date(timeIntervalSince1970: 1_721_131_199),
                rate: 0
            )
        )
        return SanitizedPresenceSnapshot(
            observedAt: Date(timeIntervalSince1970: 1_721_131_200),
            application: application,
            media: media
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}
