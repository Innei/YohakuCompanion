import Foundation

/// Comparable projection of every persisted input that can alter the
/// Companion snapshot. The consent gate and delivery path share this exact
/// definition of the current source and privacy policy.
struct CompanionPresencePolicyFingerprint: Equatable, Sendable {
    struct NameMapping: Equatable, Sendable {
        let from: String
        let to: String
    }

    let isApplicationSourceEnabled: Bool
    let isMediaSourceEnabled: Bool
    let sharesWindowTitlesGlobally: Bool
    let ignoresMediaWithoutArtist: Bool
    let privacyConfiguration: PresencePrivacyConfiguration
    let hiddenApplicationIdentifiers: Set<String>
    let hiddenMediaApplicationIdentifiers: Set<String>
    let processNameMappings: [NameMapping]
    let mediaProcessNameMappings: [NameMapping]
}

struct CompanionPresenceCaptureResult: Equatable, Sendable {
    let snapshot: SanitizedPresenceSnapshot
    let applicationIconAsset: ApplicationIconAsset?
}

/// Builds a fresh, privacy-sanitized Live Desk snapshot. Application and media
/// are independent sources, so media-only Presence remains valid when no
/// focused application can be read.
@MainActor
final class CompanionPresenceCapture {
    private let mediaSessionTracker: CompanionMediaSessionTracker
    private let mediaArtworkNormalizer: CompanionMediaArtworkNormalizer
    private let mediaPlaybackLinkResolver: any CompanionMediaPlaybackLinkResolving

    private var currentMediaIdentity: CompanionMediaSemanticIdentity?

    init(
        mediaSessionTracker: CompanionMediaSessionTracker? = nil,
        mediaArtworkNormalizer: CompanionMediaArtworkNormalizer = CompanionMediaArtworkNormalizer(),
        mediaPlaybackLinkResolver: any CompanionMediaPlaybackLinkResolving =
            CompanionMediaPlaybackLinkResolver.shared
    ) {
        self.mediaSessionTracker = mediaSessionTracker ?? CompanionMediaSessionTracker()
        self.mediaArtworkNormalizer = mediaArtworkNormalizer
        self.mediaPlaybackLinkResolver = mediaPlaybackLinkResolver
    }

    func policyFingerprint() -> CompanionPresencePolicyFingerprint {
        let enabledTypes = PreferencesDataModel.enabledTypes.value.types
        let mappings = PreferencesDataModel.mappingList.value.getList()
        return CompanionPresencePolicyFingerprint(
            isApplicationSourceEnabled: enabledTypes.contains(.process),
            isMediaSourceEnabled: enabledTypes.contains(.media),
            sharesWindowTitlesGlobally: PreferencesDataModel.shareWindowTitles.value,
            ignoresMediaWithoutArtist: PreferencesDataModel.ignoreNullArtist.value,
            privacyConfiguration: PreferencesDataModel.presencePrivacyConfiguration.value,
            hiddenApplicationIdentifiers: Set(PreferencesDataModel.filteredProcesses.value),
            hiddenMediaApplicationIdentifiers: Set(
                PreferencesDataModel.filteredMediaProcesses.value
            ),
            processNameMappings: mappings.compactMap { mapping in
                guard mapping.type == .processName else { return nil }
                return CompanionPresencePolicyFingerprint.NameMapping(
                    from: mapping.from,
                    to: mapping.to
                )
            },
            mediaProcessNameMappings: mappings.compactMap { mapping in
                guard mapping.type == .mediaProcessName else { return nil }
                return CompanionPresencePolicyFingerprint.NameMapping(
                    from: mapping.from,
                    to: mapping.to
                )
            }
        )
    }

    func capture(includeMediaTimeline: Bool) async throws -> SanitizedPresenceSnapshot {
        try await captureForDelivery(includeMediaTimeline: includeMediaTimeline).snapshot
    }

