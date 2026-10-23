import Foundation
import MCP
import Testing
@testable import GloveboxServer
@testable import SimBridge

/// Drives a real simulator through the tool layer. Opt in with the UDID of a
/// booted simulator you do not mind being driven:
///
///     GLOVEBOX_LIVE_UDID=<udid> swift test --filter LiveTests
///
/// It goes home, opens Settings, and checks taps, reads and screenshots.
private let liveUDID = ProcessInfo.processInfo.environment["GLOVEBOX_LIVE_UDID"]

@Suite(.enabled(if: liveUDID != nil, "set GLOVEBOX_LIVE_UDID to run"), .serialized)
struct LiveTests {
    func call(_ name: String, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        arguments["udid"] = .string(liveUDID!)
        return try await GloveboxServer.call(name, arguments: arguments)
    }

    func text(_ result: CallTool.Result) -> String {
        result.content.compactMap {
            if case .text(let text, _, _) = $0 { return text }
            return nil
        }.joined(separator: "\n")
    }

    @Test func settingsCanBeOpenedReadAndTapped() async throws {
        _ = try await call("press_button", ["button": "home", "screenshot": false])
        let launch = try await call("launch_app", ["bundle_id": "com.apple.Preferences", "screenshot": false])
        #expect(launch.isError != true, "\(text(launch))")
        let ui = try await call("describe_ui")
        #expect(text(ui).contains("General"))
        let tap = try await call("tap", ["label": "General"])
        #expect(tap.isError != true, "\(text(tap))")
        #expect(tap.content.contains { if case .image = $0 { return true } else { return false } }, "an inline screenshot")
        let about = try await call("wait_for", ["label": "About", "screenshot": false])
        #expect(about.isError != true, "\(text(about))")
    }

    @Test func anAmbiguousQueryIsRefusedNotGuessed() async throws {
        let result = try await call("tap", ["role": "Button", "screenshot": false])
        #expect(result.isError == true)
        #expect(text(result).contains("so none was picked"))
    }
}
