// MediaInfoManager.swift
// YohakuCompanion
// Created by Innei on 2025/4/11.

import AppKit
import Foundation

/// Owns the application-facing media state. Monitoring callbacks and cache
/// mutations are main-actor isolated; provider work remains on background
/// queues owned by the individual providers.
@MainActor
public final class MediaInfoManager: NSObject {
  public typealias PlaybackStateChangedCallback = (MediaInfo?) -> Void
  typealias PlaybackSemanticChangeCallback = @MainActor @Sendable () -> Void

  private static let provider: any MediaInfoProvider = {
    if #available(macOS 15.4, *) {
      let jxaProvider = JXAMediaInfoProvider()
      guard CLIMediaInfoProvider.isMediaControlInstalled() else {
        return jxaProvider
      }
      return AdaptiveMediaInfoProvider(
        enrichmentProvider: CLIMediaInfoProvider(),
        authoritativeProvider: jxaProvider
      )
    } else {
      return LegacyMediaInfoProvider()
    }
  }()

  private static var latestInfo: MediaInfo?
  private static var playbackStateChangedCallback: PlaybackStateChangedCallback?
  private static var playbackSemanticChangeObservers: [
    UUID: PlaybackSemanticChangeCallback
  ] = [:]
  private static var debounceTask: Task<Void, Never>?
  private static var monitoringGeneration: UInt64 = 0
  private static var isMonitoring = false

  /// Registers a callback and starts a fresh monitoring session. Repeated calls
  /// replace the previous callback and provider session rather than stacking
  /// timers or observers.
  public static func startMonitoringPlaybackChanges(
    callback: @escaping PlaybackStateChangedCallback
  ) {
    let isReplacingReporterCallback = playbackStateChangedCallback != nil
    playbackStateChangedCallback = callback
    if isReplacingReporterCallback {
      pauseMonitoringPlaybackChanges()
    }
    resumeMonitoringPlaybackChanges()
  }

  /// Permanently stops monitoring and releases the registered callback and
  /// cached media value. Use `pauseMonitoringPlaybackChanges()` for sleep.
  public static func stopMonitoringPlaybackChanges() {
    playbackStateChangedCallback = nil
    stopMonitoringIfUnused()
  }

  /// Observes semantic media changes without exposing raw media content to the
  /// observer. This lets Companion request its own fresh, privacy-sanitized
  /// capture without taking ownership away from the legacy Reporter callback.
  @discardableResult
  static func addPlaybackSemanticChangeObserver(
    _ callback: @escaping PlaybackSemanticChangeCallback
  ) -> UUID {
    let identifier = UUID()
    playbackSemanticChangeObservers[identifier] = callback
    resumeMonitoringPlaybackChanges()
    return identifier
  }

  static func removePlaybackSemanticChangeObserver(_ identifier: UUID) {
    playbackSemanticChangeObservers.removeValue(forKey: identifier)
    stopMonitoringIfUnused()
  }

  /// Suspends provider resources while retaining the callback and last known
  /// value so the session can be resumed after system wake.
  public static func pauseMonitoringPlaybackChanges() {
    monitoringGeneration &+= 1
    isMonitoring = false
    debounceTask?.cancel()
    debounceTask = nil
    provider.stopMonitoring()
  }

  /// Resumes a previously registered session. The operation is idempotent.
  public static func resumeMonitoringPlaybackChanges() {
    guard !isMonitoring, hasActiveCallback() else { return }

    monitoringGeneration &+= 1
    let generation = monitoringGeneration
    isMonitoring = true

    provider.startMonitoring { info in
      Task { @MainActor in
        receive(info, generation: generation)
      }
    }
  }

  public static func hasActiveCallback() -> Bool {
    playbackStateChangedCallback != nil || !playbackSemanticChangeObservers.isEmpty
  }

  /// Compatibility entry point for callers that need a complete provider
  /// restart. Delayed restart work is intentionally avoided so a later stop
  /// cannot resurrect monitoring.
  public static func restartMonitoring() {
    guard playbackStateChangedCallback != nil else { return }
    pauseMonitoringPlaybackChanges()
    resumeMonitoringPlaybackChanges()
  }

  /// Returns only the main-actor cache and therefore never launches or waits
  /// for an external process on the caller's thread.
  public static func getMediaInfo() -> MediaInfo? {
    latestInfo
  }

  /// Fetches a fresh value through the serial coordinator. Each provider owns
  /// its bounded process timeout, so timing out one request cannot terminate an
  /// unrelated monitoring request.
  public static func getMediaInfoAsync(timeout seconds: TimeInterval = 3) async throws
    -> MediaInfo?
  {
    resolve(try await getMediaInfoFetchResultAsync(timeout: seconds))
  }

  /// Preserves the provider distinction between authoritative no-media and a
  /// temporary lookup failure. Live Desk may retain sanitized metadata after
  /// the latter, but must not present a cached position as a fresh sample.
  static func getMediaInfoFetchResultAsync(
    timeout seconds: TimeInterval = 3
  ) async throws -> MediaInfoFetchResult {
    let generation = monitoringGeneration
    let result = try await MediaInfoFetchActor.shared.requestInfo(
      using: provider,
      timeout: seconds,
      scope: generation
    )
    guard generation == monitoringGeneration else { throw CancellationError() }
    if case .resolved(let info) = result {
      latestInfo = info
    }
    return result
  }

  private static func receive(_ info: MediaInfo?, generation: UInt64) {
    guard isMonitoring, generation == monitoringGeneration else { return }

    debounceTask?.cancel()
    debounceTask = Task { @MainActor in
      do {
        try await Task.sleep(for: .milliseconds(150))
      } catch {
        return
      }

      guard
        !Task.isCancelled,
        isMonitoring,
        generation == monitoringGeneration,
        hasActiveCallback()
      else { return }

      latestInfo = info
      playbackStateChangedCallback?(info)
      let semanticObservers = Array(playbackSemanticChangeObservers.values)
      for observer in semanticObservers {
        observer()
      }
      debounceTask = nil
    }
  }

  private static func stopMonitoringIfUnused() {
    guard !hasActiveCallback() else { return }
    pauseMonitoringPlaybackChanges()
    latestInfo = nil
  }

  private static func resolve(_ result: MediaInfoFetchResult) -> MediaInfo? {
    switch result {
    case .resolved(let info):
      latestInfo = info
      return info
    case .unavailable:
      return latestInfo
    }
  }
}