    /// Captures the public snapshot together with a local-only icon asset. The
    /// caller must not upload the asset until Live Desk publishing is enabled.
    func captureForDelivery(
        includeMediaTimeline: Bool
    ) async throws -> CompanionPresenceCaptureResult {
        try Task.checkCancellation()

        let enabledTypesBeforeFetch = PreferencesDataModel.enabledTypes.value.types
        let media: SanitizedMediaPresence?
        if includeMediaTimeline, enabledTypesBeforeFetch.contains(.media) {
            media = try await captureMedia()
        } else {
            resetMediaContinuity()
            media = nil
        }
        try Task.checkCancellation()

        // Application capture happens after the media provider await so a
        // privacy rule tightened during that suspension is applied to both
        // sources before the snapshot leaves this method.
        let enabledTypesAfterFetch = PreferencesDataModel.enabledTypes.value.types
        let capturedApplication = captureApplication(enabledTypes: enabledTypesAfterFetch)

        return CompanionPresenceCaptureResult(
            snapshot: SanitizedPresenceSnapshot(
                observedAt: .now,
                application: capturedApplication.presence,
                media: media
            ),
            applicationIconAsset: capturedApplication.iconAsset
        )
    }

    func resetMediaContinuity() {
        currentMediaIdentity = nil
        mediaSessionTracker.reset()
    }

    private func captureApplication(
        enabledTypes: Set<Reporter.Types>
    ) -> (presence: SanitizedApplicationPresence?, iconAsset: ApplicationIconAsset?) {
        guard enabledTypes.contains(.process),
              let process = ApplicationMonitor.shared.getFocusedWindowInfo()
        else {
            return (nil, nil)
        }

        let evaluator = privacyEvaluator()
        let decision = evaluator.processDecision(
            applicationIdentifier: process.applicationIdentifier
        )
        let mappedName = PreferencesDataModel.mappingList.value.getList().first {
            $0.type == .processName && $0.from == process.appName
        }?.to

        guard let presence = try? CompanionApplicationPresenceSanitizer.sanitize(
            capturedDisplayName: process.appName,
            mappedDisplayName: mappedName,
            displayAlias: decision.displayAlias,
            capturedWindowTitle: process.title,
            sharesApplication: decision.sharesApplication,
            sharesWindowTitle: decision.sharesWindowTitle,
            globalWindowTitleSharingEnabled: PreferencesDataModel.shareWindowTitles.value
        ) else {
            return (nil, nil)
        }

        return (
            presence,
            ApplicationIconAsset(
                applicationIdentifier: process.applicationIdentifier,
                displayName: presence.displayName,
                pngData: process.icon?.data
            )
        )
    }

