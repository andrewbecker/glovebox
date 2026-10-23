import Foundation
import MCP
import SimBridge

/// Debugging an app while driving it: attach, break, look, evaluate, go on.
enum DebugTools {
    static var all: [ToolEntry] {
        [attach, breakpoint, wait, evaluate, resume, detach]
    }

    static let attach = ToolEntry(
        tool: Tool(
            name: "debug_attach",
            description: "Attach lldb (through Xcode's lldb-dap) to an app you installed. By default the app is relaunched under the debugger, so breakpoints passed here catch even its first screen; relaunch: false attaches to it as it runs. While the app is paused, input tools and describe_ui are refused (its screen is frozen). The session detaches after 10 minutes without a debug call, or when glovebox exits. System apps and apps already under Xcode's debugger are refused.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "bundle_id": Schema.string("The app to debug."),
                "relaunch": Schema.boolean("Relaunch the app waiting for the debugger (default true)."),
                "pid": Schema.integer("With relaunch: false, the process to attach to (default: the running instance)."),
                "breakpoints": ["type": "array", "items": ["type": "string"],
                                "description": "Breakpoints to set before the app runs: \"File.swift:42\" or a function name."],
            ], required: ["bundle_id"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let breakpoints = args.values["breakpoints"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let text = try await Debugger.shared.attach(udid: udid, bundleID: try args.require("bundle_id"), pid: args.int("pid"),
                                                        relaunch: args.bool("relaunch") ?? true, breakpoints: breakpoints)
            return [.plain(text)]
        }
    )

    static let breakpoint = ToolEntry(
        tool: Tool(
            name: "debug_breakpoint",
            description: "Set or remove a breakpoint in the attached app: \"File.swift:42\" (a file name or full path) or a function name such as \"MyView.save()\". Then drive the app to it and call debug_wait.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "at": Schema.string("\"File.swift:42\" or a function name."),
                "condition": Schema.string("Stop only when this expression is true, e.g. count > 3."),
                "remove": Schema.boolean("Remove the breakpoint instead (default false)."),
            ], required: ["at"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            return [.plain(try await Debugger.shared.breakpoint(udid: udid, spec: try args.require("at"),
                                                                condition: args.string("condition"),
                                                                remove: args.bool("remove") ?? false))]
        }
    )

    static let wait = ToolEntry(
        tool: Tool(
            name: "debug_wait",
            description: "Wait for the attached app to stop (a breakpoint, a crash or an exception) and show where: the reason and the top of the stack. Returns at once if it is already paused. Send the input that reaches the breakpoint first; an input tool returns once the screen goes still, which a paused app's screen does.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "timeout_ms": Schema.number("How long to wait (default 30000, at most 300000)."),
            ])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let timeout = min(args.milliseconds("timeout_ms") ?? .seconds(30), .seconds(300))
            guard let stop = try await Debugger.shared.waitForStop(udid: udid, timeout: timeout) else {
                return [.plain("Still running after \(timeout.inMilliseconds) ms; nothing stopped it. Check the breakpoint with debug_breakpoint, or send the input that reaches it.")]
            }
            let head = "Paused: \(stop.description ?? stop.reason). Inspect with debug_evaluate, then debug_continue."
            return [.plain(([head] + stop.frames).joined(separator: "\n"))]
        }
    )

    static let evaluate = ToolEntry(
        tool: Tool(
            name: "debug_evaluate",
            description: "Evaluate an expression in the paused app (e.g. self.items.count), or run an lldb command (e.g. po self, bt, frame variable).",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "expression": Schema.string("A Swift or Objective-C expression, or an lldb command."),
                "frame": Schema.integer("Stack frame to evaluate in, 0 being the innermost (default 0)."),
            ], required: ["expression"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let result = try await Debugger.shared.evaluate(udid: udid, expression: try args.require("expression"),
                                                            frame: max(0, args.int("frame") ?? 0))
            return [.plain(result.isEmpty ? "(no output)" : result)]
        }
    )

    static let resume = ToolEntry(
        tool: Tool(
            name: "debug_continue",
            description: "Resume the paused app. Breakpoints stay set.",
            inputSchema: Schema.object(["udid": Schema.udid])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            return [.plain(try await Debugger.shared.resume(udid: udid))]
        }
    )

    static let detach = ToolEntry(
        tool: Tool(
            name: "debug_detach",
            description: "Detach the debugger, leaving the app running.",
            inputSchema: Schema.object(["udid": Schema.udid])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            await Debugger.shared.detach(udid: udid)
            return [.plain("Detached; the app keeps running.")]
        }
    )
}
