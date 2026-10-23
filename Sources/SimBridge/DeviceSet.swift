import Foundation

public struct SimulatorDevice: Codable, Sendable, Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: String
    public let deviceType: String?

    public var isBooted: Bool { state == "Booted" }
}

public enum DeviceSet {
    /// Lists all available simulators, booted ones first.
    public static func list() async throws -> [SimulatorDevice] {
        let data = try await Simctl.run(["list", "devices", "available", "-j"])
        return try parseList(data)
    }

    static func parseList(_ data: Data) throws -> [SimulatorDevice] {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let udid: String
                let name: String
                let state: String
                let deviceTypeIdentifier: String?
            }
            let devices: [String: [Entry]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let devices = listing.devices.flatMap { runtimeID, entries in
            entries.map {
                SimulatorDevice(
                    udid: $0.udid,
                    name: $0.name,
                    state: $0.state,
                    runtime: runtimeName(runtimeID),
                    deviceType: $0.deviceTypeIdentifier.map(deviceTypeName)
                )
            }
        }
        return devices.sorted {
            if $0.isBooted != $1.isBooted { return $0.isBooted }
            if $0.runtime != $1.runtime { return $0.runtime > $1.runtime }
            return $0.name < $1.name
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-1` -> `iOS 27.1`
    static func runtimeName(_ identifier: String) -> String {
        let suffix = identifier.split(separator: ".").last.map(String.init) ?? identifier
        guard let dash = suffix.firstIndex(of: "-") else { return suffix }
        let platform = suffix[..<dash]
        let version = suffix[suffix.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    /// `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro` -> `iPhone 17 Pro`
    static func deviceTypeName(_ identifier: String) -> String {
        let suffix = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return suffix.replacingOccurrences(of: "-", with: " ")
    }
}
