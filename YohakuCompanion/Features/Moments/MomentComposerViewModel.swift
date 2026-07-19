import AppKit
import Combine
import Foundation

@MainActor
final class MomentComposerViewModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case editing
        case publishing
        case published(id: String, url: URL?)
        case queued
        case failed(String)
    }

    @Published var content = ""
    @Published var includesApplication = true
    @Published var includesWindowTitle = false
    @Published var includesMedia = true
    @Published private(set) var snapshot: SanitizedPresenceSnapshot?
    @Published private(set) var phase: Phase = .loading

    private let service: YohakuCompanionService

    init(service: YohakuCompanionService = .shared) {
        self.service = service
    }

    var targetDescription: String {
        service.connection?.baseURL.host ?? "Yohaku"
    }

    var canPublish: Bool {
        guard let snapshot, phase != .publishing, phase != .loading else { return false }
        guard content.unicodeScalars.count <= 5_000 else { return false }
        let hasText = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasApplication = includesApplication && snapshot.application != nil
        let hasMedia = includesMedia && snapshot.media != nil
        return hasText || hasApplication || hasMedia
    }

    func load() async {
        await refresh()
    }

    func refresh() async {
        phase = .loading
        do {
            let snapshot = try await service.captureMomentSnapshot()
            self.snapshot = snapshot
            includesApplication = snapshot.application != nil
            includesMedia = snapshot.media != nil
            includesWindowTitle = false
            phase = .editing
        } catch {
            phase = .failed(message(for: error))
        }
    }

    func publish() async {
        guard let snapshot, canPublish else { return }
        phase = .publishing
        do {
            let result = try await service.publishMoment(
                CompanionMomentDraft(
                    content: content,
                    snapshot: snapshot,
                    includesApplication: includesApplication,
                    includesWindowTitle: includesWindowTitle,
                    includesMedia: includesMedia
                )
            )
            switch result {
            case .published(let id, let url):
                phase = .published(id: id, url: url)
            case .queued:
                phase = .queued
            }
        } catch {
            phase = .failed(message(for: error))
        }
    }

    func openPublishedURL() {
        guard case .published(_, let url?) = phase else { return }
        NSWorkspace.shared.open(url)
    }

    func returnToEditing() {
        phase = .editing
    }

    private func message(for error: Error) -> String {
        switch error {
        case YohakuCompanionServiceError.momentScopeMissing:
            return "Pair Yohaku again to grant Moment publishing access."
        case YohakuCompanionServiceError.momentFeatureUnavailable:
            return "This Yohaku server does not currently support Moment publishing."
        case YohakuCompanionServiceError.momentSchemaUnsupported:
            return "This Yohaku server does not support the required Moment format."
        case YohakuCompanionServiceError.clientUpdateRequired(let version):
            return "Update Yohaku Companion to version \(version) or later."
        case CompanionMomentMappingError.emptyMoment:
            return "Add text or include at least one captured context."
        default:
            if case CompanionHTTPClientError.server(_, let response) = error {
                return response?.error.message ?? "Yohaku rejected this Moment."
            }
            return "The Moment could not be published. Review the connection and try again."
        }
    }
}
