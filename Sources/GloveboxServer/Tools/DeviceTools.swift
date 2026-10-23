import Foundation
import MCP
import SimBridge

enum DeviceTools {
    static var all: [ToolEntry] {
        [listDevices, boot, shutdown, erase, openURL, setAppearance]
    }

    static let listDevices = ToolEntry(
        tool: Tool(
            name: "list_devices",
            description: "List available iOS/watchOS/tvOS simulators with UDID, name, runtime and state. Booted devices are listed first.",
            inputSchema: Schema.object([
                "booted_only": Schema.boolean("Only return booted simulators."),
            ])
        ),
        handler: { args in
            var devices = try await DeviceSet.list()
            if args.bool("booted_only") == true {
                devices = devices.filter(\.isBooted)
            }
            return [.plain(try JSONOutput.encode(devices))]
        }
    )

    static let boot = ToolEntry(
        tool: Tool(
            name: "boot",
            description: "Boot a simulator and wait until it has finished booting. Also opens Xcode's Device Hub so the device is visible.",
            inputSchema: Schema.object([
                "udid": Schema.string("Simulator UDID from list_devices."),
                "open_device_hub": Schema.boolean("Open Device Hub (default true). glovebox itself needs no window."),
            ], required: ["udid"])
        ),
        handler: { args in
            let udid = try args.require("udid")
            // A warm session from before a reboot holds dead HID and display ports.
            await DeviceSession.disconnect(udid)
            do {
                try await Simctl.run(["boot", udid], timeout: .seconds(120))
            } catch let failure as Simctl.Failure where failure.stderr.contains("current state: Booted") {
                // Already booted; fall through to bootstatus.
            }
            // The first boot after an erase can take minutes.
            try await Simctl.run(["bootstatus", udid], timeout: .seconds(600))
            var note = ""
            if args.bool("open_device_hub") ?? true {
                do {
                    try await DeviceHub.open()
                } catch {
                    note = " Could not open Device Hub: \(SimBridgeError.message(for: error))"
                }
            }
            _ = try await DeviceResolver.shared.resolve(args)
            return [.plain("Booted \(udid).\(note)")]
        }
    )

    static let shutdown = ToolEntry(
        tool: Tool(
            name: "shutdown",
            description: "Shut down a simulator.",
            inputSchema: Schema.object(["udid": Schema.udid])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            try await Simctl.run(["shutdown", udid])
            await DeviceSession.disconnect(udid)
            return [.plain("Shut down \(udid).")]
        }
    )

    static let erase = ToolEntry(
        tool: Tool(
            name: "erase",
            description: "Erase all content and settings on a simulator. The simulator must be shut down.",
            inputSchema: Schema.object(["udid": Schema.string("Simulator UDID.")], required: ["udid"])
        ),
        handler: { args in
            let udid = try args.require("udid")
            await DeviceSession.disconnect(udid)
            try await Simctl.run(["erase", udid], timeout: .seconds(300))
            return [.plain("Erased \(udid).")]
        }
    )

    static let openURL = ToolEntry(
        tool: Tool(
            name: "open_url",
            description: "Open a URL (web link or app deep link) on the simulator. Deep links are also the way to enter text type_text cannot. \(waitContract)",
            inputSchema: Schema.object(Schema.merge(Schema.settle, [
                "udid": Schema.udid,
                "url": Schema.string("The URL to open."),
            ]), required: ["url"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let url = try args.require("url")
            let session = try await DeviceSession.open(udid)
            let (_, settle) = try await session.settled(try args.settleOptions()) {
                try await Simctl.run(["openurl", udid, url])
            }
            return await args.result("Opened \(url).\(settle.note)", session: session)
        }
    )

    static let setAppearance = ToolEntry(
        tool: Tool(
            name: "set_appearance",
            description: "Switch the simulator between light and dark mode.",
            inputSchema: Schema.object([
                "udid": Schema.udid,
                "appearance": ["type": "string", "enum": ["light", "dark"]],
            ], required: ["appearance"])
        ),
        handler: { args in
            let udid = try await DeviceResolver.shared.resolve(args)
            let appearance = try args.require("appearance")
            try await Simctl.run(["ui", udid, "appearance", appearance])
            return [.plain("Appearance set to \(appearance).")]
        }
    )
}
