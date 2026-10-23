import Foundation
import MCP
import SimBridge

/// Runs a list of tool calls in one round trip on the warm device session.
/// Each step uses the same handler as the standalone tool, so it behaves
/// identically, including waiting for the screen to settle.
enum BatchTool {
    static let batch = ToolEntry(
        tool: Tool(
            name: "batch",
            description: """
            Run several steps in one call, in order. Each step is an object with one key, the tool name, whose value is that tool's arguments, e.g. \
            [{"tap":{"label":"Email"}}, {"type_text":{"text":"me@example.com"}}, {"tap":{"identifier":"loginButton"}}, \
            {"wait_for":{"label":"Welcome"}}]. Any tool except batch can be a step (scroll_to and wait_for are the usual ways to reach and wait for \
            things), plus {"capture":{"path":"/tmp/step.jpg"}} to save a screenshot under a temp folder, and {"sleep":{"ms":N}} as an escape hatch. \
            Up to \(maxSteps) steps. Each named element is looked up again right before its step and must hold still before it is tapped; an x/y tap \
            is allowed only as the first step, where the coordinates are fresh. The first failing step stops the batch. The result lists each step \
            and ends with a screenshot of the final screen. udid applies to every step. \(waitContract)
            """,
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "steps": ["type": "array", "items": ["type": "object"], "description": "Steps to run, e.g. [{\"tap\":{\"x\":100,\"y\":200}}]."],
                "stop_on_error": Schema.boolean("Stop at the first failing step (default true)."),
                "screenshot": Schema.boolean("Attach a screenshot of the final screen (default true)."),
            ], required: ["steps"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            guard let steps = args.values["steps"]?.arrayValue, !steps.isEmpty else {
                throw ToolError("steps must be a non-empty array.")
            }
            guard steps.count <= maxSteps else {
                throw ToolError("A batch takes at most \(maxSteps) steps; this one has \(steps.count). Split it, and look at the screen in between.")
            }
            try validate(steps, udid: udid)
            let stopOnError = args.bool("stop_on_error") ?? true
            let start = ContinuousClock.now
            // Held across all steps, so another call's input cannot land
            // between them.
            let session = try await DeviceSession.open(udid)
            let report = try await session.withInputLock {
                try await run(steps, udid: udid, stopOnError: stopOnError)
            }
            var summary = "Ran \(report.ran) of \(steps.count) step(s) in \(milliseconds(since: start)) ms"
                + (report.failed > 0 ? ", \(report.failed) failed." : ".")
            if report.failed > 0, let first = report.firstFailure {
                summary += " Steps before step \(first) already ran: do not resend them; continue from the screen below."
            }
            var content: [Tool.Content] = [.plain(([summary] + report.lines).joined(separator: "\n"))] + report.images
            // A failure always shows where things stand.
            if args.bool("screenshot") ?? true || report.failed > 0 {
                let session = try await DeviceSession.open(udid)
                if let shot = try? await session.screenshot() {
                    content.append(await session.recordSent(shot) ? .plain(Arguments.sameScreen) : .image(shot))
                }
            }
            if report.failed > 0 { throw ToolFailure(content: content) }
            return content
        }
    )

    static let maxSteps = 20

    struct Report: Sendable {
        var lines: [String] = []
        var images: [Tool.Content] = []
        var ran = 0
        var failed = 0
        /// The 1-based number of the first step that failed.
        var firstFailure: Int?
    }

    /// Refuses a batch that could not run as a whole, before any step acts:
    /// a malformed step, or an x/y tap after the first step, whose
    /// coordinates were read off a screen the earlier steps have changed.
    static func validate(_ steps: [Value], udid: String) throws {
        for (index, step) in steps.enumerated() {
            let name: String
            let args: Arguments
            do {
                (name, args) = try parse(step, udid: udid)
            } catch {
                throw ToolError("Step \(index + 1): \(SimBridgeError.message(for: error)) Nothing ran.")
            }
            if index > 0, ["tap", "long_press"].contains(name), args.point() != nil {
                throw ToolError("Step \(index + 1): an x/y \(name) is allowed only as a batch's first step, where the coordinates are fresh. Use a label or identifier, or end the batch and look at the screen first. Nothing ran.")
            }
        }
    }

    /// Runs `steps` in order. A cancelled batch stops at once, even when it
    /// would carry on past failures.
    private static func run(_ steps: [Value], udid: String, stopOnError: Bool) async throws -> Report {
        var report = Report()
        for (index, step) in steps.enumerated() {
            try Task.checkCancellation()
            let stepStart = ContinuousClock.now
            report.ran += 1
            do {
                let (name, args) = try parse(step, udid: udid)
                let content = try await run(name, args)
                let text = content.compactMap { item -> String? in
                    if case .text(let text, _, _) = item { return text }
                    return nil
                }.joined(separator: " ")
                report.images += content.filter {
                    if case .image = $0 { return true }
                    return false
                }
                report.lines.append("\(index + 1). \(name) (\(milliseconds(since: stepStart)) ms): \(text)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failed += 1
                if report.firstFailure == nil { report.firstFailure = index + 1 }
                report.lines.append("\(index + 1). FAILED (\(milliseconds(since: stepStart)) ms): \(SimBridgeError.message(for: error))")
                if stopOnError {
                    let skipped = steps.count - index - 1
                    if skipped > 0 { report.lines.append("Stopped; \(skipped) remaining step(s) not run.") }
                    break
                }
            }
        }
        return report
    }

    /// Splits a step into its tool name and arguments, with `udid` inherited
    /// from the batch unless the step sets its own.
    static func parse(_ step: Value, udid: String) throws -> (name: String, arguments: Arguments) {
        guard let object = step.objectValue, object.count == 1, let (name, value) = object.first else {
            throw ToolError("Each step must be an object with exactly one key, the tool name, e.g. {\"tap\":{\"x\":10,\"y\":20}}.")
        }
        guard name != "batch" else { throw ToolError("Batches cannot be nested.") }
        guard ["sleep", "capture"].contains(name) || ToolCatalog.handlers[name] != nil else { throw ToolError(ToolCatalog.unknown(name)) }
        return (name, Arguments(value.objectValue ?? [:]).inheriting(udid: udid))
    }

    private static func run(_ name: String, _ args: Arguments) async throws -> [Tool.Content] {
        switch name {
        case "sleep":
            try await Task.sleep(for: args.milliseconds("ms") ?? .zero)
            return [.plain("Slept \(args.int("ms") ?? 0) ms.")]
        case "capture":
            let path = try args.require("path")
            let format: Screenshot.Format = path.lowercased().hasSuffix(".png") ? .png : .jpeg
            let shot = try await args.session().screenshot(scale: args.double("scale") ?? 1, format: format)
            return [.plain("Saved a screenshot to \(try CapturePath.write(shot.data, to: path)).")]
        default:
            return try await ToolCatalog.handlers[name]!(args)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        (ContinuousClock.now - start).inMilliseconds
    }
}
