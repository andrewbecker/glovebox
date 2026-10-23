import AppKit

/// Xcode's Device Hub, which shows simulators in a window. glovebox itself needs
/// no window; this is only so a person can watch.
public enum DeviceHub {
    /// Opens the Device Hub of the selected Xcode, or brings it forward if it
    /// is already running.
    public static func open() async throws {
        guard let developerDirectory = SBDeveloperDirectory() else {
            throw SimBridgeError("xcode-select -p failed, so Device Hub could not be found.")
        }
        let app = URL(fileURLWithPath: developerDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent("Applications/DeviceHub.app")
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw SimBridgeError("No Device Hub at \(app.path). It ships with Xcode 27 and later.")
        }
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
