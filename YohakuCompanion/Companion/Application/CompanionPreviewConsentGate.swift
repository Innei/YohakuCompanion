/// Stable consent projection of the publicly renderable Presence fields.
/// `observedAt` is intentionally excluded: recapture time is not public content
/// and must not make an otherwise identical preview stale.
struct CompanionSanitizedPreviewProjection: Equatable, Sendable {
    struct MediaSemantics: Equatable, Sendable {
        struct PlaybackSemantics: Equatable, Sendable {
            let state: CompanionMediaPlaybackState
            let durationSeconds: Double?
            let rate: Double

            init(playback: SanitizedMediaPlayback) {
                state = playback.state
                durationSeconds = playback.durationSeconds
                rate = playback.rate
            }
        }

        let kind: CompanionMediaKind
        let title: String?
        let artist: String?
        let album: String?
        let playerDisplayName: String?
        let playback: PlaybackSemantics

        init(media: SanitizedMediaPresence) {
            kind = media.kind
            title = media.title
            artist = media.artist
            album = media.album
            playerDisplayName = media.playerDisplayName
            playback = PlaybackSemantics(playback: media.playback)
        }
    }

    let application: SanitizedApplicationPresence?
    let media: MediaSemantics?

    init(snapshot: SanitizedPresenceSnapshot) {
        application = snapshot.application
        // Session identity and the advancing playback anchor are continuity
        // details, not a new disclosure decision. Excluding sessionID,
        // positionSeconds, and sampledAt keeps one reviewed track confirmable
        // while it naturally progresses. Public playback semantics remain part
        // of the projection and still require a new confirmation when changed.
        media = snapshot.media.map(MediaSemantics.init(media:))
    }
}

/// Monotonic consent gate for the sanitized Companion preview. Confirmation is
/// valid only when both the source/privacy revision and the current sanitized
/// application/media projection still match what the user reviewed.
struct CompanionPreviewConsentGate: Equatable, Sendable {
    typealias Revision = UInt64

    struct Confirmation: Equatable, Sendable {
        let policyRevision: Revision
        let projection: CompanionSanitizedPreviewProjection
    }

    private(set) var currentPolicyRevision: Revision = 0
    private(set) var confirmation: Confirmation?

    var isPreviewCurrent: Bool {
        confirmation?.policyRevision == currentPolicyRevision
    }

    mutating func policyDidChange() {
        currentPolicyRevision &+= 1
        confirmation = nil
    }

    @discardableResult
    mutating func recordPreview(_ snapshot: SanitizedPresenceSnapshot) -> Confirmation {
        let confirmation = Confirmation(
            policyRevision: currentPolicyRevision,
            projection: CompanionSanitizedPreviewProjection(snapshot: snapshot)
        )
        self.confirmation = confirmation
        return confirmation
    }

    func validates(
        _ candidate: Confirmation?,
        currentSnapshot: SanitizedPresenceSnapshot
    ) -> Bool {
        guard let candidate,
              candidate.policyRevision == currentPolicyRevision,
              confirmation == candidate
        else {
            return false
        }
        return candidate.projection == CompanionSanitizedPreviewProjection(
            snapshot: currentSnapshot
        )
    }

    mutating func clearPreview() {
        confirmation = nil
    }
}
