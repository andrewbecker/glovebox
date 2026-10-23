import CoreGraphics
import MCP
import SimBridge

/// A tool definition paired with its handler. Tool groups return arrays of these.
struct ToolEntry: Sendable {
    typealias Handler = @Sendable (Arguments) async throws -> [Tool.Content]
    let tool: Tool
    let handler: Handler
}

/// Every tool the server exposes, in listing order.
enum ToolCatalog {
    /// The debug tools drive lldb, which can run shell commands on the Mac, so
    /// they exist only when the person running the server turns them on.
    static let debugEnabled = ProcessInfo.processInfo.environment["GLOVEBOX_ENABLE_DEBUG"] == "1"

    static let entries: [ToolEntry] = entries(debug: debugEnabled)

    static func entries(debug: Bool) -> [ToolEntry] {
        DeviceTools.all + AppTools.all + ObserveTools.all + InteractTools.all + KeyboardTools.all
            + DiagnosticsTools.all + (debug ? DebugTools.all : []) + [BatchTool.batch]
    }

    static let handlers: [String: ToolEntry.Handler] = Dictionary(uniqueKeysWithValues: entries.map { ($0.tool.name, $0.handler) })

    /// Why `name` is not a tool, saying how to turn on a debug tool that is off.
    static func unknown(_ name: String, debug: Bool = debugEnabled) -> String {
        guard !debug, DebugTools.all.contains(where: { $0.tool.name == name }) else { return "Unknown tool '\(name)'." }
        return "\(name) is off: the debug tools drive lldb, which can run shell commands on this Mac. The person running glovebox can turn them on by setting GLOVEBOX_ENABLE_DEBUG=1 in the server's environment."
    }
}

/// Typed accessors over the raw MCP argument dictionary.
struct Arguments: Sendable {
    let values: [String: Value]

    init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    func string(_ key: String) -> String? { values[key]?.stringValue }
    func bool(_ key: String) -> Bool? { values[key]?.boolValue }

    func double(_ key: String) -> Double? {
        switch values[key] {
        case .double(let d): d
        case .int(let i): Double(i)
        default: nil
        }
    }

