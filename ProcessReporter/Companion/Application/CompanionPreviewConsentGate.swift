/// Stable consent projection of the publicly renderable Presence fields.
/// `observedAt` is intentionally excluded: recapture time is not public content
/// and must not make an otherwise identical preview stale.
struct CompanionSanitizedPreviewProjection: Equatable, Sendable {
    let application: SanitizedApplicationPresence?
    let media: SanitizedMediaPresence?

    init(snapshot: SanitizedPresenceSnapshot) {
        application = snapshot.application
        media = snapshot.media
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
