import Foundation
import MCP
import SimBridge

/// The command line: every tool, plus selftest and report, run in-process
/// through the same handlers the MCP server uses.
///
///     glovebox-mcp                      serve MCP on stdin/stdout
///     glovebox-mcp serve --stdio        the same
///     glovebox-mcp tap --label General  call a tool
///     glovebox-mcp launch_app com.example.app --json
///
/// Exit codes: 0 success, 1 the tool failed, 2 the command line was wrong.
public enum CLI {
    public enum Exit: Int32 {
        case success = 0
        case toolFailed = 1
        case usage = 2
    }

    /// Whether `arguments` (without the program name) ask for the MCP server.
    public static func wantsServer(_ arguments: [String]) -> Bool {
        arguments.isEmpty || arguments.first == "serve"
    }

    public static func run(_ arguments: [String]) async -> Exit {
        guard let command = arguments.first else { return .usage }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            print(usage)
            return .success
        case "--version", "version":
            print(GloveboxServer.version)
            return .success
        case "list":
            for entry in ToolCatalog.entries {
                let first = entry.tool.description?.split(separator: ".").first.map(String.init) ?? ""
                print("\(entry.tool.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(first).")
            }
            return .success
        case "selftest":
            return await SelfTest.run(rest)
        case "report":
            return await Report.run(rest)
        default:
            return await callTool(command, rest)
        }
    }

    static let usage = """
        glovebox \(GloveboxServer.version): drive iOS Simulators.

        Usage:
          glovebox-mcp [serve [--stdio]]        Serve MCP on stdin and stdout (the default).
          glovebox-mcp <tool> [value] [--name value ...] [--json]
                                             Call one tool, e.g. glovebox-mcp tap --label General.
                                             A bare value fills the tool's main argument.
          glovebox-mcp list                     List the tools.
          glovebox-mcp selftest [--udid UDID]   Tap a page in Safari through the MCP path and check it.
          glovebox-mcp report [--json]          Versions and environment, for bug reports.

        Exit codes: 0 success, 1 the tool failed, 2 bad command line.
        """

    static func callTool(_ name: String, _ arguments: [String]) async -> Exit {
        guard let entry = ToolCatalog.entries.first(where: { $0.tool.name == name }) else {
            printError(DebugTools.all.contains { $0.tool.name == name } ? ToolCatalog.unknown(name)
                       : "Unknown command '\(name)'. Run glovebox-mcp list for the tools.")
            return .usage
        }
        var json = false
        let values: [String: Value]
        do {
            (values, json) = try parse(arguments, for: entry.tool)
        } catch {
            printError(SimBridgeError.message(for: error))
            return .usage
        }
        let result: CallTool.Result
        do {
            result = try await GloveboxServer.call(name, arguments: values)
        } catch {
            printError(SimBridgeError.message(for: error))
            return .toolFailed
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(result) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            for content in result.content { printContent(content, error: result.isError == true) }
        }
        return result.isError == true ? .toolFailed : .success
    }

    /// Turns flags into tool arguments, typed by the tool's input schema.
    static func parse(_ arguments: [String], for tool: Tool) throws -> ([String: Value], json: Bool) {
        var properties = tool.inputSchema.objectValue?["properties"]?.objectValue ?? [:]
        let listed = properties.keys.sorted()
        if properties["screenshot"] != nil { properties.merge(Schema.unlistedSettle) { a, _ in a } }
        var values: [String: Value] = [:]
        var json = false
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--json" {
                json = true
                continue
            }
            guard argument.hasPrefix("--") else {
                guard let key = primaryArgument(of: tool) else {
                    throw ToolError("\(tool.name) takes no bare value; got '\(argument)'. Use --name value.")
                }
                guard values[key] == nil else { throw ToolError("\(key) was given twice.") }
                values[key] = try value(argument, type: properties[key]?.objectValue?["type"]?.stringValue, key: key)
                continue
            }
            var key = String(argument.dropFirst(2))
            var text: String?
            if let equals = key.firstIndex(of: "=") {
                text = String(key[key.index(after: equals)...])
                key = String(key[..<equals])
            }
            key = key.replacingOccurrences(of: "-", with: "_")
            guard let schema = properties[key]?.objectValue else {
                throw ToolError("\(tool.name) has no argument --\(key). Its arguments: \(listed.joined(separator: ", ")).")
            }
            let type = schema["type"]?.stringValue
            if text == nil {
                if type == "boolean", index >= arguments.count || arguments[index].hasPrefix("--") {
                    text = "true"
                } else if index < arguments.count {
                    text = arguments[index]
                    index += 1
                } else {
                    throw ToolError("--\(key) needs a value.")
                }
            }
            values[key] = try value(text!, type: type, key: key)
        }
        return (values, json)
    }

    /// The argument a bare value fills: the first required one, or label.
    static func primaryArgument(of tool: Tool) -> String? {
        let schema = tool.inputSchema.objectValue
        if let required = schema?["required"]?.arrayValue?.compactMap(\.stringValue), let first = required.first {
            return first
        }
        let properties = schema?["properties"]?.objectValue ?? [:]
        return properties["label"] != nil ? "label" : nil
    }

    static func value(_ text: String, type: String?, key: String) throws -> Value {
        switch type {
        case "integer":
            guard let number = Int(text) else { throw ToolError("--\(key) must be a whole number, not '\(text)'.") }
            return .int(number)
        case "number":
            guard let number = Double(text) else { throw ToolError("--\(key) must be a number, not '\(text)'.") }
            return number == number.rounded() && abs(number) < 1e15 ? .int(Int(number)) : .double(number)
        case "boolean":
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: throw ToolError("--\(key) must be true or false, not '\(text)'.")
            }
        case "array", "object":
            guard let value = try? JSONDecoder().decode(Value.self, from: Data(text.utf8)) else {
                if type == "array" { return .array(text.split(separator: ",").map { .string(String($0)) }) }
                throw ToolError("--\(key) must be JSON.")
            }
            return value
        default:
            return .string(text)
        }
    }

    private static func printContent(_ content: Tool.Content, error: Bool) {
        switch content {
        case .text(let text, _, _):
            if error { printError(text) } else { print(text) }
        case .image(let data, let mimeType, _, _):
            let ext = mimeType == "image/png" ? "png" : "jpg"
            let path = NSTemporaryDirectory() + "glovebox-\(UUID().uuidString.prefix(8)).\(ext)"
            if let bytes = Data(base64Encoded: data), FileManager.default.createFile(atPath: path, contents: bytes) {
                print("[image saved to \(path)]")
            }
        default:
            break
        }
    }

    static func printError(_ text: String) {
        try? FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
    }
}
