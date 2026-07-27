//
//  Reporter+Discord.swift
//  YohakuCompanion
//
//  Created by Codex on 2025/8/27.
//

import Foundation

private struct DiscordPresence {
    var name: String?
    var details: String?
    var state: String?
    var activityType: DiscordActivityType?
    var statusDisplayType: DiscordStatusDisplayType?
    var startTimestamp: Int64?
    var endTimestamp: Int64?
    var largeImageKey: String?
    var largeImageText: String?
    var smallImageKey: String?
    var smallImageText: String?
    var buttons: [DiscordButton]? = nil
}

class DiscordReporterExtension: ReporterExtension {
    var name: String = "Discord"
    private let mediaArtworkNormalizer = CompanionMediaArtworkNormalizer()
    private let mediaPlaybackLinkResolver = CompanionMediaPlaybackLinkResolver.shared
    private let mediaArtworkHost: CompanionMediaArtworkHost
    private var mediaArtworkCache = DiscordMediaArtworkCache()
    private var initializedApplicationId: String?
    private var currentProcessName: String?
    private var processStartTimestamp: Int64?
    private var activityClearTask: Task<Void, Never>?
    private var activityClearPending = false
    private var activityClearGeneration: UInt64 = 0
    private var shutdownAfterActivityClear = false

    init(mediaArtworkHost: CompanionMediaArtworkHost = .shared) {
        self.mediaArtworkHost = mediaArtworkHost
    }

    var isEnabled: Bool {
        return PreferencesDataModel.shared.discordIntegration.value.isEnabled
    }

    func createReporterOptions() -> ReporterOptions {
        ReporterOptions(
            assetCapability: .optionalPublicURL,
            onSendWithAsset: { data, assetResolution in
                await self.sendDiscordPresence(
                    data,
                    hostedApplicationIconURL: assetResolution.publicURL
                )
            }
        )
    }

    func unregister(from reporter: Reporter) {
        reporter.unregister(name: name)
        scheduleActivityClear(shutdownAfterCompletion: true)
        currentProcessName = nil
        processStartTimestamp = nil
        mediaArtworkCache.clear()
    }

    func clearReportedState() {
        scheduleActivityClear(shutdownAfterCompletion: false)
        currentProcessName = nil
        processStartTimestamp = nil
        mediaArtworkCache.clear()
    }

    func waitForPendingCleanup(until deadline: ContinuousClock.Instant) async {
        let clock = ContinuousClock()
        while activityClearPending, clock.now < deadline {
            guard !Task.isCancelled else { break }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                break
            }
        }

