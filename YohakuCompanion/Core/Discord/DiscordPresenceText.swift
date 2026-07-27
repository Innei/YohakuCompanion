//
//  DiscordPresenceText.swift
//  YohakuCompanion
//

import Foundation

enum DiscordPresenceText {
    static func mediaIdentity(title: String?, artist: String?) -> String? {
        guard let title = normalized(title) else { return nil }
        guard let artist = normalized(artist) else { return title }
        return "\(title) - \(artist)"
    }

    static func listeningStatus(title: String?, artist: String?) -> String? {
        guard let identity = mediaIdentity(title: title, artist: artist) else { return nil }
        return "正在听：\(identity)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
