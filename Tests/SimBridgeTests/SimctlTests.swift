import Testing
@testable import SimBridge

/// These run the real `xcrun simctl`, which takes far longer than the limits
/// below just to start.
@Suite struct SimctlTests {
    @Test func simctlIsStoppedAtItsTimeout() async {
        let start = ContinuousClock.now
        await #expect(throws: Simctl.Timeout.self) {
            try await Simctl.run(["list", "devices", "-j"], timeout: .milliseconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingTheTaskStopsSimctl() async {
        let task = Task { try await Simctl.run(["list", "devices", "-j"]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellingTheTaskStopsARunningSimctl() async throws {
        let task = Task { try await Simctl.run(["list", "devices", "-j"]) }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aFailureCarriesStderr() async {
        await #expect {
            try await Simctl.run(["boot", "not-a-device"])
        } throws: { error in
            (error as? Simctl.Failure)?.stderr.isEmpty == false
        }
    }
}
