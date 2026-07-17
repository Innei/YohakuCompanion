// MediaInfoProvider.swift
// YohakuCompanion
// Created by Claude on 2025/7/12.

import Darwin
import Foundation

typealias MediaInfoProviderCallback = @Sendable (MediaInfo?) -> Void

/// Distinguishes a successful media lookup, including an authoritative
/// no-media state, from a provider that could not answer the request.
enum MediaInfoFetchResult: Sendable {
  case resolved(MediaInfo?)
  case unavailable
}

/// Resolves the current position exposed by `media-control get`. Newer builds
/// provide `elapsedTimeNow` when invoked with `--now`; older builds expose a
/// captured elapsed value plus the wall-clock timestamp of that sample.
enum MediaControlPlaybackTiming {
  static func currentPosition(
    from payload: [String: Any],
    playing: Bool,
    now: Date = .now
  ) -> Double? {
    if let current = nonNegativeSeconds(payload["elapsedTimeNow"]) {
      return current
    }

    guard
      let captured =
        nonNegativeSeconds(payload["elapsedTime"])
        ?? nonNegativeSeconds(payload["elapsed"])
        ?? nonNegativeSeconds(payload["position"])
        ?? nonNegativeSeconds(payload["progressSeconds"])
    else {
      return nil
    }

    guard
      playing,
      let capturedAt = timestamp(payload["timestamp"]),
      now > capturedAt
    else {
      return captured
    }

    let advanced = captured + now.timeIntervalSince(capturedAt)
    return advanced.isFinite ? advanced : captured
  }

  static func nonNegativeSeconds(_ value: Any?) -> Double? {
    if let number = value as? NSNumber {
      let result = number.doubleValue
      return result.isFinite && result >= 0 ? result : nil
    }
    guard let string = value as? String, !string.isEmpty else { return nil }
    if let result = Double(string), result.isFinite {
      return result >= 0 ? result : nil
    }

    let parts = string.split(separator: ":", omittingEmptySubsequences: false).reversed()
    var multiplier = 1.0
    var total = 0.0
    for part in parts {
      guard
        !part.isEmpty,
        let value = Double(part.replacingOccurrences(of: ",", with: ".")),
        value.isFinite,
        value >= 0
      else {
        return nil
      }
      total += value * multiplier
      multiplier *= 60
    }
    return total.isFinite ? total : nil
  }

  private static func timestamp(_ value: Any?) -> Date? {
    if let date = value as? Date { return date }
    guard let string = value as? String, !string.isEmpty else { return nil }

    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }
}

/// Identifies how a media session was discovered. Supported-player sessions
/// are queried directly by bundle identifier; the global session preserves
/// compatibility with browsers and players without a dedicated adapter.
enum MediaSessionSource: Int, Sendable {
  case globalFallback
  case supportedPlayer
}

/// A single independently queried Now Playing session before product-level
/// selection is applied.
struct MediaSessionCandidate: Sendable {
  let sessionIdentifier: String
  let info: MediaInfo
  let source: MediaSessionSource
  let reportedActivityDate: Date?

  init(
    sessionIdentifier: String? = nil,
    info: MediaInfo,
    source: MediaSessionSource,
    reportedActivityDate: Date?
  ) {
    if let sessionIdentifier, !sessionIdentifier.isEmpty {
      self.sessionIdentifier = sessionIdentifier
    } else if let applicationIdentifier = info.applicationIdentifier,
              !applicationIdentifier.isEmpty
    {
      self.sessionIdentifier = applicationIdentifier
    } else {
      self.sessionIdentifier = "global"
    }
    self.info = info
    self.source = source
    self.reportedActivityDate = reportedActivityDate
  }
}

/// Stateful, deterministic arbitration for concurrent media sessions.
///
/// Ranking is lexicographic: playing state, explicit application preference,
/// dedicated-adapter source, most recent transition to playing, previous
/// winner, then a stable identifier. The state preserves the observed start
/// time while a player changes tracks, so metadata updates do not steal focus.
struct MediaSessionSelectionState: Sendable {
  private struct Observation: Sendable {
    let isPlaying: Bool
    let lastStartedAt: Date?
  }

  private struct RankedCandidate {
    let candidate: MediaSessionCandidate
    let lastStartedAt: Date?
  }

  private let preferredRankByIdentifier: [String: Int]
  private var observations: [String: Observation] = [:]
  private var lastSelectedIdentifier: String?

