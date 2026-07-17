// JXAMediaInfoProvider.swift
// YohakuCompanion

import AppKit
import Foundation

/// Reads the system Now Playing state through an Apple-signed `osascript`
/// process. The queried MediaRemote classes are private API, but this path does
/// not require the private mediaremoted client entitlement introduced in 15.4.
final class JXAMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private enum FetchError: Error {
    case launchFailed
    case timedOut
    case processFailed(Int32, String)
    case incompleteResponse
    case invalidOutput
  }

  /// These players are queried independently so a paused or empty global
  /// Now Playing session cannot hide another supported player that is active.
  private static let supportedBundleIdentifiers = [
    "com.tencent.QQMusicMac",
    "com.netease.163music",
  ]

  private static let script = #"""
    ObjC.import("Foundation")
    ObjC.bindFunction("objc_msgSend", ["void", ["id", "selector", "id"]])

    function isNil(value) {
      if (value === null || value === undefined) return true
      try {
        return Boolean(value.isNil())
      } catch (_) {
        return false
      }
    }

    function unwrap(value) {
      if (isNil(value)) return null
      try {
        return ObjC.unwrap(value)
      } catch (_) {
        return null
      }
    }

    function infoValue(info, key) {
      if (isNil(info)) return null
      return unwrap(info.objectForKey(key))
    }

    function numericValue(value) {
      if (value === null || value === undefined) return null
      const number = Number(value)
      return isFinite(number) && number >= 0 ? number : null
    }

    function dateSeconds(value) {
      if (isNil(value)) return null
      try {
        const seconds = Number(value.timeIntervalSince1970)
        return isFinite(seconds) && seconds >= 0 ? seconds : null
      } catch (_) {
        return null
      }
    }

    function infoDateSeconds(info, key) {
      if (isNil(info)) return null
      return dateSeconds(info.objectForKey(key))
    }

    function encodedData(value) {
      if (isNil(value)) return null
      try {
        return unwrap(value.base64EncodedStringWithOptions(0))
      } catch (_) {
        return null
      }
    }

    function artworkData(artwork) {
      if (isNil(artwork)) return null
      try {
        const imageDataSelector = $.NSSelectorFromString("imageData")
        const value = artwork.respondsToSelector(imageDataSelector)
          ? artwork.imageData
          : artwork
        return encodedData(value)
      } catch (_) {
        return null
      }
    }

    function infoData(info, key) {
      if (isNil(info)) return null
      return encodedData(info.objectForKey(key))
    }

    function snapshot(
      info,
      bundleIdentifier,
      source,
      playing,
      activityDate,
      artwork
    ) {
      const playbackRate = numericValue(
        infoValue(info, "kMRMediaRemoteNowPlayingInfoPlaybackRate")
      )
      return {
        activityDate: activityDate,
        album: infoValue(info, "kMRMediaRemoteNowPlayingInfoAlbum"),
        artist: infoValue(info, "kMRMediaRemoteNowPlayingInfoArtist"),
        artworkData: artworkData(artwork) || infoData(
          info,
          "kMRMediaRemoteNowPlayingInfoArtworkData"
        ),
        bundleIdentifier: bundleIdentifier,
        duration: infoValue(info, "kMRMediaRemoteNowPlayingInfoDuration"),
        elapsedTime: infoValue(info, "kMRMediaRemoteNowPlayingInfoElapsedTime"),
        playbackRate: playbackRate,
        playing: playing === null ? playbackRate !== null && playbackRate > 0 : playing,
        source: source,
        title: infoValue(info, "kMRMediaRemoteNowPlayingInfoTitle")
      }
    }

    // JavaScriptObjC cannot pass a JavaScript callback directly to a method
    // whose block signature comes only from a private framework. A Foundation
    // block-taking API materializes the native block; the holder remains alive
    // until every MediaRemote callback has completed.
    function materializeNativeBlock(callback) {
      const holder = $.NSPredicate.predicateWithBlock(callback)
      return {
        block: holder.valueForKey("block"),
        holder: holder
      }
    }

    function run(bundleIdentifiers) {
      const framework = $.NSBundle.bundleWithPath(
        "/System/Library/PrivateFrameworks/MediaRemote.framework"
      )
      if (!framework || !framework.load) {
        throw new Error("Unable to load MediaRemote.framework")
      }

      const MROrigin = $.NSClassFromString("MROrigin")
      const MRPlayer = $.NSClassFromString("MRPlayer")
      const MRPlayerPath = $.NSClassFromString("MRPlayerPath")
      const MRNowPlayingRequest = $.NSClassFromString("MRNowPlayingRequest")
      if (
        isNil(MROrigin) ||
        isNil(MRPlayer) ||
        isNil(MRPlayerPath) ||
        isNil(MRNowPlayingRequest)
      ) {
        throw new Error("Required MediaRemote classes are unavailable")
      }

      const candidates = []
      const states = []
      const keepAlive = []
      const infoSelector = $.NSSelectorFromString(
        "requestNowPlayingInfoWithCompletion:"
      )
      const lastPlayingDateSelector = $.NSSelectorFromString(
        "requestLastPlayingDateWithCompletion:"
      )
      const artworkSelector = $.NSSelectorFromString(
        "requestNowPlayingItemArtworkWithCompletion:"
      )

      const playerPath = MRNowPlayingRequest.localNowPlayingPlayerPath
      const client = isNil(playerPath) ? null : playerPath.client
      const item = MRNowPlayingRequest.localNowPlayingItem
      const info = isNil(item) ? null : item.nowPlayingInfo
      const parentBundleIdentifier = !isNil(client)
        ? unwrap(client.parentApplicationBundleIdentifier)
        : null
      const bundleIdentifier = parentBundleIdentifier ||
        (!isNil(client) ? unwrap(client.bundleIdentifier) : null)

      candidates.push(
        snapshot(
          info,
          bundleIdentifier,
          "global",
          Boolean(MRNowPlayingRequest.localIsPlaying),
          infoDateSeconds(info, "kMRMediaRemoteNowPlayingInfoTimestamp"),
          null
        )
      )

      for (const supportedBundleIdentifier of bundleIdentifiers) {
        const state = {
          bundleIdentifier: supportedBundleIdentifier,
          artwork: null,
          artworkCompleted: false,
          dateCompleted: false,
          info: null,
          infoCompleted: false,
          infoError: null,
          lastPlayingDate: null
        }
        states.push(state)

        try {
          const path = MRPlayerPath.alloc.initWithOriginBundleIdentifierPlayer(
            MROrigin.localOrigin,
            supportedBundleIdentifier,
            MRPlayer.defaultPlayer
          )
          const request = MRNowPlayingRequest.alloc.initWithPlayerPath(path)

          if (!request.respondsToSelector(infoSelector)) {
            state.artworkCompleted = true
            state.infoCompleted = true
            state.dateCompleted = true
            continue
          }

          const infoCallback = ObjC.block(
            ["void", ["id", "id"]],
            function(nowPlayingInfo, error) {
              state.infoCompleted = true
              state.infoError = isNil(error)
                ? null
                : unwrap(error.localizedDescription)
              state.info = isNil(nowPlayingInfo) ? null : nowPlayingInfo
            }
          )
          const infoBridge = materializeNativeBlock(infoCallback)

          keepAlive.push(
            path,
            request,
            infoCallback,
            infoBridge.holder,
            infoBridge.block
          )
          $.objc_msgSend(request, infoSelector, infoBridge.block)

          if (request.respondsToSelector(artworkSelector)) {
            const artworkCallback = ObjC.block(
              ["void", ["id", "id"]],
              function(nowPlayingArtwork, _) {
                state.artworkCompleted = true
                state.artwork = isNil(nowPlayingArtwork)
                  ? null
                  : nowPlayingArtwork
              }
            )
            const artworkBridge = materializeNativeBlock(artworkCallback)
            keepAlive.push(
              artworkCallback,
              artworkBridge.holder,
              artworkBridge.block
            )
            $.objc_msgSend(request, artworkSelector, artworkBridge.block)
          } else {
            state.artworkCompleted = true
          }

          if (request.respondsToSelector(lastPlayingDateSelector)) {
            const dateCallback = ObjC.block(
              ["void", ["id", "id"]],
              function(lastPlayingDate, _) {
                state.dateCompleted = true
                state.lastPlayingDate = dateSeconds(lastPlayingDate)
              }
            )
            const dateBridge = materializeNativeBlock(dateCallback)
            keepAlive.push(dateCallback, dateBridge.holder, dateBridge.block)
            $.objc_msgSend(request, lastPlayingDateSelector, dateBridge.block)
          } else {
            state.dateCompleted = true
          }
        } catch (_) {
          // Keep the existing global provider behavior when a future macOS
          // release removes a targeted selector for one adapted player.
          state.infoCompleted = true
          state.dateCompleted = true
          state.artworkCompleted = true
        }
      }

      const deadline = $.NSDate.dateWithTimeIntervalSinceNow(1.25)
      while (
        states.some(
          state =>
            !state.infoCompleted ||
            !state.dateCompleted ||
            !state.artworkCompleted
        ) &&
        Number(deadline.timeIntervalSinceNow) > 0
      ) {
        $.NSRunLoop.currentRunLoop.runUntilDate(
          $.NSDate.dateWithTimeIntervalSinceNow(0.02)
        )
      }

      for (const state of states) {
        if (
          state.infoCompleted &&
          state.infoError === null &&
          !isNil(state.info)
        ) {
          candidates.push(
            snapshot(
              state.info,
              state.bundleIdentifier,
              "supported",
              null,
              state.lastPlayingDate,
              state.artwork
            )
          )
        }
      }

      return JSON.stringify({
        candidates: candidates,
        complete: states.every(state => state.infoCompleted)
      })
    }
    """#

  private let pollQueue = DispatchQueue(label: "media-info.jxa.poll", qos: .utility)
  private let executionGate = DispatchSemaphore(value: 1)
  private let stateLock = NSLock()
  private let pollInterval: TimeInterval
  private let requestTimeout: TimeInterval

  private var timer: DispatchSourceTimer?
  private var callback: MediaInfoProviderCallback?
  private var monitoringGeneration: UInt64 = 0
  private var isMonitoring = false
  private var hasEmitted = false
  private var lastSnapshotKey: MediaInfoSnapshotKey?
  private var selectionState: MediaSessionSelectionState

  init(
    pollInterval: TimeInterval = 1,
    requestTimeout: TimeInterval = 2,
    preferredApplicationIdentifiers: [String] = []
  ) {
    self.pollInterval = max(0.1, pollInterval)
    self.requestTimeout = max(0.1, requestTimeout)
    selectionState = MediaSessionSelectionState(
      preferredApplicationIdentifiers: preferredApplicationIdentifiers
    )
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {
    stopMonitoring()

    let timer = DispatchSource.makeTimerSource(queue: pollQueue)

    stateLock.lock()
    monitoringGeneration &+= 1
    let generation = monitoringGeneration
    self.callback = callback
    isMonitoring = true
    hasEmitted = false
    lastSnapshotKey = nil
    self.timer = timer
    timer.setEventHandler { [weak self] in
      self?.poll(generation: generation)
    }
    timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(100))
    timer.resume()
    stateLock.unlock()
  }

  func stopMonitoring() {
    stateLock.lock()
    monitoringGeneration &+= 1
    isMonitoring = false
    callback = nil
    hasEmitted = false
    lastSnapshotKey = nil
    selectionState.reset()
    let timer = self.timer
    self.timer = nil
    stateLock.unlock()

    timer?.setEventHandler {}
    timer?.cancel()
  }

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    let boundedTimeout = min(requestTimeout, timeout)
    guard boundedTimeout > 0 else { return .unavailable }

    switch performFetch(timeout: boundedTimeout) {
    case .success(let info):
      return .resolved(info)
    case .failure:
      return .unavailable
    }
  }

  private func poll(generation: UInt64) {
    stateLock.lock()
    let shouldPoll = isMonitoring && generation == monitoringGeneration
    stateLock.unlock()
    guard shouldPoll else { return }

    guard case .success(let info) = performFetch(timeout: requestTimeout) else { return }
    emitIfChanged(info, generation: generation)
  }

  private func performFetch(timeout: TimeInterval) -> Result<MediaInfo?, FetchError> {
    let startedAt = ProcessInfo.processInfo.systemUptime
    guard executionGate.wait(timeout: .now() + timeout) == .success else {
      return .failure(.timedOut)
    }
    defer { executionGate.signal() }

    stateLock.lock()
    let selectionGeneration = monitoringGeneration
    stateLock.unlock()

    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    let remaining = timeout - elapsed
    guard remaining > 0 else { return .failure(.timedOut) }

    switch ExternalProcessRunner.run(
      executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
      arguments: ["-l", "JavaScript", "-e", Self.script, "--"]
        + Self.supportedBundleIdentifiers,
      timeout: remaining
    ) {
    case .launchFailed:
      return .failure(.launchFailed)
    case .timedOut:
      return .failure(.timedOut)
    case .completed(let status, let output, let errorData):
      guard status == 0 else {
        let message = String(data: errorData, encoding: .utf8) ?? ""
        return .failure(.processFailed(status, message))
      }

      guard
        let json = try? JSONSerialization.jsonObject(with: output),
        let root = json as? [String: Any],
        let complete = root["complete"] as? Bool,
        let dictionaries = root["candidates"] as? [[String: Any]]
      else {
        return .failure(.invalidOutput)
      }
      guard complete else { return .failure(.incompleteResponse) }

      let candidates = dictionaries.compactMap { makeCandidate(from: $0) }
      stateLock.lock()
      guard selectionGeneration == monitoringGeneration else {
        stateLock.unlock()
        return .failure(.incompleteResponse)
      }
      let selected = selectionState.select(from: candidates, observedAt: .now)
      stateLock.unlock()

      return .success(selected)
    }
  }

  private func makeCandidate(from dictionary: [String: Any]) -> MediaSessionCandidate? {
    guard let info = makeMediaInfo(from: dictionary) else { return nil }

    let source: MediaSessionSource
    switch nonEmptyString(dictionary["source"]) {
    case "supported":
      source = .supportedPlayer
    case "global":
      source = .globalFallback
    default:
      return nil
    }

    let activityDate = numberValue(dictionary["activityDate"]).map {
      Date(timeIntervalSince1970: $0)
    }
    return MediaSessionCandidate(
      sessionIdentifier: info.applicationIdentifier,
      info: info,
      source: source,
      reportedActivityDate: activityDate
    )
  }

  private func makeMediaInfo(from dictionary: [String: Any]) -> MediaInfo? {
    let title = nonEmptyString(dictionary["title"])
    let artist = nonEmptyString(dictionary["artist"])
    let album = nonEmptyString(dictionary["album"])
    let playing = (dictionary["playing"] as? Bool) ?? false
    let bundleIdentifier = nonEmptyString(dictionary["bundleIdentifier"])

    guard title != nil || playing else { return nil }

    let runningApplication = bundleIdentifier.flatMap {
      NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
    }

    return MediaInfo(
      name: title,
      artist: artist,
      album: album,
      image: nonEmptyString(dictionary["artworkData"]),
      duration: numberValue(dictionary["duration"]),
      elapsedTime: numberValue(dictionary["elapsedTime"]),
      processID: runningApplication.map { Int($0.processIdentifier) } ?? 0,
      processName: runningApplication?.localizedName ?? "",
      executablePath: runningApplication?.executableURL?.path ?? "",
      playing: playing,
      applicationIdentifier: bundleIdentifier
    )
  }

  private func nonEmptyString(_ value: Any?) -> String? {
    guard let string = value as? String, !string.isEmpty else { return nil }
    return string
  }

  private func numberValue(_ value: Any?) -> Double? {
    let number: Double?
    if let value = value as? NSNumber {
      number = value.doubleValue
    } else if let value = value as? String {
      number = Double(value)
    } else {
      number = nil
    }

    guard let number, number.isFinite, number >= 0 else { return nil }
    return number
  }

  private func emitIfChanged(_ info: MediaInfo?, generation: UInt64) {
    let snapshotKey = MediaInfoSnapshotKey(info)

    stateLock.lock()
    guard isMonitoring, generation == monitoringGeneration else {
      stateLock.unlock()
      return
    }
    guard !hasEmitted || lastSnapshotKey != snapshotKey else {
      stateLock.unlock()
      return
    }
    hasEmitted = true
    lastSnapshotKey = snapshotKey
    let callback = self.callback
    stateLock.unlock()

    callback?(info)
  }
}