        if activityClearPending {
            activityClearGeneration &+= 1
            activityClearTask?.cancel()
            activityClearTask = nil
            activityClearPending = false
            shutdownAfterActivityClear = false
            NSLog("[Discord] Activity clear did not finish before the cleanup deadline")
        }
        DiscordClientProvider.shared.shutdown()
        initializedApplicationId = nil
    }

    private func scheduleActivityClear(shutdownAfterCompletion: Bool) {
        shutdownAfterActivityClear = shutdownAfterActivityClear || shutdownAfterCompletion
        guard !activityClearPending else { return }

        activityClearPending = true
        activityClearGeneration &+= 1
        if activityClearGeneration == 0 {
            activityClearGeneration = 1
        }
        let generation = activityClearGeneration
        let connectionGeneration = DiscordClientProvider.shared.connectionGeneration
        activityClearTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var clearFailed = false
            if DiscordClientProvider.shared.connectionGeneration == connectionGeneration {
                do {
                    try await DiscordClientProvider.shared.clearActivity()
                } catch {
                    clearFailed = true
                    NSLog("[Discord] Activity clear failed: \(error.localizedDescription)")
                }
            }

            guard self.activityClearGeneration == generation else { return }
            self.activityClearPending = false
            self.activityClearTask = nil
            // A timed-out SDK clear cannot safely share a connection with a new
            // publish. Destroy the old core before any later send reinitializes it.
            if (self.shutdownAfterActivityClear || clearFailed),
               DiscordClientProvider.shared.connectionGeneration == connectionGeneration
            {
                DiscordClientProvider.shared.shutdown()
                self.initializedApplicationId = nil
            }
            self.shutdownAfterActivityClear = false
        }
    }

    private func waitForScheduledActivityClear() async {
        if let activityClearTask {
            await activityClearTask.value
        }
    }

    private func ensureInitialized() {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard !cfg.applicationId.isEmpty else { return }

        if initializedApplicationId != cfg.applicationId {
            if initializedApplicationId != nil {
                DiscordClientProvider.shared.shutdown()
            }
            initializedApplicationId = cfg.applicationId
        }
        if !DiscordClientProvider.shared.isConnected {
            DiscordClientProvider.shared.initialize(applicationId: cfg.applicationId)
        }
    }

    private func computePresence(
        from data: ReportModel,
        hostedMediaArtworkURL: String?,
        hostedApplicationIconURL: String?
    ) -> DiscordPresence? {
        let cfg = PreferencesDataModel.shared.discordIntegration.value

        var presence = DiscordPresence()

        let nowMilliseconds = DiscordActivityTimeline.capturedAtMilliseconds(data.timeStamp)

        // Decide whether to show media or process
        let hasMedia = !(data.mediaName?.isEmpty ?? true)
        let hasProcess = !(data.processName?.isEmpty ?? true)
        let showMedia = cfg.showMediaInfo && hasMedia
            && (cfg.prioritizeMedia || !cfg.showProcessInfo || !hasProcess)

        if showMedia {
            let mediaPlayerName = Self.mediaPlayerDisplayName(for: data.mediaProcessName)
            presence.name = mediaPlayerName
            presence.details = data.mediaName
            presence.state = data.artist
            if cfg.useListeningForMedia {
                presence.activityType = .listening
                presence.statusDisplayType = .details
            }

            if cfg.showTimestamps,
               let timestamps = DiscordActivityTimeline.timestamps(
                capturedAt: data.timeStamp,
                elapsedSeconds: data.mediaElapsedTime,
                durationSeconds: data.mediaDuration
               )
            {
                presence.startTimestamp = timestamps.startMilliseconds
                presence.endTimestamp = timestamps.endMilliseconds
            }

            if let hostedMediaArtworkURL {
                presence.largeImageKey = hostedMediaArtworkURL
                presence.largeImageText = cfg.customLargeImageText.isEmpty
                    ? mediaPlayerName : cfg.customLargeImageText
            } else if !cfg.customLargeImageKey.isEmpty {
                presence.largeImageKey = cfg.customLargeImageKey
                presence.largeImageText = cfg.customLargeImageText.isEmpty
                    ? mediaPlayerName : cfg.customLargeImageText
            }

            // Dynamic player icon on small image, fallback to brand
            if let dynamicKey = Self.dynamicSmallImageKey(for: data.mediaProcessName) {
                presence.smallImageKey = dynamicKey
            }
        } else if cfg.showProcessInfo, let processName = data.processName {
            presence.name = processName
            presence.details = "正在使用 \(processName)"
            presence.state = data.windowTitle
            presence.activityType = .playing
            presence.statusDisplayType = .details

            if cfg.showTimestamps {
                if currentProcessName != processName || processStartTimestamp == nil {
                    currentProcessName = processName
                    processStartTimestamp = nowMilliseconds
                }
                presence.startTimestamp = processStartTimestamp
            }

            if let hostedApplicationIconURL {
                presence.largeImageKey = hostedApplicationIconURL
                presence.largeImageText = processName
            } else if !cfg.customLargeImageKey.isEmpty {
                presence.largeImageKey = cfg.customLargeImageKey
                presence.largeImageText = cfg.customLargeImageText.isEmpty ? processName : cfg.customLargeImageText
            }
        } else {
            // Nothing to show
            return nil
        }

        // Attach a configured branding image if dynamic mapping did not supply
        // one. An empty value deliberately publishes no branding asset instead
        // of requesting a legacy Developer Portal key.
        if presence.smallImageKey?.isEmpty ?? true,
           !cfg.brandSmallImageKey.isEmpty
        {
            presence.smallImageKey = cfg.brandSmallImageKey
        }
        if let smallImageKey = presence.smallImageKey,
           !smallImageKey.isEmpty
        {
            presence.smallImageText = presence.name ?? "Yohaku Companion"
        } else {
            presence.smallImageKey = nil
            presence.smallImageText = nil
        }

        // Optional buttons
        if cfg.enableButtons,
           let button = DiscordTransportContract.button(
            DiscordButton(label: cfg.buttonLabel, url: cfg.buttonUrl)
           )
        {
            presence.buttons = [button]
        }

        return presence
    }

    private func shouldShowMedia(_ data: ReportModel) -> Bool {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        let hasMedia = !(data.mediaName?.isEmpty ?? true)
        let hasProcess = !(data.processName?.isEmpty ?? true)
        return cfg.showMediaInfo && hasMedia
            && (cfg.prioritizeMedia || !cfg.showProcessInfo || !hasProcess)
    }

    /// Reuses the same sanitized, versioned R2 object as Live Desk. The
    /// process-wide host serializes replacements and caches identical covers;
    /// failure remains an optional enrichment and falls back to the configured
    /// Discord asset.
    private func hostedMediaArtworkURL(from data: ReportModel) async -> String? {
        guard shouldShowMedia(data),
              let title = data.mediaName,
              !title.isEmpty
        else {
            mediaArtworkCache.clear()
            return nil
        }
        let identity = DiscordMediaArtworkCache.MediaIdentity(
            title: title,
            artist: data.artist,
            album: data.mediaInfoRaw?.album,
            player: data.mediaProcessName,
            applicationIdentifier: data.sourceMediaApplicationIdentifier
        )
        guard let mediaInfo = data.mediaInfoRaw else {
            return mediaArtworkCache.resolve(identity: identity, hostedURL: nil)
        }
        guard let deviceID = YohakuCompanionService.shared.connection?.deviceID else {
            NSLog("[Discord] Media artwork unavailable: paired device metadata is not loaded")
            return mediaArtworkCache.resolve(identity: identity, hostedURL: nil)
        }
        guard let configuration = CompanionMediaArtworkHostingConfiguration(
            integration: PreferencesDataModel.s3Integration.value
        ) else {
            NSLog("[Discord] Media artwork unavailable: R2 hosting is not configured")
            return mediaArtworkCache.resolve(identity: identity, hostedURL: nil)
        }
        var artwork = await mediaArtworkNormalizer.normalize(mediaInfo.image)
        if artwork == nil {
            let resolvedArtworkData = await mediaPlaybackLinkResolver.resolveArtworkData(
                for: mediaInfo
            )
            artwork = await mediaArtworkNormalizer.normalize(resolvedArtworkData)
        }
        guard let artwork else {
            NSLog("[Discord] Media artwork unavailable: normalization rejected the source")
            return mediaArtworkCache.resolve(identity: identity, hostedURL: nil)
        }

        do {
            let hostedArtwork = try await mediaArtworkHost.host(
                artwork,
                deviceID: deviceID,
                configuration: configuration
            )
            let identifier = DiscordTransportContract.assetIdentifier(
                hostedArtwork.publicURL?.absoluteString
            )
            if identifier == nil {
                NSLog("[Discord] Media artwork unavailable: hosted URL exceeds the transport contract")
            }
            return mediaArtworkCache.resolve(identity: identity, hostedURL: identifier)
        } catch {
            NSLog(
                "[Discord] Media artwork hosting failed: \(String(describing: type(of: error)))"
            )
            return mediaArtworkCache.resolve(identity: identity, hostedURL: nil)
        }
    }

    /// Normalize once so the Social SDK call and persisted output receipt are
    /// derived from the same final payload.
    private static func transportPresence(_ presence: DiscordPresence) -> DiscordPresence {
        DiscordPresence(
            name: DiscordTransportContract.text(presence.name),
            details: DiscordTransportContract.text(presence.details),
            state: DiscordTransportContract.text(presence.state),
            activityType: presence.activityType ?? .playing,
            statusDisplayType: presence.statusDisplayType,
            startTimestamp: presence.startTimestamp,
            endTimestamp: presence.endTimestamp,
            largeImageKey: DiscordTransportContract.assetIdentifier(presence.largeImageKey),
            largeImageText: DiscordTransportContract.text(presence.largeImageText),
            smallImageKey: DiscordTransportContract.assetIdentifier(presence.smallImageKey),
            smallImageText: DiscordTransportContract.text(presence.smallImageText),
            buttons: presence.buttons?.compactMap(DiscordTransportContract.button)
        )
    }

    private func recordDebug(
        outcome: String,
        reason: String? = nil
    ) {
        let clientKind = DiscordClientProvider.shared is NoopDiscordClient ? "noop" : "sdk"
        let connected = DiscordClientProvider.shared.isConnected

        DiscordDebugStore.shared.update { snapshot in
            snapshot.lastOutcome = outcome
            snapshot.lastReason = reason
            snapshot.clientKind = clientKind
            snapshot.isConnected = connected
        }
    }

    private static func deliveryOutputSummary(
        for presence: DiscordPresence
    ) -> SyncOutputSummary {
        var detailComponents = [String]()
        if let startTimestamp = presence.startTimestamp {
            detailComponents.append("Start (ms): \(startTimestamp)")
        }
        if let endTimestamp = presence.endTimestamp {
            detailComponents.append("End (ms): \(endTimestamp)")
        }
        if let largeImageKey = presence.largeImageKey, !largeImageKey.isEmpty {
            detailComponents.append("Large image: \(largeImageKey)")
        }
        if let largeImageText = presence.largeImageText, !largeImageText.isEmpty {
            detailComponents.append("Large image text: \(largeImageText)")
        }
        if let smallImageKey = presence.smallImageKey, !smallImageKey.isEmpty {
            detailComponents.append("Small image: \(smallImageKey)")
        }
        if let smallImageText = presence.smallImageText, !smallImageText.isEmpty {
            detailComponents.append("Small image text: \(smallImageText)")
        }
        let buttonLabels = presence.buttons?
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if let buttonLabels, !buttonLabels.isEmpty {
            // URLs are deliberately excluded from local History.
            detailComponents.append("Buttons: \(buttonLabels)")
        }

        return SyncOutputSummary(
            title: presence.details,
            subtitle: presence.state,
            detail: detailComponents.isEmpty ? nil : detailComponents.joined(separator: " · "),
            activityKind: presence.activityType.map { activityTypeName($0) }
        )
    }

    private static func activityTypeName(_ type: DiscordActivityType?) -> String {
        guard let type else { return "N/A" }
        switch type {
        case .playing: return "playing"
        case .streaming: return "streaming"
        case .listening: return "listening"
        case .watching: return "watching"
        case .custom: return "custom"
        case .competing: return "competing"
        }
    }

    private static func dynamicSmallImageKey(for mediaProcessName: String?) -> String? {
        guard let name = mediaProcessName?.lowercased(), !name.isEmpty else { return nil }
        // Keep specific names before generic "music"; Dictionary iteration order
        // previously made YouTube Music nondeterministically use the Apple key.
        let mappings: [(String, String)] = [
            ("youtube music", "youtubemusic"),
            ("yt music", "youtubemusic"),
            ("neteasemusic", "netease"),
            ("网易云音乐", "netease"),
            ("qqmusic", "qqmusic"),
            ("qq 音乐", "qqmusic"),
            ("spotify", "spotify"),
            ("itunes", "applemusic"),
            ("music", "applemusic"),
            ("vlc", "vlc"),
        ]
        for (candidate, key) in mappings {
            if name.contains(candidate) { return key }
        }
        return nil
    }

    private static func mediaPlayerDisplayName(for mediaProcessName: String?) -> String {
        guard let rawName = mediaProcessName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !rawName.isEmpty else {
            return "Yohaku Companion"
        }
        let name = rawName.lowercased()
        let mappings: [(String, String)] = [
            ("youtube music", "YouTube Music"),
            ("yt music", "YouTube Music"),
            ("neteasemusic", "网易云音乐"),
            ("网易云音乐", "网易云音乐"),
            ("qqmusic", "QQ 音乐"),
            ("qq 音乐", "QQ 音乐"),
            ("spotify", "Spotify"),
            ("itunes", "Apple Music"),
            ("music", "Apple Music"),
            ("vlc", "VLC"),
        ]
        return mappings.first(where: { name.contains($0.0) })?.1 ?? rawName
    }

    @MainActor
    private func sendDiscordPresence(
        _ data: ReportModel,
        hostedApplicationIconURL: String?
    ) async -> ReporterDeliveryResult {
        let cfg = PreferencesDataModel.shared.discordIntegration.value
        guard cfg.isEnabled else {
            recordDebug(outcome: "ignored", reason: "disabled")
            return .failure(.ignored)
        }
        guard !cfg.applicationId.isEmpty else {
            recordDebug(outcome: "ignored", reason: "missing applicationId")
            return .failure(.ignored)
        }
        guard let applicationId = UInt64(cfg.applicationId), applicationId > 0 else {
            recordDebug(outcome: "error", reason: "invalid applicationId")
            return .failure(.cancelled(message: "Discord applicationId must be a positive integer"))
        }

        await waitForScheduledActivityClear()
        ensureInitialized()
        guard DiscordClientProvider.shared.isConnected else {
            let reason = DiscordClientProvider.shared is NoopDiscordClient
                ? "Discord SDK is unavailable" : "Discord client not connected"
            recordDebug(outcome: "error", reason: reason)
            return .failure(.cancelled(message: reason))
        }

        let hostedMediaArtworkURL = await hostedMediaArtworkURL(from: data)
        if Task.isCancelled {
            recordDebug(outcome: "cancelled")
            return .failure(.cancelled(message: "Discord activity update was cancelled"))
        }

        guard let computedPresence = computePresence(
            from: data,
            hostedMediaArtworkURL: hostedMediaArtworkURL,
            hostedApplicationIconURL: DiscordTransportContract.assetIdentifier(
                hostedApplicationIconURL
            )
        ) else {
            clearReportedState()
            recordDebug(outcome: "ignored", reason: "no presence to show")
            return .failure(.ignored)
        }
        let p = Self.transportPresence(computedPresence)

        do {
            try await DiscordClientProvider.shared.setActivity(
                name: p.name,
                details: p.details,
                state: p.state,
                activityType: p.activityType,
                statusDisplayType: p.statusDisplayType,
                startTimestamp: p.startTimestamp,
                endTimestamp: p.endTimestamp,
                largeImageKey: p.largeImageKey,
                largeImageText: p.largeImageText,
                smallImageKey: p.smallImageKey,
                smallImageText: p.smallImageText,
                buttons: p.buttons
            )
            try Task.checkCancellation()
            recordDebug(outcome: "success")
            return .success(
                ReporterDeliveryReceipt(outputSummary: Self.deliveryOutputSummary(for: p))
            )
        } catch {
            if Task.isCancelled {
                // Some Discord SDK transports complete setActivity even after the
                // enclosing task is cancelled. Clear again so a stale generation
                // cannot restore an activity after privacy or lifecycle invalidation.
                clearReportedState()
                recordDebug(outcome: "cancelled")
                return .failure(.cancelled(message: "Discord activity update was cancelled"))
            }
            let reason = error.localizedDescription
            recordDebug(outcome: "error", reason: reason)
            return .failure(.networkError("Discord activity update failed: \(reason)"))
        }
    }
}
