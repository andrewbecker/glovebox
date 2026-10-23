import Foundation
import MCP
import SimBridge

enum DiagnosticsTools {
    static var all: [ToolEntry] {
        [getLogs]
    }

    /// An idle simulator logs about 500 KB a second, so the window is short
    /// and the filter is what makes the tool useful.
    static let defaultWindow = 30
    static let maxWindow = 600
    static let defaultBytes = 40_000
    static let maxBytes = 200_000

    static let getLogs = ToolEntry(
        tool: Tool(
            name: "get_logs",
            description: "Read recent unified-log entries from the simulator (log show), newest kept when trimmed. Filter by bundle_id to get an app's own logs and its crash: that matches the app's binary, its subsystem, and messages naming it (a crashed app logs nothing itself; runningboardd names it).",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "bundle_id": Schema.string("Only entries from this app, its subsystem, or naming it (e.g. its crash)."),
                "since": Schema.string("How far back to read: 30s, 5m (default \(defaultWindow)s, at most \(maxWindow / 60) minutes)."),
                "process": Schema.string("Only entries from this process name, e.g. the app's executable name."),
                "predicate": Schema.string("NSPredicate filter, e.g. subsystem == \"com.example.app\" AND messageType == error."),
                "max_bytes": Schema.integer("Return at most this much text, keeping the newest lines (default \(defaultBytes), at most \(maxBytes))."),
                "max_lines": Schema.integer("Return at most this many of the newest lines."),
            ])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let seconds = try window(args.string("since"))
            var predicates: [String] = []
            if let bundleID = args.string("bundle_id") {
                predicates.append(try await appPredicate(bundleID, udid: udid))
            }
            if let process = args.string("process") {
                predicates.append("process == \(quoted(process))")
            }
            if let predicate = args.string("predicate") { predicates.append("(\(predicate))") }
            // log show takes --last 30q as 30 seconds without complaint, so
            // glovebox always writes seconds itself.
            var command = ["spawn", udid, "log", "show", "--style", "compact", "--last", "\(seconds)s"]
            if !predicates.isEmpty { command += ["--predicate", predicates.joined(separator: " AND ")] }
            let output: Data
            do {
                output = try await Simctl.run(command)
            } catch let failure as Simctl.Failure where failure.status == 64 {
                throw ToolError("log show rejected the predicate: \(stderrText(failure.stderr))")
            }
            // An empty result is just the column header (44 bytes).
            let lines = String(decoding: output, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            guard !lines.isEmpty else { return [.plain("No log entries in the last \(seconds) s\(predicates.isEmpty ? "" : " matching the filter").")] }
            let byteLimit = min(max(1000, args.int("max_bytes") ?? defaultBytes), maxBytes)
            let lineLimit = max(1, args.int("max_lines") ?? Int.max)
            let kept = newest(lines.map(String.init), maxBytes: byteLimit, maxLines: lineLimit)
            let note = lines.count > kept.count ? "Showing the newest \(kept.count) of \(lines.count) lines.\n" : ""
            return [.plain(note + kept.joined(separator: "\n"))]
        }
    )

    /// `since` in whole seconds, refusing what log show would misread.
    static func window(_ since: String?) throws -> Int {
        guard let since else { return defaultWindow }
        guard let match = since.wholeMatch(of: #/(\d+)([smh]?)/#), let value = Int(match.1) else {
            throw ToolError("since must look like 30s or 5m (at most \(maxWindow / 60) minutes).")
        }
        let seconds = switch match.2 {
        case "m": value * 60
        case "h": value * 3600
        default: value
        }
        guard (1...maxWindow).contains(seconds) else {
            throw ToolError("since must be from 1s to \(maxWindow / 60)m; an idle simulator logs about 500 KB a second. Narrow it with bundle_id or a predicate instead.")
        }
        return seconds
    }

    /// The three clauses that together catch an app's logs and its crash:
    /// its binary (by container path), its subsystem, and messages naming it.
    static func appPredicate(_ bundleID: String, udid: String) async throws -> String {
        var clauses: [String] = []
        if let container = try? await Simctl.run(["get_app_container", udid, bundleID, "app"]) {
            let path = String(decoding: container, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { clauses.append("processImagePath BEGINSWITH \(quoted(path))") }
        }
        clauses.append("subsystem BEGINSWITH \(quoted(bundleID))")
        clauses.append("eventMessage CONTAINS \(quoted(bundleID))")
        return "(" + clauses.joined(separator: " OR ") + ")"
    }

    /// The last lines that fit in `maxBytes` and `maxLines`, oldest first.
    static func newest(_ lines: [String], maxBytes: Int, maxLines: Int) -> [String] {
        var kept: [String] = []
        var bytes = 0
        for line in lines.reversed() {
            let size = line.utf8.count + 1
            guard kept.count < maxLines, bytes + size <= maxBytes else { break }
            kept.append(line)
            bytes += size
        }
        return kept.reversed()
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// simctl spawn writes a getpwuid_r warning to stderr on every call.
    static func stderrText(_ stderr: String) -> String {
        stderr.split(separator: "\n").filter { !$0.contains("getpwuid_r") }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
