//
//  DiscordIPCClient.swift
//  YohakuCompanion
//
//  Native Swift Rich Presence client using Discord's documented local IPC RPC.
//

import Foundation
import Network

@MainActor
final class DiscordIPCClient: DiscordClient {
    private enum ConnectionPhase {
        case idle
        case connecting
        case awaitingReady
        case connected
    }

    private enum RequestKind {
        case update
        case clear
    }

    private struct PendingRequest {
        let kind: RequestKind
        let nonce: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let transportQueue = DispatchQueue(
        label: "dev.innei.YohakuCompanion.discord-ipc"
    )
    private var connection: NWConnection?
    private var phase: ConnectionPhase = .idle
    private var decoder = DiscordRPCFrameDecoder()
    private var applicationID: String?
    private var remainingSocketPaths = [String]()
    private var lastConnectionError: Error?
    private var initializationContinuations = [
        UUID: CheckedContinuation<Void, Error>
    ]()
    private var initializationTimeoutTask: Task<Void, Never>?
    private var pendingRequest: PendingRequest?
    private var requestTimeoutTask: Task<Void, Never>?

    private(set) var isConnected = false
    private(set) var connectionGeneration: UInt64 = 0

    func initialize(applicationId: String) async throws {
        try Task.checkCancellation()
        guard let numericID = UInt64(applicationId), numericID > 0 else {
            throw DiscordClientError.invalidApplicationID
        }
        if isConnected, applicationID == applicationId {
            return
        }
        if applicationID == applicationId,
           phase == .connecting || phase == .awaitingReady
        {
            try await waitForInitialization(startConnection: false)
            try Task.checkCancellation()
            return
        }

        disconnect(
            clearPresence: isConnected,
            reason: DiscordClientError.connectionReinitialized,
            updateDebugStore: false
        )
        advanceConnectionGeneration()
        applicationID = applicationId
        remainingSocketPaths = DiscordIPCPathResolver.candidatePaths().filter {
            FileManager.default.fileExists(atPath: $0)
        }
        lastConnectionError = nil
        decoder = DiscordRPCFrameDecoder()

        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "ipc"
            snapshot.isConnected = false
            snapshot.lastOutcome = "connecting"
            snapshot.lastReason = nil
        }

        try await waitForInitialization(startConnection: true)
        try Task.checkCancellation()
    }

    private func waitForInitialization(startConnection: Bool) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                initializationContinuations[waiterID] = continuation
                guard startConnection else { return }
                guard !remainingSocketPaths.isEmpty else {
                    failInitialization(DiscordClientError.discordNotRunning)
                    return
                }

                initializationTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    self?.failInitialization(DiscordClientError.connectionTimedOut)
                }
                connectToNextSocket()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelInitializationWaiter(waiterID)
            }
        }
    }

    private func cancelInitializationWaiter(_ waiterID: UUID) {
        guard let continuation = initializationContinuations.removeValue(
            forKey: waiterID
        ) else { return }
        continuation.resume(throwing: CancellationError())
    }

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
    ) async throws {
        try Task.checkCancellation()
        let activity = try DiscordRPCActivity(
            name: name,
            details: details,
            state: state,
            activityType: activityType?.rawValue,
            statusDisplayType: statusDisplayType?.rawValue,
            startTimestamp: startTimestamp,
            endTimestamp: endTimestamp,
            largeImageKey: largeImageKey,
            largeImageText: largeImageText,
            smallImageKey: smallImageKey,
            smallImageText: smallImageText,
            buttons: buttons?.map { .init(label: $0.label, url: $0.url) }
        )
        try await performRequest(kind: .update) { nonce in
            try DiscordRPCPayload.setActivity(
                processID: ProcessInfo.processInfo.processIdentifier,
                activity: activity,
                nonce: nonce
            )
        }
        try Task.checkCancellation()
    }

    func clearActivity() async throws {
        guard isConnected else { return }

        if pendingRequest?.kind == .update {
            finishPendingRequest(
                .failure(DiscordClientError.activityUpdateSuperseded)
            )
        }

        try await performRequest(kind: .clear) { nonce in
            try DiscordRPCPayload.clearActivity(
                processID: ProcessInfo.processInfo.processIdentifier,
                nonce: nonce
            )
        }
        try Task.checkCancellation()
    }

    func shutdown() {
        advanceConnectionGeneration()
        disconnect(
            clearPresence: isConnected,
            reason: DiscordClientError.clientShutDown,
            updateDebugStore: true
        )
        applicationID = nil
    }

    private func connectToNextSocket() {
        cancelCurrentConnection()
        guard let path = remainingSocketPaths.first else {
            failInitialization(
                lastConnectionError ?? DiscordClientError.discordNotRunning
            )
            return
        }
        remainingSocketPaths.removeFirst()

        let candidate = NWConnection(to: .unix(path: path), using: .tcp)
        connection = candidate
        phase = .connecting
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            Task { @MainActor in
                guard let self,
                      let candidate,
                      self.connection === candidate
                else { return }
                self.handleConnectionState(state, connection: candidate)
            }
        }
        candidate.start(queue: transportQueue)
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        connection candidate: NWConnection
    ) {
        switch state {
        case .ready:
            guard phase == .connecting, let applicationID else { return }
            phase = .awaitingReady
            receiveNextFrame(from: candidate)
            do {
                try send(
                    DiscordRPCPayload.handshake(applicationID: applicationID),
                    through: candidate
                )
            } catch {
                lastConnectionError = error
                connectToNextSocket()
            }
        case .waiting(let error), .failed(let error):
            if phase == .connecting || phase == .awaitingReady {
                lastConnectionError = DiscordClientError.connectionFailed(
                    error.localizedDescription
                )
                connectToNextSocket()
            } else {
                handleEstablishedConnectionFailure(error)
            }
        case .cancelled:
            if phase == .connected {
                handleEstablishedConnectionFailure(
                    DiscordClientError.connectionClosed("Discord closed the IPC connection")
                )
            }
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNextFrame(from candidate: NWConnection) {
        candidate.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak candidate] data, _, isComplete, error in
            Task { @MainActor in
                guard let self,
                      let candidate,
                      self.connection === candidate
                else { return }
                self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    error: error,
                    connection: candidate
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        error: NWError?,
        connection candidate: NWConnection
    ) {
        if let data, !data.isEmpty {
            do {
                let frames = try decoder.append(data)
                for frame in frames where connection === candidate {
                    try handle(frame, connection: candidate)
                }
            } catch {
                handleEstablishedConnectionFailure(error)
                return
            }
        }

        if let error {
            handleEstablishedConnectionFailure(error)
            return
        }
        if isComplete {
            handleEstablishedConnectionFailure(
                DiscordClientError.connectionClosed("Discord closed the IPC stream")
            )
            return
        }
        guard connection === candidate else { return }
        receiveNextFrame(from: candidate)
    }

    private func handle(_ frame: DiscordRPCFrame, connection candidate: NWConnection) throws {
        switch frame.opcode {
        case .frame:
            let response = try DiscordRPCPayload.response(from: frame.payload)
            if phase == .awaitingReady,
               response.command == "DISPATCH",
               response.event == "READY"
            {
                phase = .connected
                isConnected = true
                finishInitialization(.success(()))
                NSLog("[Discord] Connected through native IPC")
                DiscordDebugStore.shared.update { snapshot in
                    snapshot.clientKind = "ipc"
                    snapshot.isConnected = true
                    snapshot.lastOutcome = "connected"
                    snapshot.lastReason = nil
                }
                return
            }

            if response.event == "ERROR" {
                let error = DiscordClientError.requestRejected(
                    code: response.data?.code,
                    message: response.data?.message ?? "Discord rejected the RPC request"
                )
                if let nonce = response.nonce,
                   pendingRequest?.nonce == nonce
                {
                    finishPendingRequest(.failure(error))
                } else if phase == .awaitingReady {
                    failInitialization(error)
                }
                return
            }

            if let nonce = response.nonce,
               pendingRequest?.nonce == nonce
            {
                guard response.command == "SET_ACTIVITY" else {
                    finishPendingRequest(
                        .failure(
                            DiscordClientError.protocolViolation(
                                "Discord returned an unexpected command response"
                            )
                        )
                    )
                    return
                }
                finishPendingRequest(.success(()))
            }
        case .ping:
            let pong = try DiscordRPCFrameCodec.encode(
                opcode: .pong,
                payload: frame.payload
            )
            try send(pong, through: candidate)
        case .pong:
            break
        case .close:
            let close = DiscordRPCPayload.closePayload(from: frame.payload)
            throw DiscordClientError.connectionClosed(
                close?.message ?? "Discord closed the IPC connection"
            )
        case .handshake:
            throw DiscordClientError.protocolViolation(
                "Discord returned an unexpected handshake frame"
            )
        }
    }

    private func performRequest(
        kind: RequestKind,
        makeFrame: (String) throws -> Data
    ) async throws {
        try Task.checkCancellation()
        guard isConnected, phase == .connected, let connection else {
            throw DiscordClientError.notConnected
        }
        guard pendingRequest == nil else {
            throw DiscordClientError.updateAlreadyInProgress
        }

        let nonce = UUID().uuidString.lowercased()
        let frame = try makeFrame(nonce)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequest = PendingRequest(
                    kind: kind,
                    nonce: nonce,
                    continuation: continuation
                )
                requestTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    self?.requestDidTimeOut(nonce: nonce)
                }
                do {
                    try send(frame, through: connection)
                } catch {
                    finishPendingRequest(.failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingRequest(nonce: nonce)
            }
        }
    }

    private func requestDidTimeOut(nonce: String) {
        guard pendingRequest?.nonce == nonce else { return }
        let kind = pendingRequest?.kind
        finishPendingRequest(.failure(DiscordClientError.requestTimedOut))
        if kind == .update {
            sendUntrackedClear()
        }
    }

    private func cancelPendingRequest(nonce: String) {
        guard pendingRequest?.nonce == nonce else { return }
        let kind = pendingRequest?.kind
        finishPendingRequest(.failure(CancellationError()))
        if kind == .update {
            sendUntrackedClear()
        }
    }

    private func sendUntrackedClear() {
        guard isConnected, let connection else { return }
        do {
            let frame = try DiscordRPCPayload.clearActivity(
                processID: ProcessInfo.processInfo.processIdentifier,
                nonce: UUID().uuidString.lowercased()
            )
            try send(frame, through: connection)
        } catch {
            handleEstablishedConnectionFailure(error)
        }
    }

    private func send(_ data: Data, through candidate: NWConnection) throws {
        guard connection === candidate else {
            throw DiscordClientError.notConnected
        }
        candidate.send(content: data, completion: .contentProcessed { [weak self, weak candidate] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self,
                      let candidate,
                      self.connection === candidate
                else { return }
                self.handleEstablishedConnectionFailure(error)
            }
        })
    }

    private func handleEstablishedConnectionFailure(_ error: Error) {
        if phase == .connecting || phase == .awaitingReady {
            lastConnectionError = error
            connectToNextSocket()
            return
        }

        let wrappedError: Error
        if error is DiscordClientError || error is DiscordRPCProtocolError {
            wrappedError = error
        } else {
            wrappedError = DiscordClientError.connectionFailed(error.localizedDescription)
        }
        advanceConnectionGeneration()
        disconnect(
            clearPresence: false,
            reason: wrappedError,
            updateDebugStore: false
        )
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "ipc"
            snapshot.isConnected = false
            snapshot.lastOutcome = "disconnected"
            snapshot.lastReason = wrappedError.localizedDescription
        }
    }

    private func failInitialization(_ error: Error) {
        guard phase == .connecting
                || phase == .awaitingReady
                || !initializationContinuations.isEmpty
        else { return }
        cancelCurrentConnection()
        phase = .idle
        isConnected = false
        remainingSocketPaths.removeAll()
        finishInitialization(.failure(error))
        DiscordDebugStore.shared.update { snapshot in
            snapshot.clientKind = "ipc"
            snapshot.isConnected = false
            snapshot.lastOutcome = "connection failed"
            snapshot.lastReason = error.localizedDescription
        }
    }

    private func finishInitialization(_ result: Result<Void, Error>) {
        initializationTimeoutTask?.cancel()
        initializationTimeoutTask = nil
        let continuations = initializationContinuations.values
        initializationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    private func finishPendingRequest(_ result: Result<Void, Error>) {
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        pendingRequest.continuation.resume(with: result)
    }

    private func disconnect(
        clearPresence: Bool,
        reason: Error,
        updateDebugStore: Bool
    ) {
        let existingConnection = connection
        let shouldClear = clearPresence && isConnected && existingConnection != nil

        connection = nil
        phase = .idle
        isConnected = false
        decoder = DiscordRPCFrameDecoder()
        remainingSocketPaths.removeAll()
        initializationTimeoutTask?.cancel()
        initializationTimeoutTask = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        finishInitialization(.failure(reason))
        finishPendingRequest(.failure(reason))

        existingConnection?.stateUpdateHandler = nil
        if shouldClear,
           let existingConnection,
           let frame = try? DiscordRPCPayload.clearActivity(
               processID: ProcessInfo.processInfo.processIdentifier,
               nonce: UUID().uuidString.lowercased()
           )
        {
            existingConnection.send(
                content: frame,
                completion: .contentProcessed { _ in existingConnection.cancel() }
            )
        } else {
            existingConnection?.cancel()
        }

        if updateDebugStore {
            DiscordDebugStore.shared.update { snapshot in
                snapshot.clientKind = "ipc"
                snapshot.isConnected = false
                snapshot.lastOutcome = "shutdown"
                snapshot.lastReason = nil
            }
        }
    }

    private func cancelCurrentConnection() {
        let existingConnection = connection
        connection = nil
        existingConnection?.stateUpdateHandler = nil
        existingConnection?.cancel()
        decoder = DiscordRPCFrameDecoder()
    }

    private func advanceConnectionGeneration() {
        connectionGeneration &+= 1
        if connectionGeneration == 0 {
            connectionGeneration = 1
        }
    }
}
