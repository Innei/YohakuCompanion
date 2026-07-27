import Foundation

private enum RuntimeHarnessFailure: Error, CustomStringConvertible {
  case unavailable(attempt: Int)

  var description: String {
    switch self {
    case .unavailable(let attempt):
      return "MediaRemote runtime lookup was unavailable on attempt \(attempt)"
    }
  }
}

@main
private enum MediaRemoteRuntimeHarness {
  static func main() throws {
    guard #available(macOS 15.4, *) else {
      print("MediaRemote runtime behavior skipped before macOS 15.4")
      return
    }

    let provider = JXAMediaInfoProvider(
      pollInterval: 1,
      requestTimeout: 5,
      preferredApplicationIdentifiers: []
    )

    for attempt in 1 ... 2 {
      switch provider.fetchMediaInfo(timeout: 5) {
      case .unavailable:
        throw RuntimeHarnessFailure.unavailable(attempt: attempt)
      case .resolved:
        continue
      }
    }

    print("MediaRemote runtime behavior passed")
  }
}
