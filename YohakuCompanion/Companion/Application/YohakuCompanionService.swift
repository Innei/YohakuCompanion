import Combine
import Foundation
import RxSwift

enum YohakuCompanionServiceError: Error, Equatable, Sendable {
    case operationInProgress
    case applicationTerminating
    case missingConnection
    case previewOutOfDate
    case momentScopeMissing
    case momentFeatureUnavailable
    case momentSchemaUnsupported
    case clientUpdateRequired(minimumVersion: String)
}

enum CompanionMomentPublishResult: Equatable, Sendable {
    case published(id: String, url: URL?)
    case queued
}

enum CompanionMomentPublishingAvailability: Equatable, Sendable {
    case available
    case setupRequired
    case repairPairingRequired
}

/// Non-secret connection data intended for settings presentation. The Device
/// Token remains owned by protected persistence and cannot cross this boundary.
struct YohakuCompanionConnectionSummary: Equatable, Sendable {
    let baseURL: URL
    let deviceID: String
    let scopes: [CompanionDeviceScope]
    let isLiveDeskEnabled: Bool

    init(metadata: CompanionConnectionMetadata) {
        baseURL = metadata.baseURL
        deviceID = metadata.deviceID
        scopes = metadata.scopes
        isLiveDeskEnabled = metadata.isLiveDeskEnabled
    }
}

/// Main-actor application façade for the Companion settings experience. It is
/// the sole owner of the process-wide connection store and Live Desk
/// coordinator, preventing settings views from creating competing credential
/// or heartbeat authorities.
@MainActor
final class YohakuCompanionService: ObservableObject {
    static let shared = YohakuCompanionService()

    @Published private(set) var connection: YohakuCompanionConnectionSummary?
    @Published private(set) var preview: SanitizedPresenceSnapshot?
    @Published private(set) var runtimeState: CompanionLiveDeskRuntimeState = .disabled
    @Published private(set) var isBusy = false
    @Published private(set) var isPreviewCurrent = false
    @Published private(set) var pendingMomentCount = 0
    @Published private(set) var isPublishingMoment = false

    private let connectionStore: CompanionConnectionStore
    private let coordinator: CompanionLiveDeskCoordinator
    private let capture: CompanionPresenceCapture
    private let momentOutbox: CompanionMomentOutbox
    private let momentArtworkHost: CompanionMomentArtworkHost
    private let capturePolicySubscriptions = DisposeBag()
    private var capturePolicyFingerprint: CompanionPresencePolicyFingerprint
    private var previewConsentGate = CompanionPreviewConsentGate()
    private var displayedPreviewConfirmation: CompanionPreviewConsentGate.Confirmation?
    private var previewCaptureGeneration: UInt64 = 0
    private var momentRetryTask: Task<Void, Never>?

    private convenience init() {
        self.init(
            connectionStore: CompanionConnectionStore(
                credentialPersistence: ProtectedCompanionCredentialPersistence()
            ),
            capture: CompanionPresenceCapture()
        )
        observeCapturePolicyChanges()
    }

    init(
        connectionStore: CompanionConnectionStore,
        capture: CompanionPresenceCapture,
        momentOutbox: CompanionMomentOutbox = CompanionMomentOutbox(),
        momentArtworkHost: CompanionMomentArtworkHost = CompanionMomentArtworkHost()
    ) {
        self.connectionStore = connectionStore
        self.capture = capture
        self.momentOutbox = momentOutbox
        self.momentArtworkHost = momentArtworkHost
        capturePolicyFingerprint = capture.policyFingerprint()
        coordinator = CompanionLiveDeskCoordinator(
            connectionStore: connectionStore,
            capture: capture,
            clientVersion: CompanionClientVersion.current
        )
        runtimeState = coordinator.state
        coordinator.onStateChange = { [weak self] state in
            self?.runtimeState = state
        }
    }

    /// Used only by the AppKit lifecycle bridge. Settings code should call this
    /// façade rather than retaining or constructing a coordinator directly.
    var applicationLifecycleCoordinator: CompanionLiveDeskCoordinator {
        coordinator
    }