    /// Clamped to ±1e9: converting a larger double to Int would crash the server.
    func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let i): min(max(i, -1_000_000_000), 1_000_000_000)
        case .double(let d) where d.isFinite: Int(min(max(d, -1e9), 1e9))
        default: nil
        }
    }

    func require(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolError("Missing required argument '\(key)'.") }
        return value
    }

    /// Clamped to 0...1 hour, so an absurd value cannot overflow Duration.
    func milliseconds(_ key: String) -> Duration? {
        double(key).map { .milliseconds(min(max(0, $0), 3_600_000)) }
    }

    func point(x: String = "x", y: String = "y") -> CGPoint? {
        guard let px = double(x), let py = double(y) else { return nil }
        return CGPoint(x: px, y: py)
    }

    /// Element selector fields shared by tap, type_text, wait_for and friends.
    var query: ElementQuery {
        ElementQuery(
            label: string("label"), labelContains: string("label_contains"), identifier: string("identifier"),
            role: string("role"), value: string("value"), valueContains: string("value_contains"),
            text: string("text_match"), index: int("index")
        )
    }

    func settleOptions() throws -> SettleOptions {
        var options = SettleOptions()
        if let mode = string("settle") {
            guard let parsed = SettleOptions.Mode(rawValue: mode) else {
                throw ToolError("settle must be one of screen, ui, none.")
            }
            options.mode = parsed
        }
        if let response = milliseconds("settle_response_ms") { options.response = response }
        if let quiet = milliseconds("settle_quiet_ms") { options.quiet = quiet }
        if let timeout = milliseconds("settle_timeout_ms") { options.timeout = timeout }
        return options
    }

    /// The session for this call's device (see `DeviceResolver`).
    func session() async throws -> DeviceSession {
        try await DeviceSession.open(DeviceResolver.shared.resolve(self))
    }

    /// Runs an interaction on this call's device while holding its input
    /// lock, so finding the target, sending the input and settling happen
    /// with no other call's input in between.
    func interaction(_ body: @Sendable @escaping (DeviceSession) async throws -> [Tool.Content]) async throws -> [Tool.Content] {
        let session = try await session()
        try await session.refuseIfPaused()
        return try await session.withInputLock { try await body(session) }
    }

    /// Copy with `udid` filled in from an enclosing batch, and no screenshot
    /// per step unless the step asks: the batch attaches one at the end.
    func inheriting(udid: String) -> Arguments {
        var values = values
        if values["udid"] == nil { values["udid"] = .string(udid) }
        if values["screenshot"] == nil { values["screenshot"] = .bool(false) }
        values[Self.stableKey] = .bool(true)
        return Arguments(values)
    }

    /// Said instead of attaching a screenshot identical to the last one sent.
    static let sameScreen = "Screen identical to the last screenshot sent; none attached."

    /// Set on batch steps: an element must hold still across two reads
    /// before it is tapped, since a batch has no agent looking in between.
    var requiresStableTarget: Bool { bool(Self.stableKey) ?? false }
    static let stableKey = "_stable_target"

    /// Whether to attach a screenshot of the settled screen (default true).
    var wantsScreenshot: Bool { bool("screenshot") ?? true }

    /// An interaction's result: `text`, then a screenshot of the settled
    /// screen unless the call opted out. If the screenshot fails, the action
    /// still happened, and the text says so, so the agent does not repeat it.
    func result(_ text: String, session: DeviceSession) async -> [Tool.Content] {
        var text = text + DriverNote.record(udid: session.udid)
        if let paused = await Debugger.shared.pausedNote(udid: session.udid) {
            text += " The app then stopped: " + paused.replacingOccurrences(of: "Call debug_continue first.", with: "Call debug_wait to see where.")
        }
        guard wantsScreenshot else { return [.plain(text)] }
        do {
            let shot = try await session.screenshot(scale: double("screenshot_scale") ?? 1)
            if await session.recordSent(shot) { return [.plain(text + " " + Self.sameScreen)] }
            return [.plain(text), .image(shot)]
        } catch {
            return [.plain(text + " That happened, but the screenshot after it failed (\(SimBridgeError.message(for: error))). Do not repeat the action; call screenshot to see the screen.")]
        }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A failure that still carries partial results (e.g. a batch that stopped midway).
struct ToolFailure: Error {
    let content: [Tool.Content]
}

/// The sentence every tool that takes or returns coordinates carries, so an
/// agent never has to guess the space. The one thing in capitals.
let coordinateContract = "Coordinates are POINTS everywhere (a scale 1 screenshot has one pixel per point), never device pixels."

/// The sentence every tool that changes the screen carries. Without it,
/// agents invented their own waits.
let waitContract = "Returns once the screen settles, with a screenshot: do NOT sleep or poll before the next step."

/// JSON Schema helpers to keep tool declarations short.
enum Schema {
    static func object(_ properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String) -> Value {
        ["type": "string", "description": .string(description)]
    }

    static func number(_ description: String) -> Value {
        ["type": "number", "description": .string(description)]
    }

    static func integer(_ description: String) -> Value {
        ["type": "integer", "description": .string(description)]
    }

    static func boolean(_ description: String) -> Value {
        ["type": "boolean", "description": .string(description)]
    }

    /// No description: the server instructions say when it can be left
    /// out, and 33 tools repeating it cost about 700 tokens.
    static let udid: Value = ["type": "string"]

    /// Element selector. String matches are case-insensitive; all given fields must match.
    static let query: [String: Value] = [
        "label": string("Exact label."),
        "label_contains": string("Label substring."),
        "identifier": string("Exact identifier."),
        "role": string("As describe_ui shows it, e.g. Button, StaticText, TextField, CheckBox (a switch)."),
        "value": string("Exact value."),
        "value_contains": string("Value substring."),
        "text_match": string("Substring of label, value, placeholder or identifier."),
    ]

    /// Picks one of several query matches, for tools that act on a single element.
    static let index: [String: Value] = [
        "index": integer("Which of several matches, numbered as find_elements does."),
    ]

    /// Settle and result controls listed by every interaction.
    static let settle: [String: Value] = [
        "screenshot": boolean("Attach a screenshot of the result (default true; false in batch steps)."),
        "settle": ["type": "string", "enum": ["screen", "ui", "none"],
                   "description": "screen (default): wait for the screen to stop changing; ui: also for a stable accessibility tree; none: don't wait."],
    ]

    /// Accepted by every tool that lists `settle`, but not listed: agents
    /// had no use for them, and listing them on 13 tools cost about 1,200
    /// tokens. The command line and scenarios still take them.
    static let unlistedSettle: [String: Value] = [
        "screenshot_scale": number("Image pixels per point for the result's screenshot (default 1)."),
        "settle_response_ms": number("Longest wait for the first visible change before reporting none (default 1000)."),
        "settle_quiet_ms": number("How long the screen must stay still to count as settled (default 250)."),
        "settle_timeout_ms": number("Overall cap on waiting (default 10000)."),
    ]

    static func merge(_ parts: [String: Value]...) -> [String: Value] {
        parts.reduce(into: [:]) { result, part in result.merge(part) { $1 } }
    }
}

extension Tool.Content {
    static func plain(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    static func image(_ screenshot: Screenshot) -> Tool.Content {
        .image(data: screenshot.data.base64EncodedString(), mimeType: screenshot.format.mimeType, annotations: nil, _meta: nil)
    }
}

extension SettleResult {
    /// Appended to interaction results so the agent knows the screen state.
    var note: String {
        if elapsed == .zero { return "" }
        if !observed {
            return " glovebox saw no screen updates, so it cannot tell whether the input landed. Look before repeating it."
        }
        if !changed {
            return " No visible change within \(milliseconds) ms (idle): the input missed or did nothing visible, or the app is busy. Look before repeating it: a repeat acts on what is on screen now."
        }
        return settled
            ? " Screen settled after \(milliseconds) ms."
            : " Screen still changing after \(milliseconds) ms (moving, settled: false): animating or loading. Look again before relying on it."
    }
}

extension CGPoint {
    /// Formats instead of converting to Int, which would crash on huge values.
    var text: String { String(format: "(%.0f, %.0f)", x, y) }
}
