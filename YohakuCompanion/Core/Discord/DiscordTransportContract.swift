//
//  DiscordTransportContract.swift
//  YohakuCompanion
//

import Foundation

enum DiscordTransportContract {
    private static let minimumTextCharacterCount = 2
    private static let maximumTextCharacterCount = 128
    private static let maximumAssetCharacterCount = 300
    private static let maximumButtonLabelCharacterCount = 32
    private static let maximumButtonURLCharacterCount = 512

    /// Discord rejects optional activity and asset tooltip text shorter than
    /// two characters. Omitting unsupported text keeps the rest of the Rich
    /// Presence payload deliverable without adding visible or invisible filler.
    static func text(_ value: String?) -> String? {
        guard let value = boundedString(
            value,
            maximumCharacterCount: maximumTextCharacterCount
        ),
              value.count >= minimumTextCharacterCount
        else { return nil }
        return value
    }

    /// Discord activity assets accept either an uploaded asset identifier or a public
    /// HTTPS image URL. Rejecting other URL schemes keeps the optional external
    /// image path aligned with the application's network privacy boundary.
    static func assetIdentifier(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.contains("://") else {
            guard value.count <= maximumAssetCharacterCount else { return nil }
            return value
        }
        guard value.count <= maximumAssetCharacterCount else { return nil }
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { return nil }
        return value
    }

    static func button(_ button: DiscordButton) -> DiscordButton? {
        guard button.url.count <= maximumButtonURLCharacterCount,
              let label = boundedString(
            button.label,
            maximumCharacterCount: maximumButtonLabelCharacterCount
        ),
        let url = boundedString(
            button.url,
            maximumCharacterCount: maximumButtonURLCharacterCount
        ),
        let components = URLComponents(string: url),
        components.scheme?.lowercased() == "https",
        components.host?.isEmpty == false,
        components.user == nil,
        components.password == nil
        else { return nil }

        return DiscordButton(label: label, url: url)
    }

    private static func boundedString(
        _ value: String?,
        maximumCharacterCount: Int
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.count > maximumCharacterCount else { return value }
        let result = String(value.prefix(maximumCharacterCount))
        return result.isEmpty ? nil : result
    }
}

/// Retains a hosted cover across progress-only Presence updates while making a
/// track change an explicit cache boundary. Media providers may emit artwork
/// only on their enrichment callback, even though playback progress continues
/// to publish every few seconds.
struct DiscordMediaArtworkCache {
    struct MediaIdentity: Equatable {
        let title: String
        let artist: String?
        let album: String?
        let player: String?
        let applicationIdentifier: String?
    }

    private var identity: MediaIdentity?
    private var hostedURL: String?

    mutating func resolve(
        identity newIdentity: MediaIdentity,
        hostedURL newHostedURL: String?
    ) -> String? {
        if let newHostedURL {
            identity = newIdentity
            hostedURL = newHostedURL
            return newHostedURL
        }

        guard identity == newIdentity else {
            clear()
            return nil
        }
        return hostedURL
    }

    mutating func clear() {
        identity = nil
        hostedURL = nil
    }
}
