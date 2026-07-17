import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
  case expectation(String)

  var description: String {
    switch self {
    case .expectation(let message):
      return message
    }
  }
}

private final class StubMediaInfoProvider: MediaInfoProvider, @unchecked Sendable {
  private let result: MediaInfoFetchResult

  init(result: MediaInfoFetchResult) {
    self.result = result
  }

  func startMonitoring(callback: @escaping MediaInfoProviderCallback) {}
  func stopMonitoring() {}

  func fetchMediaInfo(timeout: TimeInterval) -> MediaInfoFetchResult {
    result
  }
}

@main
private struct MediaTimingSemanticsHarness {
  static func main() throws {
    try verifyMediaControlTiming()
    try verifyMediaInfoNormalization()
    try verifyAdaptiveMerge()
    try verifyMultiSessionSelection()

    print("Media timing semantics behavior passed")
  }

  private static func verifyMediaControlTiming() throws {
    let now = Date(timeIntervalSince1970: 1_000)

    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: [
          "elapsedTime": 0,
          "elapsedTimeNow": 42.5,
          "timestamp": "1970-01-01T00:00:00Z",
        ],
        playing: true,
        now: now
      ) == 42.5,
      "elapsedTimeNow did not override the captured zero position"
    )
    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: ["elapsedTime": 45, "elapsedTimeNow": 0],
        playing: true,
        now: now
      ) == 0,
      "a real elapsedTimeNow zero did not override an older position"
    )
    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: [
          "elapsedTime": 5,
          "timestamp": "1970-01-01T00:16:30Z",
        ],
        playing: true,
        now: now
      ) == 15,
      "playing position was not advanced from its timestamp"
    )
    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: [
          "elapsedTime": 5,
          "timestamp": "1970-01-01T00:16:30Z",
        ],
        playing: false,
        now: now
      ) == 5,
      "paused position advanced from its timestamp"
    )
    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: ["elapsedTime": "01:02.5"],
        playing: true,
        now: now
      ) == 62.5,
      "clock-formatted elapsed time was not parsed"
    )
    try expect(
      MediaControlPlaybackTiming.currentPosition(
        from: ["elapsedTimeNow": -1],
        playing: true,
        now: now
      ) == nil,
      "invalid current position became a real zero"
    )
  }

  private static func verifyMediaInfoNormalization() throws {
    let missing = media(duration: nil, elapsedTime: nil)
    try expect(missing.duration == nil, "missing duration was converted to a value")
    try expect(missing.elapsedTime == nil, "missing position was converted to a value")

    let zero = media(duration: 0, elapsedTime: 0)
    try expect(zero.duration == 0, "real zero duration was not preserved")
    try expect(zero.elapsedTime == 0, "real zero position was not preserved")

    let invalidNegative = media(duration: -1, elapsedTime: -1)
    try expect(invalidNegative.duration == nil, "negative duration became a real zero")
    try expect(invalidNegative.elapsedTime == nil, "negative position became a real zero")
    try expect(
      MediaInfoSnapshotKey(missing) != MediaInfoSnapshotKey(zero),
      "snapshot identity conflated missing duration with zero"
    )
    try expect(
      MediaInfoSnapshotKey(media(duration: 120, elapsedTime: nil))
        != MediaInfoSnapshotKey(media(duration: 120, elapsedTime: 0)),
      "snapshot identity conflated missing position with zero"
    )

    let clamped = media(duration: 120, elapsedTime: 145)
    try expect(clamped.elapsedTime == 120, "position was not clamped to known duration")

    let zeroDurationClamp = media(duration: 0, elapsedTime: 10)
    try expect(zeroDurationClamp.elapsedTime == 0, "known zero duration did not clamp position")

    let unboundedPosition = media(duration: nil, elapsedTime: 10)
    try expect(
      unboundedPosition.elapsedTime == 10,
      "position was discarded when duration was unavailable"
    )
  }

  private static func verifyAdaptiveMerge() throws {
    let enriched = try merged(
      authoritative: media(duration: nil, elapsedTime: nil),
      enrichment: .resolved(media(duration: 180, elapsedTime: 45))
    )
    try expect(enriched.duration == 180, "merge did not fill a missing duration")
    try expect(enriched.elapsedTime == 45, "merge did not fill a missing position")

    let authoritativeZero = try merged(
      authoritative: media(duration: 0, elapsedTime: 0),
      enrichment: .resolved(media(duration: 180, elapsedTime: 45))
    )
    try expect(authoritativeZero.duration == 0, "merge replaced a real zero duration")
    try expect(
      authoritativeZero.elapsedTime == 0,
      "known zero duration did not clamp the enriched position"
    )

    let reliableEnrichment = try merged(
      authoritative: media(duration: 180, elapsedTime: 0),
      enrichment: .resolved(media(duration: 180, elapsedTime: 45))
    )
    try expect(
      reliableEnrichment.elapsedTime == 45,
      "MediaRemote zero overrode the current media-control position"
    )

    let seekedToStart = try merged(
      authoritative: media(duration: 180, elapsedTime: 60),
      enrichment: .resolved(media(duration: 180, elapsedTime: 0))
    )
    try expect(
      seekedToStart.elapsedTime == 0,
      "a reliable media-control zero position was discarded"
    )

    let jxaFallback = try merged(
      authoritative: media(duration: 180, elapsedTime: 12),
      enrichment: .unavailable
    )
    try expect(
      jxaFallback.elapsedTime == 12,
      "authoritative JXA timing was lost when media-control was unavailable"
    )

    let differentItem = try merged(
      authoritative: media(name: "Current", duration: 180, elapsedTime: 7),
      enrichment: .resolved(media(name: "Stale", duration: 180, elapsedTime: 90))
    )
    try expect(
      differentItem.name == "Current" && differentItem.elapsedTime == 7,
      "timing from a different media item was merged"
    )
  }

  private static func verifyMultiSessionSelection() throws {
    let qqMusic = "com.tencent.QQMusicMac"
    let neteaseMusic = "com.netease.163music"
    let chrome = "com.google.Chrome"
    let observedAt = Date(timeIntervalSince1970: 1_000)

    var pausedGlobalState = MediaSessionSelectionState()
    let selectedOverPausedGlobal = pausedGlobalState.select(
      from: [
        candidate(
          applicationIdentifier: qqMusic,
          source: .supportedPlayer,
          playing: true,
          activityDate: Date(timeIntervalSince1970: 900)
        ),
        candidate(
          applicationIdentifier: chrome,
          source: .globalFallback,
          playing: false,
          activityDate: Date(timeIntervalSince1970: 990)
        ),
      ],
      observedAt: observedAt
    )
    try expect(
      selectedOverPausedGlobal?.applicationIdentifier == qqMusic,
      "a paused global session masked a supported player that was playing"
    )

    var emptySessionState = MediaSessionSelectionState()
    let emptySession = candidate(
      applicationIdentifier: neteaseMusic,
      source: .supportedPlayer,
      playing: false,
      name: nil,
      activityDate: nil
    )
    try expect(
      emptySessionState.select(from: [emptySession], observedAt: observedAt) == nil,
      "an opened player without media became the selected session"
    )

    var simultaneousState = MediaSessionSelectionState()
    let qqCandidate = candidate(
      applicationIdentifier: qqMusic,
      source: .supportedPlayer,
      playing: true,
      activityDate: Date(timeIntervalSince1970: 900)
    )
    let neteaseCandidate = candidate(
      applicationIdentifier: neteaseMusic,
      source: .supportedPlayer,
      playing: true,
      activityDate: Date(timeIntervalSince1970: 950)
    )
    let mostRecentlyStarted = simultaneousState.select(
      from: [qqCandidate, neteaseCandidate],
      observedAt: observedAt
    )
    try expect(
      mostRecentlyStarted?.applicationIdentifier == neteaseMusic,
      "the most recently started supported player was not selected"
    )

    let qqMetadataChanged = candidate(
      applicationIdentifier: qqMusic,
      source: .supportedPlayer,
      playing: true,
      activityDate: Date(timeIntervalSince1970: 990)
    )
    let selectionAfterMetadataChange = simultaneousState.select(
      from: [qqMetadataChanged, neteaseCandidate],
      observedAt: Date(timeIntervalSince1970: 1_010)
    )
    try expect(
      selectionAfterMetadataChange?.applicationIdentifier == neteaseMusic,
      "a track metadata update replaced the actual most recently started player"
    )

    let qqPaused = candidate(
      applicationIdentifier: qqMusic,
      source: .supportedPlayer,
      playing: false,
      activityDate: Date(timeIntervalSince1970: 990)
    )
    _ = simultaneousState.select(
      from: [qqPaused, neteaseCandidate],
      observedAt: Date(timeIntervalSince1970: 1_020)
    )
    let selectionAfterResume = simultaneousState.select(
      from: [qqCandidate, neteaseCandidate],
      observedAt: Date(timeIntervalSince1970: 1_030)
    )
    try expect(
      selectionAfterResume?.applicationIdentifier == qqMusic,
      "a supported player did not regain priority after resuming playback"
    )

    var preferredState = MediaSessionSelectionState(
      preferredApplicationIdentifiers: [qqMusic, neteaseMusic]
    )
    let explicitlyPreferred = preferredState.select(
      from: [qqCandidate, neteaseCandidate],
      observedAt: observedAt
    )
    try expect(
      explicitlyPreferred?.applicationIdentifier == qqMusic,
      "explicit application priority did not override activity recency"
    )

    var globalFallbackState = MediaSessionSelectionState()
    let globalFallback = globalFallbackState.select(
      from: [
        candidate(
          applicationIdentifier: chrome,
          source: .globalFallback,
          playing: true,
          activityDate: Date(timeIntervalSince1970: 990)
        )
      ],
      observedAt: observedAt
    )
    try expect(
      globalFallback?.applicationIdentifier == chrome,
      "the global session was not retained for an unsupported player"
    )
  }

  private static func merged(
    authoritative: MediaInfo,
    enrichment: MediaInfoFetchResult
  ) throws -> MediaInfo {
    let provider = AdaptiveMediaInfoProvider(
      enrichmentProvider: StubMediaInfoProvider(result: enrichment),
      authoritativeProvider: StubMediaInfoProvider(result: .resolved(authoritative))
    )

    guard case .resolved(let result?) = provider.fetchMediaInfo(timeout: 1) else {
      throw HarnessFailure.expectation("adaptive provider did not resolve media")
    }
    return result
  }

  private static func media(
    name: String? = "Track",
    duration: Double?,
    elapsedTime: Double?,
    playing: Bool = true,
    applicationIdentifier: String = "example.player"
  ) -> MediaInfo {
    MediaInfo(
      name: name,
      artist: "Artist",
      album: nil,
      image: nil,
      duration: duration,
      elapsedTime: elapsedTime,
      processID: 0,
      processName: "Player",
      executablePath: "",
      playing: playing,
      applicationIdentifier: applicationIdentifier
    )
  }

  private static func candidate(
    applicationIdentifier: String,
    source: MediaSessionSource,
    playing: Bool,
    name: String? = "Track",
    activityDate: Date?
  ) -> MediaSessionCandidate {
    MediaSessionCandidate(
      info: media(
        name: name,
        duration: playing ? 180 : nil,
        elapsedTime: playing ? 30 : nil,
        playing: playing,
        applicationIdentifier: applicationIdentifier
      ),
      source: source,
      reportedActivityDate: activityDate
    )
  }

  private static func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
  ) throws {
    guard condition() else { throw HarnessFailure.expectation(message) }
  }
}
