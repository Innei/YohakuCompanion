import Combine
import Foundation

@MainActor
final class YohakuSettingsStore: ObservableObject {
    @Published var serverURL = ""
    @Published var deviceName = ProcessInfo.processInfo.hostName
    @Published var pairingCode = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var warningMessage: String?
    @Published private(set) var hasLoaded = false

    var canPair: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(using service: YohakuCompanionService) async {
        guard !hasLoaded else { return }
        clearNotices()

        do {
            try await service.load()
            synchronize(using: service)
            if service.connection != nil {
                await service.refreshPreview()
            }
        } catch {
            errorMessage = userMessage(for: error)
        }

        hasLoaded = true
    }

    func pair(using service: YohakuCompanionService) async {
        clearNotices()

        do {
            let baseURL = try validatedBaseURL()
            try await service.pair(
                baseURL: baseURL,
                pairingCode: pairingCode,
                deviceName: deviceName
            )
            pairingCode = ""
            synchronize(using: service)
            await service.refreshPreview()
        } catch {
            errorMessage = userMessage(for: error)
        }
    }

    func setLiveDeskEnabled(
        _ isEnabled: Bool,
        using service: YohakuCompanionService
    ) async {
        clearNotices()

        do {
            try await service.setLiveDeskEnabled(isEnabled)
            synchronize(using: service)
        } catch {
            synchronize(using: service)
            errorMessage = userMessage(for: error)
        }
    }

    func refreshPreview(using service: YohakuCompanionService) async {
        clearNotices()
        await service.refreshPreview()
    }

    func removeConnection(using service: YohakuCompanionService) async {
        clearNotices()

        do {
            let result = try await service.removeConnection()
            pairingCode = ""
            if result.retainedClearedKeychainValue {
                warningMessage = "The local Yohaku connection was removed, but an inaccessible Keychain copy may remain on this Mac. Revoke this device in Yohaku Admin."
            }
        } catch {
            synchronize(using: service)
            errorMessage = userMessage(for: error)
        }
    }

    func synchronize(using service: YohakuCompanionService) {
        if let connection = service.connection {
            serverURL = connection.baseURL.absoluteString
        }
    }

    private func validatedBaseURL() throws -> URL {
        let value = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else {
            throw CompanionConnectionConfigurationError.invalidBaseURL
        }
        _ = try CompanionServerConfiguration(baseURL: url)
        return url
    }

    private func clearNotices() {
        errorMessage = nil
        warningMessage = nil
    }

    private func userMessage(for error: Error) -> String {
        if let error = error as? YohakuCompanionServiceError {
            switch error {
            case .operationInProgress:
                return "Another Yohaku connection update is still in progress. Wait and try again."
            case .applicationTerminating:
                return "Yohaku connection settings are unavailable while the app is quitting."
            case .missingConnection:
                return "The saved Yohaku connection is missing. Pair this Mac again."
            case .previewOutOfDate:
                return "Presence privacy settings changed. Review the updated public preview, then enable Live Desk again."
            case .momentScopeMissing,
                 .momentFeatureUnavailable,
                 .momentSchemaUnsupported,
                 .clientUpdateRequired:
                return "Moment publishing is unavailable for this connection."
            }
        }

        if error is SettingsMutationCoordinatorError {
            return "Yohaku connection settings are temporarily unavailable while the app resets data or quits."
        }

        if let error = error as? CompanionConnectionConfigurationError {
            switch error {
            case .invalidBaseURL:
                return "Enter a valid Yohaku server URL, including https://."
            case .insecureBaseURL:
                return "Use HTTPS for a Yohaku server. HTTP is allowed only for localhost."
            case .missingCredential:
                return "The saved Yohaku credential is missing. Remove this connection and pair again."
            }
        }

        if let error = error as? CompanionPairingClientError {
            switch error {
            case .invalidPairingCode:
                return "Enter the one-time pairing code shown in Yohaku Admin."
            case .invalidDeviceName:
                return "Enter a device name between 1 and 120 characters."
            case .requiredPresenceScopeMissing:
                return "This pairing does not permit Live Desk sharing. Generate a new pairing code."
            case .clientUpdateRequired:
                return "This version of Yohaku Companion must be updated before it can pair."
            case .presenceSchemaUnsupported:
                return "This Yohaku server uses an incompatible Live Desk protocol."
            case .serverFeatureUnavailable:
                return "This Yohaku server does not support Live Desk."
            case .invalidCapabilities:
                return "This Yohaku server returned an invalid capability description."
            case .responseTooLarge, .invalidResponse, .responseDecodingFailed:
                return "The Yohaku server returned an invalid pairing response."
            case .server(_, let code):
                switch code {
                case .pairingExpired:
                    return "This pairing code has expired or was already used. Generate a new code."
                case .validationFailed:
                    return "This pairing code is not valid. Check the code and try again."
                case .rateLimited:
                    return "Too many pairing attempts were made. Wait briefly and try again."
                case .internalError, .httpError, nil:
                    return "The Yohaku server could not complete pairing. Try again."
                }
            }
        }

        if let error = error as? CompanionConnectionStoreError {
            switch error {
            case .credentialStorageUnavailable:
                return "Protected credential storage is unavailable. Unlock this Mac and try again."
            case .credentialPersistenceFailed:
                return "The device credential could not be saved securely. Try pairing again."
            case .missingCredential:
                return "The saved device credential is missing. Remove this connection and pair again."
            case .invalidMetadata, .invalidDeviceIdentifier, .invalidNextSequence:
                return "The saved Yohaku connection is invalid. Remove it and pair this Mac again."
            }
        }

        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "This Mac is offline. Reconnect to the network and try again."
            case .timedOut:
                return "The Yohaku server did not respond in time. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "The Yohaku server could not be reached. Check the server URL."
            default:
                return "A network error prevented the Yohaku request. Try again."
            }
        }

        return "Yohaku Companion could not complete this request. Try again."
    }
}
