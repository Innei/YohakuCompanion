//
//  DiscordRPCProtocol.swift
//  YohakuCompanion
//
//  Discord's documented local RPC framing and Rich Presence payloads.
//

import Foundation

enum DiscordRPCOpcode: UInt32, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case ping = 3
    case pong = 4
}

struct DiscordRPCFrame: Equatable, Sendable {
    let opcode: DiscordRPCOpcode
    let payload: Data
}

enum DiscordRPCProtocolError: LocalizedError, Equatable, Sendable {
    case invalidOpcode(UInt32)
    case payloadTooLarge(Int)
    case invalidJSON
    case invalidActivityType(Int)

    var errorDescription: String? {
        switch self {
        case .invalidOpcode(let opcode):
            return "Discord sent an unsupported RPC opcode (\(opcode))"
        case .payloadTooLarge(let byteCount):
            return "Discord RPC payload exceeds the 1 MiB safety limit (\(byteCount) bytes)"
        case .invalidJSON:
            return "Discord sent an invalid RPC JSON payload"
        case .invalidActivityType(let type):
            return "Discord RPC does not support activity type \(type)"
        }
    }
}

enum DiscordRPCFrameCodec {
    static let maximumPayloadByteCount = 1_048_576
    static let headerByteCount = 8

    static func encode(opcode: DiscordRPCOpcode, payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadByteCount else {
            throw DiscordRPCProtocolError.payloadTooLarge(payload.count)
        }

        var encoded = Data(capacity: headerByteCount + payload.count)
        appendLittleEndian(opcode.rawValue, to: &encoded)
        appendLittleEndian(UInt32(payload.count), to: &encoded)
        encoded.append(payload)
        return encoded
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

struct DiscordRPCFrameDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [DiscordRPCFrame] {
        buffer.append(data)
        var frames = [DiscordRPCFrame]()

        while buffer.count >= DiscordRPCFrameCodec.headerByteCount {
            let rawOpcode = readLittleEndianUInt32(at: 0)
            guard let opcode = DiscordRPCOpcode(rawValue: rawOpcode) else {
                buffer.removeAll(keepingCapacity: false)
                throw DiscordRPCProtocolError.invalidOpcode(rawOpcode)
            }

            let payloadByteCount = Int(readLittleEndianUInt32(at: 4))
            guard payloadByteCount <= DiscordRPCFrameCodec.maximumPayloadByteCount else {
                buffer.removeAll(keepingCapacity: false)
                throw DiscordRPCProtocolError.payloadTooLarge(payloadByteCount)
            }

            let frameByteCount = DiscordRPCFrameCodec.headerByteCount + payloadByteCount
            guard buffer.count >= frameByteCount else { break }

            let payloadRange = DiscordRPCFrameCodec.headerByteCount..<frameByteCount
            frames.append(
                DiscordRPCFrame(
                    opcode: opcode,
                    payload: buffer.subdata(in: payloadRange)
                )
            )
            buffer.removeSubrange(0..<frameByteCount)
        }

        return frames
    }

    private func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        UInt32(buffer[offset])
            | (UInt32(buffer[offset + 1]) << 8)
            | (UInt32(buffer[offset + 2]) << 16)
            | (UInt32(buffer[offset + 3]) << 24)
    }
}

struct DiscordRPCActivity: Encodable, Equatable, Sendable {
    struct Timestamps: Encodable, Equatable, Sendable {
        let start: Int64?
        let end: Int64?
    }

    struct Assets: Encodable, Equatable, Sendable {
        let largeImage: String?
        let largeText: String?
        let smallImage: String?
        let smallText: String?

        private enum CodingKeys: String, CodingKey {
            case largeImage = "large_image"
            case largeText = "large_text"
            case smallImage = "small_image"
            case smallText = "small_text"
        }
    }

    struct Button: Encodable, Equatable, Sendable {
        let label: String
        let url: String
    }

    let name: String?
    let details: String?
    let state: String?
    let type: Int?
    let statusDisplayType: Int?
    let timestamps: Timestamps?
    let assets: Assets?
    let buttons: [Button]?

    private enum CodingKeys: String, CodingKey {
        case name, details, state, type, timestamps, assets, buttons
        case statusDisplayType = "status_display_type"
    }