    var momentPublishingAvailability: CompanionMomentPublishingAvailability {
        guard let connection else { return .setupRequired }
        return connection.scopes.contains(.momentWrite)
            ? .available
            : .repairPairingRequired
    }

    func start() async {
        do {
            try await load()
        } catch {
            // Corrupt or unavailable connection metadata must not turn an
            // optional integration into an application-startup failure. The
            // coordinator performs the same fail-closed load and exposes its
            // fixed degraded state while settings can present the load error.
            connection = nil
        }
        if connection != nil {
            await refreshPreview()
        } else {
            clearPreviewConsent()
        }
        coordinator.start()
        await refreshPendingMomentCount()
        await retryPendingMoments()
    }

    func load() async throws {
        do {
            connection = try await connectionStore.loadMetadata().map(
                YohakuCompanionConnectionSummary.init(metadata:)
            )
            runtimeState = coordinator.state
        } catch {
            connection = nil
            runtimeState = coordinator.state
            throw error
        }
    }

    /// Captures the same privacy-sanitized application and media projection
    /// used by Live Desk before the user grants public publishing consent.
    func refreshPreview() async {
        let policyChanged = invalidatePreviewIfPolicyChanged()
        await captureAndRecordPreview()
        if policyChanged {
            coordinator.requestFreshSnapshot()
        }
    }

    func captureMomentSnapshot() async throws -> SanitizedPresenceSnapshot {
        guard momentPublishingAvailability == .available else {
            throw momentAvailabilityError()
        }
        return try await capture.capture(includeMediaTimeline: true)
    }