    private func captureMedia() async throws -> SanitizedMediaPresence? {
        let mediaInfo: MediaInfo?
        let hasFreshTimeline: Bool
        do {
            switch try await MediaInfoManager.getMediaInfoFetchResultAsync(timeout: 2) {
            case .resolved(let resolved):
                mediaInfo = resolved
                hasFreshTimeline = true
            case .unavailable:
                mediaInfo = MediaInfoManager.getMediaInfo()
                hasFreshTimeline = false
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            mediaInfo = MediaInfoManager.getMediaInfo()
            hasFreshTimeline = false
        }

        guard let mediaInfo else {
            resetMediaContinuity()
            return nil
        }
        guard PreferencesDataModel.enabledTypes.value.types.contains(.media) else {
            resetMediaContinuity()
            return nil
        }
        guard mediaInfo.playing else {
            resetMediaContinuity()
            return nil
        }

        // Preferences are deliberately loaded after the provider await. A
        // privacy rule tightened during capture therefore applies before any
        // raw value can enter the sanitized domain model.
        let initialDecision = privacyEvaluator().mediaDecision(
            applicationIdentifier: mediaInfo.applicationIdentifier,
            processName: mediaInfo.processName
        )
        guard initialDecision.sharesMedia else {
            resetMediaContinuity()
            return nil
        }
        async let artworkResolution = resolveArtwork(for: mediaInfo)
        async let playbackURLResolution = mediaPlaybackLinkResolver.resolvePlaybackURL(
            for: mediaInfo
        )
        let (artwork, playbackURL) = await (artworkResolution, playbackURLResolution)
        try Task.checkCancellation()

        // Artwork normalization runs outside the main actor. Re-read every
        // source and privacy input after that suspension so a rule tightened
        // in the interim remains fail-closed for the entire media snapshot.
        guard PreferencesDataModel.enabledTypes.value.types.contains(.media) else {
            resetMediaContinuity()
            return nil
        }
        let decision = privacyEvaluator().mediaDecision(
            applicationIdentifier: mediaInfo.applicationIdentifier,
            processName: mediaInfo.processName
        )
        guard decision.sharesMedia else {
            resetMediaContinuity()
            return nil
        }
        let mappings = PreferencesDataModel.mappingList.value.getList()
        let mappedPlayerName = mappings.first {
            $0.type == .mediaProcessName && $0.from == mediaInfo.processName
        }?.to ?? mediaInfo.processName
        let playerDisplayName = decision.displayAlias ?? mappedPlayerName
        let kind = CompanionMediaKindResolver.kind(
            applicationIdentifier: mediaInfo.applicationIdentifier
        )
        let identity = CompanionMediaSemanticIdentity(
            kind: kind,
            title: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.name),
            artist: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.artist),
            album: CompanionMediaPresenceSanitizer.normalizedText(mediaInfo.album),
            playerDisplayName: CompanionMediaPresenceSanitizer.normalizedText(playerDisplayName),
            durationSeconds: CompanionMediaPresenceSanitizer.normalizedTime(mediaInfo.duration)
        )
        let sampledAt = Date.now

        if currentMediaIdentity != identity {
            currentMediaIdentity = identity
        }

        let sessionID = mediaSessionTracker.sessionID(for: identity)
        do {
            let sanitized = try CompanionMediaPresenceSanitizer.sanitize(
                sessionID: sessionID,
                kind: kind,
                capturedTitle: mediaInfo.name,
                capturedArtist: mediaInfo.artist,
                capturedAlbum: mediaInfo.album,
                playerDisplayName: playerDisplayName,
                durationSeconds: mediaInfo.duration,
                positionSeconds: hasFreshTimeline ? mediaInfo.elapsedTime : nil,
                sampledAt: sampledAt,
                isPlaying: mediaInfo.playing,
                sharesMedia: decision.sharesMedia,
                requiresArtist: PreferencesDataModel.ignoreNullArtist.value,
                playbackURL: playbackURL,
                artwork: artwork
            )
            if sanitized == nil {
                resetMediaContinuity()
            }
            return sanitized
        } catch {
            resetMediaContinuity()
            return nil
        }
    }

    private func resolveArtwork(for mediaInfo: MediaInfo) async -> SanitizedMediaArtwork? {
        if let providerArtwork = await mediaArtworkNormalizer.normalize(mediaInfo.image) {
            return providerArtwork
        }
        let artworkData = await mediaPlaybackLinkResolver.resolveArtworkData(for: mediaInfo)
        return await mediaArtworkNormalizer.normalize(artworkData)
    }

    private func privacyEvaluator() -> PresencePrivacyEvaluator {
        let hiddenMediaApplications = Set(PreferencesDataModel.filteredMediaProcesses.value)
        return PresencePrivacyEvaluator(
            configuration: PreferencesDataModel.presencePrivacyConfiguration.value,
            legacyHiddenApplications: Set(PreferencesDataModel.filteredProcesses.value),
            legacyHiddenMediaApplications: hiddenMediaApplications,
            legacyHiddenMediaNames: Set(
                hiddenMediaApplications.map { identifier in
                    AppUtility.shared.getAppInfo(for: identifier).displayName
                }
            )
        )
    }
}