  init(preferredApplicationIdentifiers: [String] = []) {
    var ranks: [String: Int] = [:]
    for (index, identifier) in preferredApplicationIdentifiers.enumerated()
      where ranks[identifier] == nil
    {
      ranks[identifier] = index
    }
    preferredRankByIdentifier = ranks
  }

  mutating func reset() {
    observations.removeAll(keepingCapacity: true)
    lastSelectedIdentifier = nil
  }

  mutating func select(
    from candidates: [MediaSessionCandidate],
    observedAt: Date = .now
  ) -> MediaInfo? {
    let candidatesByIdentifier = deduplicatedMeaningfulCandidates(candidates)
    guard !candidatesByIdentifier.isEmpty else {
      reset()
      return nil
    }

    let observedIdentifiers = Set(candidatesByIdentifier.keys)
    observations = observations.filter { observedIdentifiers.contains($0.key) }

    var rankedCandidates: [RankedCandidate] = []
    rankedCandidates.reserveCapacity(candidatesByIdentifier.count)

    for (identifier, candidate) in candidatesByIdentifier {
      let previous = observations[identifier]
      let reportedActivityDate = normalizedActivityDate(
        candidate.reportedActivityDate,
        observedAt: observedAt
      )

      let lastStartedAt: Date?
      if candidate.info.playing {
        if let previous {
          lastStartedAt = previous.isPlaying
            ? (previous.lastStartedAt ?? reportedActivityDate ?? observedAt)
            : observedAt
        } else {
          lastStartedAt = reportedActivityDate ?? observedAt
        }
      } else {
        lastStartedAt = previous?.lastStartedAt ?? reportedActivityDate
      }

      observations[identifier] = Observation(
        isPlaying: candidate.info.playing,
        lastStartedAt: lastStartedAt
      )
      rankedCandidates.append(
        RankedCandidate(candidate: candidate, lastStartedAt: lastStartedAt)
      )
    }

    let previousWinner = lastSelectedIdentifier
    let winner = rankedCandidates.sorted {
      outranks($0, $1, previousWinner: previousWinner)
    }.first
    lastSelectedIdentifier = winner?.candidate.sessionIdentifier
    return winner?.candidate.info
  }

  private func deduplicatedMeaningfulCandidates(
    _ candidates: [MediaSessionCandidate]
  ) -> [String: MediaSessionCandidate] {
    var result: [String: MediaSessionCandidate] = [:]

    for candidate in candidates
      where candidate.info.name?.isEmpty == false || candidate.info.playing
    {
      let identifier = candidate.sessionIdentifier
      guard let existing = result[identifier] else {
        result[identifier] = candidate
        continue
      }

      if shouldReplaceDuplicate(existing, with: candidate) {
        result[identifier] = candidate
      }
    }

    return result
  }

  private func shouldReplaceDuplicate(
    _ existing: MediaSessionCandidate,
    with candidate: MediaSessionCandidate
  ) -> Bool {
    if existing.source != candidate.source {
      return candidate.source == .supportedPlayer
    }
    if existing.info.playing != candidate.info.playing {
      return candidate.info.playing
    }

    switch (existing.reportedActivityDate, candidate.reportedActivityDate) {
    case (.none, .some):
      return true
    case (.some(let existingDate), .some(let candidateDate)):
      return candidateDate > existingDate
    default:
      return false
    }
  }

  private func normalizedActivityDate(
    _ date: Date?,
    observedAt: Date
  ) -> Date? {
    guard
      let date,
      date.timeIntervalSince1970.isFinite,
      date <= observedAt.addingTimeInterval(300)
    else {
      return nil
    }
    return date
  }

  private func outranks(
    _ lhs: RankedCandidate,
    _ rhs: RankedCandidate,
    previousWinner: String?
  ) -> Bool {
    if lhs.candidate.info.playing != rhs.candidate.info.playing {
      return lhs.candidate.info.playing
    }

    let lhsPreferredRank = preferredRankByIdentifier[
      lhs.candidate.sessionIdentifier
    ] ?? Int.max
    let rhsPreferredRank = preferredRankByIdentifier[
      rhs.candidate.sessionIdentifier
    ] ?? Int.max
    if lhsPreferredRank != rhsPreferredRank {
      return lhsPreferredRank < rhsPreferredRank
    }

    if lhs.candidate.source != rhs.candidate.source {
      return lhs.candidate.source.rawValue > rhs.candidate.source.rawValue
    }

    if lhs.lastStartedAt != rhs.lastStartedAt {
      switch (lhs.lastStartedAt, rhs.lastStartedAt) {
      case (.some(let lhsDate), .some(let rhsDate)):
        return lhsDate > rhsDate
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }
    }

    let lhsWasPreviousWinner = lhs.candidate.sessionIdentifier == previousWinner
    let rhsWasPreviousWinner = rhs.candidate.sessionIdentifier == previousWinner
    if lhsWasPreviousWinner != rhsWasPreviousWinner {
      return lhsWasPreviousWinner
    }

    return lhs.candidate.sessionIdentifier < rhs.candidate.sessionIdentifier
  }
}

