import Foundation

enum DiscordActivityTimeline {
    struct Timestamps: Equatable {
        let startMilliseconds: Int64
        let endMilliseconds: Int64?
    }

    static func timestamps(
        capturedAt: Date,
        elapsedSeconds rawElapsed: Double?,
        durationSeconds rawDuration: Double?
    ) -> Timestamps? {
        guard let rawElapsed, rawElapsed.isFinite else { return nil }

        let nowMilliseconds = boundedMilliseconds(capturedAt.timeIntervalSince1970)
        let elapsedSeconds = max(0, rawElapsed)
        let elapsedMilliseconds = boundedMilliseconds(elapsedSeconds)
        let startMilliseconds = subtractingClampedToZero(
            nowMilliseconds,
            elapsedMilliseconds
        )

        guard let rawDuration, rawDuration.isFinite, rawDuration > elapsedSeconds else {
            return Timestamps(
                startMilliseconds: startMilliseconds,
                endMilliseconds: nil
            )
        }

        let remainingMilliseconds = boundedMilliseconds(rawDuration - elapsedSeconds)
        return Timestamps(
            startMilliseconds: startMilliseconds,
            endMilliseconds: addingWithoutOverflow(
                nowMilliseconds,
                remainingMilliseconds
            )
        )
    }

    static func capturedAtMilliseconds(_ capturedAt: Date) -> Int64 {
        boundedMilliseconds(capturedAt.timeIntervalSince1970)
    }

    private static func boundedMilliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let milliseconds = seconds * 1_000
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds.rounded(.down))
    }

    private static func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : value
    }

    private static func subtractingClampedToZero(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs >= rhs else { return 0 }
        return lhs - rhs
    }
}
