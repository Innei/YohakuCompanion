import Foundation

enum CompanionCoordinatorStopDisposition: Equatable, Sendable {
    case perform
    case joinInFlightStop
}

/// Small, pure lifecycle gate used by the coordinator to distinguish a
/// temporary stop from terminal object disposal. A completed stop returns to
/// `stopped`, so the same coordinator can safely be started after settings
/// change without creating a second heartbeat owner.
struct CompanionCoordinatorLifecycle: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case stopped
        case running
        case stopping
    }

    private var phase: Phase = .stopped

    var isStopping: Bool {
        phase == .stopping
    }

    mutating func beginStart() -> Bool {
        guard phase != .stopping else { return false }
        phase = .running
        return true
    }

    mutating func beginStop() -> CompanionCoordinatorStopDisposition {
        guard phase != .stopping else { return .joinInFlightStop }
        phase = .stopping
        return .perform
    }

    mutating func finishStop() {
        phase = .stopped
    }
}
