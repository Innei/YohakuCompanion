import Foundation

/// Comparable projection of every persisted input that can alter the
/// application-only Companion snapshot. Keeping this projection beside the
/// capture adapter prevents the settings consent gate and the delivery path
/// from drifting onto different definitions of "current privacy policy".
struct CompanionApplicationPresencePolicyFingerprint: Equatable, Sendable {
    struct ProcessNameMapping: Equatable, Sendable {
        let from: String
        let to: String
    }

    let isApplicationSourceEnabled: Bool
    let sharesWindowTitlesGlobally: Bool
    let privacyConfiguration: PresencePrivacyConfiguration
    let hiddenApplicationIdentifiers: Set<String>
    let processNameMappings: [ProcessNameMapping]
}

/// Release 1 capture adapter for the first vertical slice. It intentionally
/// produces `media: nil`; media continuity remains owned by the later timeline
/// slice rather than synthesizing an unreliable playback context here.
@MainActor
struct CompanionApplicationPresenceCapture {
    func policyFingerprint() -> CompanionApplicationPresencePolicyFingerprint {
        CompanionApplicationPresencePolicyFingerprint(
            isApplicationSourceEnabled: PreferencesDataModel.enabledTypes.value.types
                .contains(.process),
            sharesWindowTitlesGlobally: PreferencesDataModel.shareWindowTitles.value,
            privacyConfiguration: PreferencesDataModel.presencePrivacyConfiguration.value,
            hiddenApplicationIdentifiers: Set(PreferencesDataModel.filteredProcesses.value),
            // Mapping order is significant because capture intentionally uses
            // the first matching process-name mapping.
            processNameMappings: PreferencesDataModel.mappingList.value.getList().compactMap {
                guard $0.type == .processName else { return nil }
                return CompanionApplicationPresencePolicyFingerprint.ProcessNameMapping(
                    from: $0.from,
                    to: $0.to
                )
            }
        )
    }

    func capture(observedAt: Date = .now) -> SanitizedPresenceSnapshot {
        let enabledTypes = PreferencesDataModel.enabledTypes.value.types
        guard enabledTypes.contains(.process),
              let process = ApplicationMonitor.shared.getFocusedWindowInfo()
        else {
            return SanitizedPresenceSnapshot(
                observedAt: observedAt,
                application: nil,
                media: nil
            )
        }

        let configuration = PreferencesDataModel.presencePrivacyConfiguration.value
        let hiddenApplications = Set(PreferencesDataModel.filteredProcesses.value)
        let evaluator = PresencePrivacyEvaluator(
            configuration: configuration,
            legacyHiddenApplications: hiddenApplications,
            legacyHiddenMediaApplications: [],
            legacyHiddenMediaNames: []
        )
        let decision = evaluator.processDecision(
            applicationIdentifier: process.applicationIdentifier
        )
        let mappedName = PreferencesDataModel.mappingList.value.getList().first {
            $0.type == .processName && $0.from == process.appName
        }?.to

        let application: SanitizedApplicationPresence?
        do {
            application = try CompanionApplicationPresenceSanitizer.sanitize(
                capturedDisplayName: process.appName,
                mappedDisplayName: mappedName,
                displayAlias: decision.displayAlias,
                capturedWindowTitle: process.title,
                sharesApplication: decision.sharesApplication,
                sharesWindowTitle: decision.sharesWindowTitle,
                globalWindowTitleSharingEnabled: PreferencesDataModel.shareWindowTitles.value
            )
        } catch {
            application = nil
        }
        return SanitizedPresenceSnapshot(
            observedAt: observedAt,
            application: application,
            media: nil
        )
    }
}
