import Foundation
import Testing
@testable import SimBridge

@Suite struct ErrorMessageTests {
    @Test func nsErrorsGiveOnlyTheirMessage() {
        let error = NSError(domain: SBErrorDomain, code: 2, userInfo: [NSLocalizedDescriptionKey: "No simulator."])
        #expect(SimBridgeError.message(for: error) == "No simulator.")
    }

    @Test func swiftErrorsGiveTheirDescription() {
        #expect(SimBridgeError.message(for: SimBridgeError("Point is off screen.")) == "Point is off screen.")
        let failure = Simctl.Failure(arguments: ["boot", "X"], status: 149, stderr: "Invalid device: X\n")
        #expect(SimBridgeError.message(for: failure) == "simctl boot X failed (149): Invalid device: X")
    }
}
