import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw HarnessFailure.assertion(message)
    }
}

private func snapshot(
    applicationName: String?,
    media: SanitizedMediaPresence? = nil,
    observedAt: Date = .now
) throws -> SanitizedPresenceSnapshot {
    SanitizedPresenceSnapshot(
        observedAt: observedAt,
        application: try applicationName.map {
            try SanitizedApplicationPresence(displayName: $0)
        },
        media: media
    )
}

private func media(
    title: String,
    sessionID: UUID = UUID(uuidString: "8A79DECF-4495-4C65-97CA-E6E7E625DF01")!,
    kind: CompanionMediaKind = .music,
    artist: String? = "Artist",
    album: String? = nil,
    playerDisplayName: String? = "Player",
    state: CompanionMediaPlaybackState = .playing,
    durationSeconds: Double? = 180,
    positionSeconds: Double? = 30,
    sampledAt: Date = Date(timeIntervalSince1970: 20),
    rate: Double = 1
) throws -> SanitizedMediaPresence {
    try SanitizedMediaPresence(
        sessionID: sessionID,
        kind: kind,
        title: title,
        artist: artist,
        album: album,
        playerDisplayName: playerDisplayName,
        playback: SanitizedMediaPlayback(
            state: state,
            durationSeconds: durationSeconds,
            positionSeconds: positionSeconds,
            sampledAt: sampledAt,
            rate: rate
        )
    )
}

@main
private enum CompanionPreviewConsentGateHarness {
    static func main() throws {
        var gate = CompanionPreviewConsentGate()
        let idle = try snapshot(applicationName: nil)

        try expect(!gate.isPreviewCurrent, "an uncaptured preview was accepted")
        try expect(
            !gate.validates(nil, currentSnapshot: idle),
            "a missing confirmation was accepted"
        )

        let firstPreview = gate.recordPreview(try snapshot(applicationName: "Editor"))
        let samePublicContentAtAnotherTime = try snapshot(
            applicationName: "Editor",
            observedAt: Date(timeIntervalSince1970: 10)
        )
        let changedApplication = try snapshot(applicationName: "Terminal")
        try expect(gate.isPreviewCurrent, "a fresh preview was rejected")
        try expect(
            gate.validates(
                firstPreview,
                currentSnapshot: samePublicContentAtAnotherTime
            ),
            "recapture time incorrectly invalidated identical public content"
        )
        try expect(
            !gate.validates(
                firstPreview,
                currentSnapshot: changedApplication
            ),
            "changed sanitized application content remained confirmable"
        )

        var mediaGate = CompanionPreviewConsentGate()
        let firstMediaSnapshot = try snapshot(
            applicationName: nil,
            media: media(title: "First Track")
        )
        let firstMediaPreview = mediaGate.recordPreview(firstMediaSnapshot)
        let changedSessionSnapshot = try snapshot(
            applicationName: nil,
            media: media(
                title: "First Track",
                sessionID: UUID(uuidString: "D8854BED-BE90-4D79-A81E-62A79AF68C19")!
            )
        )
        try expect(
            mediaGate.validates(
                firstMediaPreview,
                currentSnapshot: changedSessionSnapshot
            ),
            "a continuity-only media session ID change invalidated consent"
        )

        let advancedPlaybackSnapshot = try snapshot(
            applicationName: nil,
            media: media(
                title: "First Track",
                positionSeconds: 46,
                sampledAt: Date(timeIntervalSince1970: 36)
            ),
            observedAt: Date(timeIntervalSince1970: 37)
        )
        try expect(
            mediaGate.validates(
                firstMediaPreview,
                currentSnapshot: advancedPlaybackSnapshot
            ),
            "natural media position and sampling-time changes invalidated consent"
        )

        let semanticChanges: [(name: String, media: SanitizedMediaPresence)] = [
            ("title", try media(title: "Second Track")),
            ("artist", try media(title: "First Track", artist: "Second Artist")),
            ("album", try media(title: "First Track", album: "Album")),
            (
                "player",
                try media(title: "First Track", playerDisplayName: "Second Player")
            ),
            ("kind", try media(title: "First Track", kind: .podcast)),
            (
                "playback state",
                try media(title: "First Track", state: .paused, rate: 0)
            ),
            (
                "duration",
                try media(title: "First Track", durationSeconds: 181)
            ),
            ("playback rate", try media(title: "First Track", rate: 1.25)),
        ]
        for change in semanticChanges {
            let changedMediaSnapshot = try snapshot(
                applicationName: nil,
                media: change.media
            )
            try expect(
                !mediaGate.validates(
                    firstMediaPreview,
                    currentSnapshot: changedMediaSnapshot
                ),
                "changed media \(change.name) remained confirmable"
            )
        }

        gate.policyDidChange()
        try expect(!gate.isPreviewCurrent, "a policy change retained stale consent")
        try expect(
            !gate.validates(
                firstPreview,
                currentSnapshot: samePublicContentAtAnotherTime
            ),
            "a preview captured under the previous policy remained confirmable"
        )

        let refreshedSnapshot = try snapshot(applicationName: "Editor")
        let refreshedPreview = gate.recordPreview(refreshedSnapshot)
        try expect(gate.isPreviewCurrent, "a recaptured preview did not restore consent")
        try expect(
            gate.validates(refreshedPreview, currentSnapshot: refreshedSnapshot),
            "the recaptured sanitized projection was rejected"
        )

        gate.clearPreview()
        try expect(!gate.isPreviewCurrent, "clearing a connection retained preview consent")
        try expect(
            !gate.validates(refreshedPreview, currentSnapshot: refreshedSnapshot),
            "a cleared preview confirmation remained valid"
        )

        print("Companion preview consent gate harness passed")
    }
}