/// Stable state used to suppress duplicate callbacks without discarding
/// enrichment-only changes such as artwork or process metadata.
enum MediaInfoSnapshotKey: Equatable, Sendable {
  case noMedia
  case media(
    name: String?,
    artist: String?,
    album: String?,
    imageHash: Int?,
    imageLength: Int,
    duration: Double?,
    hasElapsedTime: Bool,
    processID: Int,
    processName: String,
    executablePath: String,
    playing: Bool,
    applicationIdentifier: String?
  )

  init(_ info: MediaInfo?) {
    guard let info else {
      self = .noMedia
      return
    }

    self = .media(
      name: info.name,
      artist: info.artist,
      album: info.album,
      imageHash: info.image?.hashValue,
      imageLength: info.image?.utf8.count ?? 0,
      duration: info.duration,
      hasElapsedTime: info.elapsedTime != nil,
      processID: info.processID,
      processName: info.processName,
      executablePath: info.executablePath,
      playing: info.playing,
      applicationIdentifier: info.applicationIdentifier
    )
  }
}

/// Protocol for providing media information from different sources
protocol MediaInfoProvider: AnyObject, Sendable {
  /// Start monitoring playback changes
  func startMonitoring(callback: @escaping MediaInfoProviderCallback)

  /// Stop monitoring playback changes
  func stopMonitoring()

  /// Resolve current media information without conflating no media with a
  /// temporary provider failure.
  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult
}

extension MediaInfoProvider {
  func fetchMediaInfo() -> MediaInfoFetchResult {
    fetchMediaInfo(timeout: 3)
  }
}

/// Result of a bounded external-process invocation. Both output pipes are
/// drained while the child is running so that a full pipe cannot deadlock the
/// parent while it waits for termination.
enum ExternalProcessResult: Sendable {
  case completed(status: Int32, stdout: Data, stderr: Data)
  case launchFailed
  case timedOut
}

enum ExternalProcessRunner {
  static func run(
    executableURL: URL,
    arguments: [String],
    timeout: TimeInterval
  ) -> ExternalProcessResult {
    guard timeout > 0 else { return .timedOut }

    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      return .launchFailed
    }

    let outputReader = PipeReader(handle: outputPipe.fileHandleForReading)
    let errorReader = PipeReader(handle: errorPipe.fileHandleForReading)
    outputReader.start()
    errorReader.start()

    let waitResult = completion.wait(timeout: .now() + timeout)
    guard waitResult == .success else {
      terminate(process, completion: completion)
      _ = outputReader.finish()
      _ = errorReader.finish()
      process.terminationHandler = nil
      return .timedOut
    }

    let output = outputReader.finish()
    let error = errorReader.finish()
    process.terminationHandler = nil
    return .completed(
      status: process.terminationStatus,
      stdout: output,
      stderr: error
    )
  }

  private static func terminate(_ process: Process, completion: DispatchSemaphore) {
    guard process.isRunning else { return }

    process.terminate()
    guard completion.wait(timeout: .now() + 0.25) != .success else { return }

    if process.isRunning {
      Darwin.kill(process.processIdentifier, SIGKILL)
      _ = completion.wait(timeout: .now() + 0.25)
    }
  }
}

private final class PipeReader: @unchecked Sendable {
  private let handle: FileHandle
  private let queue = DispatchQueue(label: "media-info.process-pipe-reader")
  private let group = DispatchGroup()
  private let lock = NSLock()
  private var data = Data()

  init(handle: FileHandle) {
    self.handle = handle
  }

  func start() {
    group.enter()
    queue.async { [self] in
      let readData = handle.readDataToEndOfFile()
      lock.lock()
      data = readData
      lock.unlock()
      group.leave()
    }
  }

  func finish() -> Data {
    if group.wait(timeout: .now() + 1) != .success {
      try? handle.close()
      _ = group.wait(timeout: .now() + 0.1)
    }

    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
