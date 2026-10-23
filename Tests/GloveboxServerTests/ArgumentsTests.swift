import MCP
import Testing
@testable import GloveboxServer
@testable import SimBridge

@Suite struct ArgumentsTests {
    @Test func numbersAreClampedSoTheyCannotCrashTheServer() {
        let args = Arguments(["big": .double(1e300), "nan": .double(.nan), "negative": .int(-5), "ms": .double(1e12)])
        #expect(args.int("big") == 1_000_000_000)
        #expect(args.int("nan") == nil)
        #expect(args.int("negative") == -5)
        #expect(args.milliseconds("ms") == .seconds(3600))
        #expect(args.milliseconds("negative") == .zero)
    }

    @Test func settleOptionsAreParsedAndChecked() throws {
        let options = try Arguments(["settle": "ui", "settle_quiet_ms": .int(400)]).settleOptions()
        #expect(options.mode == .ui)
        #expect(options.quiet == .milliseconds(400))
        #expect(options.response == .seconds(1))
        #expect(throws: ToolError.self) { try Arguments(["settle": "soon"]).settleOptions() }
    }

    @Test func queryFieldsMapToTheElementQuery() {
        let query = Arguments(["label_contains": "Sign", "text_match": "in", "index": .int(1)]).query
        #expect(query == ElementQuery(labelContains: "Sign", text: "in", index: 1))
        #expect(Arguments(nil).query.isEmpty)
    }
}

@Suite struct BatchParsingTests {
    @Test func aStepNamesOneToolAndInheritsTheBatchUDID() throws {
        let (name, args) = try BatchTool.parse(["tap": ["label": "General"]], udid: "A")
        #expect(name == "tap")
        #expect(args.string("label") == "General")
        #expect(args.string("udid") == "A")
    }

    @Test func aStepCanChooseItsOwnUDID() throws {
        let (_, args) = try BatchTool.parse(["screenshot": ["udid": "B"]], udid: "A")
        #expect(args.string("udid") == "B")
    }

    @Test func sleepIsAStep() throws {
        #expect(try BatchTool.parse(["sleep": ["ms": .int(10)]], udid: "A").name == "sleep")
    }

    @Test func malformedStepsAreRejected() {
        #expect(throws: ToolError.self) { try BatchTool.parse(["tap": [:], "swipe": [:]], udid: "A") }
        #expect(throws: ToolError.self) { try BatchTool.parse("tap", udid: "A") }
        #expect(throws: ToolError.self) { try BatchTool.parse(["batch": [:]], udid: "A") }
        #expect(throws: ToolError.self) { try BatchTool.parse(["teleport": [:]], udid: "A") }
    }
}

@Suite struct ResultTextTests {
    @Test func settleNotesSayWhatHappened() {
        #expect(SettleResult.skipped.note == "")
        #expect(SettleResult(settled: true, changed: true, elapsed: .milliseconds(420)).note == " Screen settled after 420 ms.")
        #expect(SettleResult(settled: true, changed: false, elapsed: .seconds(1)).note.hasPrefix(" No visible change within 1000 ms"))
        #expect(SettleResult(settled: false, changed: true, elapsed: .seconds(10)).note.contains("settled: false"))
        #expect(SettleResult(settled: true, changed: false, elapsed: .seconds(1), observed: false).note.contains("no screen updates"))
    }

    @Test func failuresBecomeErrorResultsWithTheirMessage() async throws {
        let unknown = try await GloveboxServer.call("teleport", arguments: nil)
        #expect(unknown.isError == true)
        #expect(unknown.content == [.plain("Unknown tool 'teleport'.")])

        // boot checks its arguments before touching any simulator.
        let missing = try await GloveboxServer.call("boot", arguments: [:])
        #expect(missing.isError == true)
        #expect(missing.content == [.plain("Missing required argument 'udid'.")])
    }

    @Test func everyToolHasAUniqueName() {
        let names = ToolCatalog.entries.map(\.tool.name)
        #expect(Set(names).count == names.count)
    }
}