    func publishMoment(_ draft: CompanionMomentDraft) async throws
        -> CompanionMomentPublishResult
    {
        guard !ApplicationState.isTerminating else {
            throw YohakuCompanionServiceError.applicationTerminating
        }
        guard !isPublishingMoment else {
            throw YohakuCompanionServiceError.operationInProgress
        }
        guard momentPublishingAvailability == .available else {
            throw momentAvailabilityError()
        }

        isPublishingMoment = true
        defer { isPublishingMoment = false }

        let mapper = CompanionMomentDTOMapper()
        var request = try mapper.makeRequest(draft: draft)
        do {
            guard let connection = try await connectionStore.loadPairedConnection() else {
                throw YohakuCompanionServiceError.missingConnection
            }
            let client = CompanionHTTPClient(
                server: connection.server,
                maximumPayloadBytes: 64 * 1_024,
                clientVersion: CompanionClientVersion.current
            )
            let capabilities = try await client.fetchCapabilities()
            try requireMomentCapability(capabilities.data)

            if draft.includesMedia,
               let artwork = draft.snapshot.media?.artwork,
               let configuration = CompanionMediaArtworkHostingConfiguration(
                   integration: PreferencesDataModel.s3Integration.value
               )
            {
                do {
                    let artworkURL = try await momentArtworkHost.host(
                        artwork,
                        configuration: configuration
                    )
                    request = try mapper.makeRequest(
                        draft: draft,
                        artworkURL: artworkURL,
                        requestID: request.meta.requestID
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Artwork is optional. The sanitized text and context remain publishable.
                }
            }

            let response = try await client.publishRecently(
                request,
                credential: connection.credential
            )
            return .published(id: response.data.id, url: response.data.url)
        } catch {
            guard shouldQueueMoment(after: error) else { throw error }
            try await momentOutbox.enqueue(request)
            await refreshPendingMomentCount()
            scheduleMomentRetries()
            return .queued
        }
    }

    func retryPendingMoments() async {
        guard momentPublishingAvailability == .available,
              !ApplicationState.isTerminating,
              let connection = try? await connectionStore.loadPairedConnection()
        else {
            await refreshPendingMomentCount()
            return
        }
        guard let entries = try? await momentOutbox.entries(), !entries.isEmpty else {
            await refreshPendingMomentCount()
            return
        }

        let client = CompanionHTTPClient(
            server: connection.server,
            maximumPayloadBytes: 64 * 1_024,
            clientVersion: CompanionClientVersion.current
        )
        do {
            let capabilities = try await client.fetchCapabilities()
            try requireMomentCapability(capabilities.data)
            for entry in entries where !Task.isCancelled {
                do {
                    _ = try await client.publishRecently(
                        entry.request,
                        credential: connection.credential
                    )
                    try await momentOutbox.remove(requestID: entry.request.meta.requestID)
                } catch {
                    if shouldQueueMoment(after: error) { break }
                    return
                }
            }
        } catch {
            // The durable outbox remains unchanged for a later retry.
        }
        await refreshPendingMomentCount()
        if pendingMomentCount > 0 { scheduleMomentRetries() }
    }

    func shutdownMomentPublishing() {
        momentRetryTask?.cancel()
        momentRetryTask = nil
    }

    func pair(
        baseURL: URL,
        pairingCode: String,
        deviceName: String
    ) async throws {
        try beginOperation()
        defer { isBusy = false }

        try await SettingsMutationCoordinator.shared.perform { [self] in
            try await pairTransaction(
                baseURL: baseURL,
                pairingCode: pairingCode,
                deviceName: deviceName
            )
        }
    }

    private func pairTransaction(
        baseURL: URL,
        pairingCode: String,
        deviceName: String
    ) async throws {
        let client = CompanionPairingClient(
            server: try CompanionServerConfiguration(baseURL: baseURL)
        )
        try await client.claimAndInstall(
            pairingCode: pairingCode,
            deviceName: deviceName,
            connectionStore: connectionStore
        )
        try? await momentOutbox.removeAll()
        await refreshPendingMomentCount()

        // A successful claim atomically replaces the local credential and
        // installs disabled metadata. Stop the previous authority immediately;
        // it still owns the old in-memory credential needed for its final clear.
        await coordinator.shutdown()
        try await load()
        await refreshPreview()
    }

    func setLiveDeskEnabled(_ isEnabled: Bool) async throws {
        try beginOperation()
        defer { isBusy = false }

        try await SettingsMutationCoordinator.shared.perform { [self] in
            try await setLiveDeskEnabledTransaction(isEnabled)
        }
    }

    private func setLiveDeskEnabledTransaction(_ isEnabled: Bool) async throws {
        if isEnabled {
            // The visible sanitized preview is the consent boundary. Never
            // persist opt-in from an older source/privacy revision. If relay
            // delivery has not reached this service yet, compare the capture
            // fingerprint synchronously and require another explicit click
            // after presenting the refreshed projection.
            if invalidatePreviewIfPolicyChanged() {
                await captureAndRecordPreview()
                coordinator.requestFreshSnapshot()
                throw YohakuCompanionServiceError.previewOutOfDate
            }
            guard let confirmedPreview = displayedPreviewConfirmation,
                  isPreviewCurrent
            else {
                await captureAndRecordPreview()
                throw YohakuCompanionServiceError.previewOutOfDate
            }
            previewCaptureGeneration &+= 1
            let currentSnapshotBeforePersistence = try await capture.capture(
                includeMediaTimeline: true
            )
            guard previewConsentGate.validates(
                confirmedPreview,
                currentSnapshot: currentSnapshotBeforePersistence
            ) else {
                recordPreview(currentSnapshotBeforePersistence)
                throw YohakuCompanionServiceError.previewOutOfDate
            }

            guard let metadata = try await connectionStore.setLiveDeskEnabled(true) else {
                throw YohakuCompanionServiceError.missingConnection
            }

            // The actor hop above permits MainActor preference mutations to
            // run. Revalidate the exact revision before making the enabled
            // record observable to the coordinator. A stale write is revoked
            // immediately and can never start a publishing authority.
            let policyChangedWhilePersisting = invalidatePreviewIfPolicyChanged()
            let currentSnapshotAfterPersistence = try await capture.capture(
                includeMediaTimeline: true
            )
            guard !policyChangedWhilePersisting,
                  previewConsentGate.validates(
                      confirmedPreview,
                      currentSnapshot: currentSnapshotAfterPersistence
                  )
            else {
                do {
                    guard let disabledMetadata = try await connectionStore
                        .setLiveDeskEnabled(false)
                    else {
                        throw YohakuCompanionServiceError.missingConnection
                    }
                    connection = YohakuCompanionConnectionSummary(metadata: disabledMetadata)
                } catch {
                    await coordinator.shutdown()
                    try? await load()
                    throw error
                }
                await captureAndRecordPreview()
                coordinator.requestFreshSnapshot()
                throw YohakuCompanionServiceError.previewOutOfDate
            }

            connection = YohakuCompanionConnectionSummary(metadata: metadata)
            coordinator.start()
            return
        }

        // Persist revoked consent before waiting for best-effort remote cleanup.
        // A crash during the bounded clear can therefore never resume sharing
        // on the next launch. Lease expiry remains the remote fallback.
        do {
            guard let metadata = try await connectionStore.setLiveDeskEnabled(false) else {
                throw YohakuCompanionServiceError.missingConnection
            }
            connection = YohakuCompanionConnectionSummary(metadata: metadata)
        } catch {
            // Persistence failure cannot prove a durable revocation. Still stop
            // the current process before reporting the failure to the user.
            await coordinator.shutdown()
            try? await load()
            throw error
        }
        await coordinator.shutdown()
    }

    @discardableResult
    func removeConnection() async throws -> CompanionCredentialMutationResult {
        try beginOperation()
        defer { isBusy = false }

        return try await SettingsMutationCoordinator.shared.perform { [self] in
            try await removeConnectionTransaction()
        }
    }

    /// Called only from a transaction that already owns the mutation
    /// coordinator's exclusive maintenance window. Routing this call through
    /// `perform` again would make the transaction wait on itself.
    @discardableResult
    func removeConnectionDuringExclusiveSettingsMutation()
        async throws -> CompanionCredentialMutationResult
    {
        // An already-admitted erase transaction must finish fail-closed even if
        // AppKit begins termination while it is waiting behind an earlier tail.
        // Termination drains that tail before stopping the process.
        try beginOperation(allowDuringTermination: true)
        defer { isBusy = false }
        return try await removeConnectionTransaction()
    }

    private func removeConnectionTransaction()
        async throws -> CompanionCredentialMutationResult
    {
        // Revoke durable consent before waiting for best-effort remote cleanup.
        // The coordinator retains its in-memory credential for the final clear.
        do {
            if let metadata = try await connectionStore.setLiveDeskEnabled(false) {
                connection = YohakuCompanionConnectionSummary(metadata: metadata)
            }
        } catch {
            // Invalid metadata must not prevent an explicit removal from erasing
            // the protected credential. Stop this process, then continue to the
            // atomic credential-and-metadata removal below.
        }
        await coordinator.shutdown()

        do {
            let result = try await connectionStore.removeConnection()
            try? await momentOutbox.removeAll()
            await refreshPendingMomentCount()
            connection = nil
            runtimeState = coordinator.state
            clearPreviewConsent()
            return result
        } catch {
            try? await load()
            throw error
        }
    }

    private func beginOperation(allowDuringTermination: Bool = false) throws {
        guard allowDuringTermination || !ApplicationState.isTerminating else {
            throw YohakuCompanionServiceError.applicationTerminating
        }
        guard !isBusy else {
            throw YohakuCompanionServiceError.operationInProgress
        }
        isBusy = true
    }

    private func momentAvailabilityError() -> YohakuCompanionServiceError {
        switch momentPublishingAvailability {
        case .available:
            return .operationInProgress
        case .setupRequired:
            return .missingConnection
        case .repairPairingRequired:
            return .momentScopeMissing
        }
    }

    private func requireMomentCapability(
        _ capabilities: CompanionCapabilitiesV2
    ) throws {
        switch CompanionCapabilityNegotiator.negotiateMoment(
            capabilities,
            clientVersion: CompanionClientVersion.current
        ) {
        case .available:
            return
        case .clientUpdateRequired(let minimumVersion):
            throw YohakuCompanionServiceError.clientUpdateRequired(
                minimumVersion: minimumVersion
            )
        case .schemaUnsupported:
            throw YohakuCompanionServiceError.momentSchemaUnsupported
        case .featureUnavailable, .invalidCapabilities:
            throw YohakuCompanionServiceError.momentFeatureUnavailable
        }
    }

    private func shouldQueueMoment(after error: Error) -> Bool {
        if error is URLError { return true }
        guard let error = error as? CompanionHTTPClientError else { return false }
        switch error {
        case .server(let statusCode, _):
            return statusCode >= 500 || statusCode == 429
        case .invalidResponse, .unexpectedEmptyResponse, .responseDecodingFailed:
            return true
        case .credentialDeviceMismatch,
             .responseRequestIDMismatch,
             .payloadTooLarge:
            return false
        }
    }

    private func refreshPendingMomentCount() async {
        pendingMomentCount = (try? await momentOutbox.count()) ?? 0
    }

    private func scheduleMomentRetries() {
        guard momentRetryTask == nil, pendingMomentCount > 0 else { return }
        momentRetryTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.pendingMomentCount > 0 {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self.retryPendingMoments()
            }
            self?.momentRetryTask = nil
        }
    }