    init(
        name: String?,
        details: String?,
        state: String?,
        activityType: Int?,
        statusDisplayType: Int?,
        startTimestamp: Int64?,
        endTimestamp: Int64?,
        largeImageKey: String?,
        largeImageText: String?,
        smallImageKey: String?,
        smallImageText: String?,
        buttons: [Button]?
    ) throws {
        if let activityType, !Self.supportedActivityTypes.contains(activityType) {
            throw DiscordRPCProtocolError.invalidActivityType(activityType)
        }

        self.name = name
        self.details = details
        self.state = state
        type = activityType
        self.statusDisplayType = statusDisplayType

        let normalizedStart = startTimestamp.flatMap { $0 >= 0 ? $0 : nil }
        let normalizedEnd = endTimestamp.flatMap { $0 >= 0 ? $0 : nil }
        timestamps = normalizedStart == nil && normalizedEnd == nil
            ? nil
            : Timestamps(start: normalizedStart, end: normalizedEnd)

        if largeImageKey == nil,
           largeImageText == nil,
           smallImageKey == nil,
           smallImageText == nil
        {
            assets = nil
        } else {
            assets = Assets(
                largeImage: largeImageKey,
                largeText: largeImageText,
                smallImage: smallImageKey,
                smallText: smallImageText
            )
        }

        let normalizedButtons = buttons.map { Array($0.prefix(2)) }
        self.buttons = normalizedButtons?.isEmpty == false ? normalizedButtons : nil
    }

    private static let supportedActivityTypes: Set<Int> = [0, 2, 3, 5]
}

struct DiscordRPCResponse: Decodable, Equatable, Sendable {
    struct ErrorData: Decodable, Equatable, Sendable {
        let code: Int?
        let message: String?
    }

    let command: String?
    let event: String?
    let nonce: String?
    let data: ErrorData?

    private enum CodingKeys: String, CodingKey {
        case command = "cmd"
        case event = "evt"
        case nonce, data
    }
}

struct DiscordRPCClosePayload: Decodable, Equatable, Sendable {
    let code: Int?
    let message: String?
}

enum DiscordRPCPayload {
    static func handshake(applicationID: String) throws -> Data {
        let payload = Handshake(version: 1, clientID: applicationID)
        return try DiscordRPCFrameCodec.encode(
            opcode: .handshake,
            payload: encodeJSON(payload)
        )
    }

    static func setActivity(
        processID: Int32,
        activity: DiscordRPCActivity,
        nonce: String
    ) throws -> Data {
        try command(
            processID: processID,
            activity: activity,
            nonce: nonce
        )
    }

    static func clearActivity(processID: Int32, nonce: String) throws -> Data {
        try command(processID: processID, activity: nil, nonce: nonce)
    }

    static func response(from payload: Data) throws -> DiscordRPCResponse {
        do {
            return try JSONDecoder().decode(DiscordRPCResponse.self, from: payload)
        } catch {
            throw DiscordRPCProtocolError.invalidJSON
        }
    }

    static func closePayload(from payload: Data) -> DiscordRPCClosePayload? {
        try? JSONDecoder().decode(DiscordRPCClosePayload.self, from: payload)
    }

    private static func command(
        processID: Int32,
        activity: DiscordRPCActivity?,
        nonce: String
    ) throws -> Data {
        let payload = SetActivityCommand(
            command: "SET_ACTIVITY",
            arguments: .init(processID: processID, activity: activity),
            nonce: nonce
        )
        return try DiscordRPCFrameCodec.encode(
            opcode: .frame,
            payload: encodeJSON(payload)
        )
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private struct Handshake: Encodable {
        let version: Int
        let clientID: String

        private enum CodingKeys: String, CodingKey {
            case version = "v"
            case clientID = "client_id"
        }
    }

    private struct SetActivityCommand: Encodable {
        struct Arguments: Encodable {
            let processID: Int32
            let activity: DiscordRPCActivity?

            private enum CodingKeys: String, CodingKey {
                case processID = "pid"
                case activity
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(processID, forKey: .processID)
                if let activity {
                    try container.encode(activity, forKey: .activity)
                } else {
                    try container.encodeNil(forKey: .activity)
                }
            }
        }

        let command: String
        let arguments: Arguments
        let nonce: String

        private enum CodingKeys: String, CodingKey {
            case command = "cmd"
            case arguments = "args"
            case nonce
        }
    }
}

enum DiscordIPCPathResolver {
    private static let environmentKeys = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]

    static func candidatePaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var directories = environmentKeys.compactMap { key -> String? in
            guard let value = environment[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL.path
        }
        directories.append("/tmp")

        var seenDirectories = Set<String>()
        let uniqueDirectories = directories.filter { seenDirectories.insert($0).inserted }
        return uniqueDirectories.flatMap { directory in
            (0..<10).map { index in
                URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("discord-ipc-\(index)")
                    .path
            }
        }
    }
}
