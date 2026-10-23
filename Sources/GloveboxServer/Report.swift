import Foundation
import SimBridge
import SimBridgeObjC

/// `glovebox-mcp report`: what a bug report needs, gathered in one place.
enum Report {
    struct Device: Codable {
        let udid: String
        let name: String
        let runtime: String
        let input: String
    }

    struct Contents: Codable {
        let glovebox: String
        let macOS: String
        let developerDirectory: String?
        let xcode: String?
        let coreSimulator: String?
        let lldbDAP: String?
        let bootedDevices: [Device]
    }

    static func run(_ arguments: [String]) async -> CLI.Exit {
        let json = arguments.contains("--json")
        guard arguments.allSatisfy({ $0 == "--json" }) else {
            CLI.printError("report takes only --json.")
            return .usage
        }
        let contents = await gather()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: (try? encoder.encode(contents)) ?? Data(), as: UTF8.self))
        } else {
            print("glovebox          \(contents.glovebox)")
            print("macOS          \(contents.macOS)")
            print("Xcode          \(contents.xcode ?? "not found") at \(contents.developerDirectory ?? "?")")
            print("CoreSimulator  \(contents.coreSimulator ?? "not found")")
            print("lldb-dap       \(contents.lldbDAP ?? "missing (debug tools unavailable)")")
            if contents.bootedDevices.isEmpty { print("Booted         none") }
            for device in contents.bootedDevices {
                print("Booted         \(device.name) (\(device.runtime)) \(device.udid), input via \(device.input)")
            }
        }
        return .success
    }

    static func gather() async -> Contents {
        let developer = SBDeveloperDirectory()
        var xcode: String?
        if let developer {
            let contents = (developer as NSString).deletingLastPathComponent
            let info = NSDictionary(contentsOfFile: contents + "/Info.plist")
            let build = NSDictionary(contentsOfFile: contents + "/version.plist")?["ProductBuildVersion"] as? String
            if let version = info?["CFBundleShortVersionString"] as? String {
                xcode = version + (build.map { " (\($0))" } ?? "")
            }
        }
        var devices: [Device] = []
        for device in (try? await DeviceSet.list().filter(\.isBooted)) ?? [] {
            let input = (try? await DeviceSession.open(device.udid).inputTransport()) ?? "unknown"
            devices.append(Device(udid: device.udid, name: device.name, runtime: device.runtime, input: input))
        }
        let lldbDAP = developer.map { $0 + "/usr/bin/lldb-dap" }.flatMap {
            FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil
        }
        return Contents(glovebox: GloveboxServer.version, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                        developerDirectory: developer, xcode: xcode, coreSimulator: SBCoreSimulatorVersion(),
                        lldbDAP: lldbDAP, bootedDevices: devices)
    }
}
