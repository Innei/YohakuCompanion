import Foundation

private enum RuntimeHarnessError: LocalizedError {
    case missingApplicationID

    var errorDescription: String? {
        "Usage: test_discord_ipc_runtime <Discord Application ID>"
    }
}

@main
private struct DiscordIPCRuntimeHarness {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw RuntimeHarnessError.missingApplicationID
        }

        let client = DiscordIPCClient()
        do {
            let firstInitialization = Task { @MainActor in
                try await client.initialize(applicationId: CommandLine.arguments[1])
            }
            let joinedInitialization = Task { @MainActor in
                try await client.initialize(applicationId: CommandLine.arguments[1])
            }
            try await firstInitialization.value
            try await joinedInitialization.value
            try await client.setActivity(
                name: "Yohaku Companion",
                details: "Native Swift IPC verification",
                state: "Temporary Rich Presence",
                activityType: .playing,
                statusDisplayType: .details,
                startTimestamp: Int64(
                    (Date.now.timeIntervalSince1970 * 1_000).rounded(.down)
                ),
                endTimestamp: nil,
                largeImageKey: nil,
                largeImageText: nil,
                smallImageKey: nil,
                smallImageText: nil,
                buttons: nil
            )
            try await Task.sleep(for: .seconds(2))
            try await client.clearActivity()
            client.shutdown()
            print("Discord native IPC runtime behavior passed")
        } catch {
            client.shutdown()
            throw error
        }
    }
}
