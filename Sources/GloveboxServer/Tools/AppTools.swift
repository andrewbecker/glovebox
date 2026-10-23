import Foundation
import MCP
import SimBridge

/// App lifecycle. Building is out of scope: the agent builds with the Xcode MCP
/// and passes the resulting `.app` bundle here.
enum AppTools {
    static var all: [ToolEntry] {
        [installApp, launchApp, terminateApp, uninstallApp, listApps]
    }

    static let installApp = ToolEntry(
        tool: Tool(
            name: "install_app",
            description: "Install a prebuilt .app bundle (e.g. the build product from the Xcode MCP). glovebox does not build apps.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "app_path": Schema.string("Absolute path to the .app bundle."),
            ], required: ["app_path"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let path = try args.require("app_path")
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError("No app bundle at \(path). Build it with the Xcode MCP and pass the built .app path.")
            }
            try await Simctl.run(["install", udid, path], timeout: .seconds(300))
            let bundleID = Bundle(path: path)?.bundleIdentifier
            return [.plain("Installed \(bundleID ?? path).")]
        }
    )

    static let launchApp = ToolEntry(
        tool: Tool(
            name: "launch_app",
            description: "Launch an installed app by bundle identifier and return its process ID once it is frontmost and its first screen has settled (or a system alert covers it). \(waitContract)",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "bundle_id": Schema.string("Bundle identifier, e.g. com.apple.Preferences."),
                "arguments": ["type": "array", "items": ["type": "string"], "description": "Launch arguments."],
                "environment": ["type": "object", "additionalProperties": ["type": "string"], "description": "Environment variables for the app (not DYLD_ ones)."],
                "terminate_existing": Schema.boolean("Terminate a running instance first (default true)."),
                "wait": Schema.boolean("Wait until the app is frontmost and settled (default true)."),
                "timeout_ms": Schema.number("How long to wait for the app (default 30000)."),
                "settle_quiet_ms": Schema.number("How long the first screen must hold still (default \(DeviceSession.launchQuiet.inMilliseconds)): cold launches pause over 2 s mid-transition."),
                "screenshot": Schema.settle["screenshot"]!,
            ], required: ["bundle_id"])
        ),
        handler: { args in
            let environment = args.values["environment"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            // Simulator apps run on the Mac, so a DYLD_ variable would load
            // code from the Mac into the app.
            if let key = environment.keys.sorted().first(where: { $0.uppercased().hasPrefix("DYLD_") }) {
                throw ToolError("launch_app does not pass \(key): DYLD_ variables load code into the app from the Mac.")
            }
            let udid = try await DeviceResolver.shared.resolve(args)
            let bundleID = try args.require("bundle_id")
            var command = ["launch"]
            if args.bool("terminate_existing") ?? true {
                command.append("--terminate-running-process")
            }
            command += [udid, bundleID]
            command += args.values["arguments"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let output = try await Simctl.run(command, childEnvironment: environment)
            // simctl prints "<bundle id>: <pid>".
            let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard args.bool("wait") ?? true, let pid = text.split(separator: " ").last.flatMap({ Int($0) }) else {
                return [.plain("Launched \(text).")]
            }
            let session = try await DeviceSession.open(udid)
            let (ready, alert) = try await session.waitUntilFrontmostOrAlert(
                pid: pid, timeout: args.milliseconds("timeout_ms") ?? .seconds(30),
                quiet: args.milliseconds("settle_quiet_ms") ?? DeviceSession.launchQuiet)
            if let alert {
                return await args.result("Launched \(bundleID) (pid \(pid)), but a system alert is in front of it: \(alert). Tap one of its buttons (tap {\"label\": ...}) to go on.", session: session)
            }
            let state = ready.settled ? "settled" : "frontmost but still changing (settled: false)"
            return await args.result("Launched \(bundleID) (pid \(pid)); \(state) after \(ready.milliseconds) ms.", session: session)
        }
    )

    static let terminateApp = ToolEntry(
        tool: Tool(
            name: "terminate_app",
            description: "Terminate a running app.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "bundle_id": Schema.string("Bundle identifier."),
            ], required: ["bundle_id"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let bundleID = try args.require("bundle_id")
            try await Simctl.run(["terminate", udid, bundleID])
            return [.plain("Terminated \(bundleID).")]
        }
    )

    static let uninstallApp = ToolEntry(
        tool: Tool(
            name: "uninstall_app",
            description: "Uninstall an app.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "bundle_id": Schema.string("Bundle identifier."),
            ], required: ["bundle_id"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let bundleID = try args.require("bundle_id")
            try await Simctl.run(["uninstall", udid, bundleID])
            return [.plain("Uninstalled \(bundleID).")]
        }
    )

    static let listApps = ToolEntry(
        tool: Tool(
            name: "list_apps",
            description: "List installed apps (bundle ID, name, type). User apps are listed first.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "include_system": Schema.boolean("Include system apps (default false)."),
            ])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            var apps = try await AppList.list(udid: udid)
            if args.bool("include_system") != true {
                apps = apps.filter { $0.type != "System" }
            }
            return [.plain(try JSONOutput.encode(apps))]
        }
    )
}
