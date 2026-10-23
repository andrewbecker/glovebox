import SimBridge

/// Resolves the optional `udid` argument: explicit value, else the last device
/// used, else the single booted simulator.
actor DeviceResolver {
    static let shared = DeviceResolver()

    private var lastUsed: String?

    func resolve(_ args: Arguments) async throws -> String {
        if let udid = args.string("udid") {
            lastUsed = udid
            return udid
        }
        // Checking the last device in-process avoids a ~150 ms simctl spawn per call.
        if let lastUsed, let session = try? await DeviceSession.open(lastUsed), await session.isBooted {
            return lastUsed
        }
        let booted = try await DeviceSet.list().filter(\.isBooted)
        switch booted.count {
        case 1:
            lastUsed = booted[0].udid
            return booted[0].udid
        case 0:
            throw ToolError("No booted simulator. Call `boot` with a UDID from `list_devices` first.")
        default:
            let names = booted.map { "\($0.name) (\($0.udid))" }.joined(separator: ", ")
            throw ToolError("Multiple simulators are booted: \(names). Pass `udid` to choose one.")
        }
    }
}
