//
//  DiscordClient.swift
//  YohakuCompanion
//
//  Created by Codex on 2025/8/27.
//

import Foundation

enum DiscordActivityType: Int {
    case playing = 0
    case streaming = 1
    case listening = 2
    case watching = 3
    case custom = 4
    case competing = 5
}

@MainActor
protocol DiscordClient: AnyObject {
    var isConnected: Bool { get }
    var connectionGeneration: UInt64 { get }
    func initialize(applicationId: String) async throws
    func setActivity(
        name: String?,
        details: String?,
        state: String?,
        activityType: DiscordActivityType?,
        statusDisplayType: DiscordStatusDisplayType?,
        startTimestamp: Int64?,
        endTimestamp: Int64?,
        largeImageKey: String?,
        largeImageText: String?,
        smallImageKey: String?,
        smallImageText: String?,
        buttons: [DiscordButton]?
    ) async throws
    func clearActivity() async throws
    func shutdown()
}

enum DiscordClientError: LocalizedError, Sendable {
    case invalidApplicationID
    case discordNotRunning
    case notConnected
    case connectionReinitialized
    case connectionTimedOut
    case connectionFailed(String)
    case connectionClosed(String)
    case protocolViolation(String)
    case requestRejected(code: Int?, message: String)
    case requestTimedOut
    case updateAlreadyInProgress
    case activityUpdateSuperseded
    case clientShutDown

    var errorDescription: String? {
        switch self {
        case .invalidApplicationID:
            return "Discord Application ID must be a positive integer"
        case .discordNotRunning:
            return "Discord desktop is not running or its IPC socket is unavailable"
        case .notConnected:
            return "Discord client is not connected"
        case .connectionReinitialized:
            return "Discord IPC was reinitialized"
        case .connectionTimedOut:
            return "Discord IPC handshake timed out"
        case .connectionFailed(let reason):
            return "Discord IPC connection failed: \(reason)"
        case .connectionClosed(let reason):
            return reason
        case .protocolViolation(let reason):
            return "Discord IPC protocol error: \(reason)"
        case .requestRejected(let code, let message):
            if let code {
                return "Discord rejected the activity request (\(code)): \(message)"
            }
            return "Discord rejected the activity request: \(message)"
        case .requestTimedOut:
            return "Discord activity request timed out"
        case .updateAlreadyInProgress:
            return "A Discord activity update is already in progress"
        case .activityUpdateSuperseded:
            return "Discord activity update was superseded by a clear"
        case .clientShutDown:
            return "Discord IPC client was shut down"
        }
    }
}

@MainActor
enum DiscordClientProvider {
    static let shared: DiscordClient = DiscordIPCClient()
}
