import Foundation

private actor TestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@main
private struct SettingsMutationCoordinatorHarness {
    @MainActor
    static func main() async throws {
        let coordinator = SettingsMutationCoordinator.shared
        let serialGate = TestGate()
        var events: [String] = []

        guard let first = coordinator.enqueue({
            events.append("first-start")
            await serialGate.wait()
            events.append("first-end")
        }) else {
            fatalError("The initial operation should be admitted")
        }

        let second = Task { @MainActor in
            try await coordinator.perform {
                events.append("second")
            }
        }

        await Task.yield()
        precondition(events == ["first-start"])
        await serialGate.open()
        await first.value
        try await second.value
        precondition(events == ["first-start", "first-end", "second"])

        let exclusiveGate = TestGate()
        let exclusive = Task { @MainActor in
            try await coordinator.performExclusive {
                events.append("exclusive-start")
                await exclusiveGate.wait()
                events.append("exclusive-end")
            }
        }

        while events.last != "exclusive-start" {
            await Task.yield()
        }

        do {
            try await coordinator.perform {
                events.append("must-not-run")
            }
            fatalError("Exclusive maintenance must reject new operations")
        } catch SettingsMutationCoordinatorError.notAcceptingOperations {
            // Expected observable boundary.
        }

        await exclusiveGate.open()
        try await exclusive.value
        precondition(!events.contains("must-not-run"))

        coordinator.closeAdmissionPermanently()
        precondition(coordinator.enqueue {} == nil)
        do {
            try await coordinator.perform {}
            fatalError("Termination must permanently reject new operations")
        } catch SettingsMutationCoordinatorError.notAcceptingOperations {
            // Expected observable boundary.
        }

        await coordinator.drain()
        print("Settings mutation coordinator behavior passed")
    }
}
