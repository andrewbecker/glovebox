import Foundation

/// Notices when another glovebox process drove the same simulator recently, so
/// two agents on one device find out instead of silently interleaving. There
/// is no lock: a lock an agent cannot see turns a visible race into a hang.
/// Each process records its last input per device in a small file.
enum DriverNote {
    /// Input from another process this recent is worth mentioning.
    static let window: TimeInterval = 120

    static var directory: String { NSTemporaryDirectory() + "glovebox-drivers" }

    struct Record: Codable {
        let pid: Int32
        let client: String
        let time: Date
    }

    /// The name this process gives itself in other processes' notes.
    nonisolated(unsafe) static var clientName = "glovebox"

    /// Records that this process drove `udid`, and returns a note if another
    /// process did within `window`: a live one, or a finished one from
    /// another client (a one-shot CLI call from a script, say). Finished
    /// processes of this same client are its own earlier CLI calls.
    static func record(udid: String, now: Date = Date()) -> String {
        let path = directory + "/" + udid.uppercased() + ".json"
        var note = ""
        if let data = FileManager.default.contents(atPath: path),
           let last = try? JSONDecoder().decode(Record.self, from: data),
           last.pid != getpid(), now.timeIntervalSince(last.time) < window,
           last.client != clientName || kill(last.pid, 0) == 0 || errno == EPERM {
            let seconds = Int(now.timeIntervalSince(last.time).rounded())
            note = " Note: another client (\(displayName(last.client)), pid \(last.pid)) also drove this simulator \(seconds) s ago, so the screen may have changed under you; check it before relying on earlier observations."
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Record(pid: getpid(), client: clientName, time: now)) {
            FileManager.default.createFile(atPath: path, contents: data)
        }
        return note
    }

    /// Another process's name for itself, as shown to this agent. Any MCP
    /// client can pick its name, so only a short run of plain characters is
    /// passed on.
    static func displayName(_ name: String) -> String {
        let plain = name.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " ._-()/@".unicodeScalars.contains($0))
        }
        let shown = String(String.UnicodeScalarView(plain.prefix(60))).trimmingCharacters(in: .whitespaces)
        return shown.isEmpty ? "unnamed" : shown
    }
}