    /// Installs the only process-wide capture-input observer. Injected service
    /// instances deliberately omit this binding so tests cannot accidentally
    /// create a second heartbeat/privacy authority beside `shared`.
    private func observeCapturePolicyChanges() {
        let changes: [Observable<Void>] = [
            PreferencesDataModel.enabledTypes.skip(1).map { _ in () },
            PreferencesDataModel.shareWindowTitles.skip(1).map { _ in () },
            PreferencesDataModel.presencePrivacyConfiguration.skip(1).map { _ in () },
            PreferencesDataModel.filteredProcesses.skip(1).map { _ in () },
            PreferencesDataModel.filteredMediaProcesses.skip(1).map { _ in () },
            PreferencesDataModel.mappingList.skip(1).map { _ in () },
            PreferencesDataModel.ignoreNullArtist.skip(1).map { _ in () },
        ]

        Observable.merge(changes)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] in
                self?.handleCapturePolicyChange()
            })
            .disposed(by: capturePolicySubscriptions)

        PreferencesDataModel.s3Integration
            .skip(1)
            .observe(on: MainScheduler.instance)
            .subscribe(onNext: { [weak self] _ in
                self?.coordinator.applicationIconHostingConfigurationDidChange()
            })
            .disposed(by: capturePolicySubscriptions)
    }

    private func handleCapturePolicyChange() {
        guard invalidatePreviewIfPolicyChanged() else { return }

        // A paired device receives a new sanitized preview immediately. The
        // coordinator independently coalesces the corresponding network send,
        // so sequential relay writes cannot fan out concurrent replacements.
        if connection != nil {
            Task { @MainActor [weak self] in
                await self?.captureAndRecordPreview()
            }
        } else {
            clearPreviewConsent()
        }
        coordinator.requestFreshSnapshot()
    }

    @discardableResult
    private func invalidatePreviewIfPolicyChanged() -> Bool {
        let latestFingerprint = capture.policyFingerprint()
        guard latestFingerprint != capturePolicyFingerprint else { return false }

        capturePolicyFingerprint = latestFingerprint
        previewCaptureGeneration &+= 1
        previewConsentGate.policyDidChange()
        displayedPreviewConfirmation = nil
        isPreviewCurrent = false
        return true
    }

    private func captureAndRecordPreview() async {
        previewCaptureGeneration &+= 1
        let captureGeneration = previewCaptureGeneration
        do {
            let snapshot = try await capture.capture(includeMediaTimeline: true)
            guard captureGeneration == previewCaptureGeneration else { return }
            recordPreview(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard captureGeneration == previewCaptureGeneration else { return }
            clearPreviewConsent()
        }
    }

    private func recordPreview(_ snapshot: SanitizedPresenceSnapshot) {
        preview = snapshot
        displayedPreviewConfirmation = previewConsentGate.recordPreview(snapshot)
        isPreviewCurrent = previewConsentGate.isPreviewCurrent
    }

    private func clearPreviewConsent() {
        previewCaptureGeneration &+= 1
        preview = nil
        displayedPreviewConfirmation = nil
        previewConsentGate.clearPreview()
        isPreviewCurrent = false
    }
}
