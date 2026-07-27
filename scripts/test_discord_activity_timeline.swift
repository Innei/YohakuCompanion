import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case unexpectedValue(caseName: String, actual: String)

    var description: String {
        switch self {
        case .unexpectedValue(let caseName, let actual):
            return "\(caseName) produced \(actual)"
        }
    }
}

@main
private struct DiscordActivityTimelineHarness {
    static func main() throws {
        let capturedAt = Date(timeIntervalSince1970: 1_000)

        try expect(
            DiscordActivityTimeline.timestamps(
                capturedAt: capturedAt,
                elapsedSeconds: 25.5,
                durationSeconds: 120
            ),
            start: 974_500,
            end: 1_094_500,
            caseName: "playing media timeline"
        )
        try expect(
            DiscordActivityTimeline.timestamps(
                capturedAt: capturedAt,
                elapsedSeconds: 130,
                durationSeconds: 120
            ),
            start: 870_000,
            end: nil,
            caseName: "elapsed time beyond duration"
        )
        try expect(
            DiscordActivityTimeline.timestamps(
                capturedAt: capturedAt,
                elapsedSeconds: -5,
                durationSeconds: 120
            ),
            start: 1_000_000,
            end: 1_120_000,
            caseName: "negative elapsed time"
        )
        try expect(
            DiscordActivityTimeline.timestamps(
                capturedAt: capturedAt,
                elapsedSeconds: nil,
                durationSeconds: 120
            ),
            start: nil,
            end: nil,
            caseName: "missing elapsed time"
        )
        try expect(
            DiscordActivityTimeline.timestamps(
                capturedAt: capturedAt,
                elapsedSeconds: 2_000,
                durationSeconds: nil
            ),
            start: 0,
            end: nil,
            caseName: "elapsed time before Unix epoch"
        )

        let beforeEpoch = Date(timeIntervalSince1970: -1)
        guard DiscordActivityTimeline.capturedAtMilliseconds(beforeEpoch) == 0 else {
            throw HarnessFailure.unexpectedValue(
                caseName: "pre-epoch capture time",
                actual: String(DiscordActivityTimeline.capturedAtMilliseconds(beforeEpoch))
            )
        }

        print("Discord activity timeline behavior passed")
    }

    private static func expect(
        _ actual: DiscordActivityTimeline.Timestamps?,
        start expectedStart: Int64?,
        end expectedEnd: Int64?,
        caseName: String
    ) throws {
        guard actual?.startMilliseconds == expectedStart,
              actual?.endMilliseconds == expectedEnd
        else {
            throw HarnessFailure.unexpectedValue(
                caseName: caseName,
                actual: String(describing: actual)
            )
        }
    }
}
