import Foundation
import MCP
import Testing
@testable import GloveboxServer

/// tools/list is what every agent reads first, so any change to a name,
/// description or schema should be a deliberate one. Re-record with
/// GLOVEBOX_RECORD_GOLDEN=1 swift test --filter GoldenTests, and review the diff.
/// The golden is the full list, debug tools included.
@Suite struct GoldenTests {
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Golden/tools-list.json")

    static func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ToolCatalog.entries(debug: true).map(\.tool)) + Data("\n".utf8)
    }

    @Test func toolsListMatchesTheGolden() throws {
        let current = try Self.encoded()
        if ProcessInfo.processInfo.environment["GLOVEBOX_RECORD_GOLDEN"] == "1" {
            try current.write(to: Self.golden)
            return
        }
        let recorded = try Data(contentsOf: Self.golden)
        #expect(current == recorded, "tools/list changed; if on purpose, re-record with GLOVEBOX_RECORD_GOLDEN=1")
    }

    @Test func noDescriptionNamesThisMachine() throws {
        let text = String(decoding: try Self.encoded(), as: UTF8.self)
        #expect(!text.contains(NSTemporaryDirectory()))
        #expect(!text.contains(NSHomeDirectory()))
    }

    @Test func everyScreenChangingToolCarriesTheWaitContract() {
        let changing = ["tap", "long_press", "swipe", "scroll_to", "press_button", "shake", "fold", "type_text",
                        "press_key", "key_chord", "hold_key", "clear_text", "open_url", "launch_app", "wait_for", "batch"]
        for entry in ToolCatalog.entries where changing.contains(entry.tool.name) {
            #expect(entry.tool.description?.contains("do NOT sleep or poll") == true, "\(entry.tool.name)")
        }
        for name in ["tap", "long_press", "swipe", "describe_ui", "describe_point", "screenshot", "find_elements"] {
            let entry = ToolCatalog.entries.first { $0.tool.name == name }
            #expect(entry?.tool.description?.contains("POINTS everywhere") == true, "\(name)")
        }
    }
}
