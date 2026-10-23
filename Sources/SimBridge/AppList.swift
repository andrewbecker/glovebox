import Foundation

public struct InstalledApp: Codable, Sendable {
    public let bundleId: String
    public let name: String
    public let type: String
}

public enum AppList {
    public static func list(udid: String) async throws -> [InstalledApp] {
        // `listapps` prints an old-style (OpenStep) plist.
        let plist = try await Simctl.run(["listapps", udid])
        let object = try PropertyListSerialization.propertyList(from: plist, format: nil)
        guard let dictionary = object as? [String: [String: Any]] else { return [] }
        let apps = dictionary.map { bundleID, info in
            InstalledApp(
                bundleId: bundleID,
                name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? bundleID,
                type: info["ApplicationType"] as? String ?? "Unknown"
            )
        }
        return apps.sorted {
            if ($0.type == "User") != ($1.type == "User") { return $0.type == "User" }
            return $0.bundleId < $1.bundleId
        }
    }
}