/// Serializes and coalesces explicit media lookups. The synchronous provider
/// call runs in a detached task; the actor never blocks its own executor.
actor MediaInfoFetchActor {
  static let shared = MediaInfoFetchActor()

  private struct InFlight {
    let id: UInt64
    let scope: UInt64
    let deadlineUptime: TimeInterval
    let task: Task<MediaInfoFetchResult, Never>
  }

  private var inFlight: InFlight?
  private var nextRequestID: UInt64 = 0
  private var lastCompletionUptime: TimeInterval?
  private var lastCompletedScope: UInt64?
  private var lastCompletedResult: MediaInfoFetchResult?
  private let coalesceInterval: TimeInterval = 0.2

  enum ErrorType: Swift.Error {
    case timeout
  }

  func requestInfo(
    using provider: any MediaInfoProvider,
    timeout seconds: TimeInterval = 3,
    scope: UInt64
  ) async throws -> MediaInfoFetchResult {
    try Task.checkCancellation()
    guard seconds > 0 else { throw ErrorType.timeout }
    let deadlineUptime = ProcessInfo.processInfo.systemUptime + seconds

    while let current = inFlight {
      // Sharing is safe only when the existing bounded request is guaranteed
      // to finish no later than this caller's own deadline.
      guard current.deadlineUptime <= deadlineUptime else {
        throw ErrorType.timeout
      }
      let result = await current.task.value
      if current.scope == scope {
        try Task.checkCancellation()
        return result
      }

      // A lifecycle transition occurred while the old request was running.
      // Wait for its bounded completion, then perform a fresh lookup rather
      // than returning a pre-sleep/pre-stop value to the new session.
      if inFlight?.id == current.id {
        inFlight = nil
      }
      try Task.checkCancellation()
    }

    let now = ProcessInfo.processInfo.systemUptime
    if let lastCompletionUptime,
      now - lastCompletionUptime < coalesceInterval,
      lastCompletedScope == scope,
      let lastCompletedResult
    {
      return lastCompletedResult
    }

    nextRequestID &+= 1
    let requestID = nextRequestID
    let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
    guard remaining > 0 else { throw ErrorType.timeout }
    let task = Task.detached(priority: .utility) {
      provider.fetchMediaInfo(timeout: remaining)
    }
    inFlight = InFlight(
      id: requestID,
      scope: scope,
      deadlineUptime: deadlineUptime,
      task: task
    )

    let result = await task.value
    if inFlight?.id == requestID {
      inFlight = nil
      lastCompletionUptime = ProcessInfo.processInfo.systemUptime
      lastCompletedScope = scope
      lastCompletedResult = result
    }

    try Task.checkCancellation()
    return result
  }
}
