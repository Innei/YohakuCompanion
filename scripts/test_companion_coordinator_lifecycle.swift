import Foundation

private enum HarnessFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

@main
private struct CompanionCoordinatorLifecycleHarness {
    static func main() throws {
        var lifecycle = CompanionCoordinatorLifecycle()

        try expect(lifecycle.beginStart(), "initial start was rejected")
        try expect(
            lifecycle.beginStop() == .perform,
            "running coordinator did not acquire the stop"
        )
        try expect(
            !lifecycle.beginStart(),
            "a start was admitted while ordered cleanup was in flight"
        )
        try expect(
            lifecycle.beginStop() == .joinInFlightStop,
            "a second stop attempted to own a duplicate cleanup"
        )

        lifecycle.finishStop()
        try expect(
            lifecycle.beginStart(),
            "completed shutdown remained terminal and prevented restart"
        )
        try expect(
            lifecycle.beginStart(),
            "an in-process refresh could not reuse the single coordinator"
        )

        print("Companion coordinator restart lifecycle behavior passed")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw HarnessFailure.assertion(message) }
    }
}
